import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:nostr/nostr.dart' as nostr;
import 'package:shared_preferences/shared_preferences.dart';

import '../community/community_membership_provider.dart';
import '../relay/relay.dart';
import '../theme/theme_provider.dart';
import 'project_task.dart';

/// Injectable relay boundary used by task history and durable writes.
class ProjectTaskTransport {
  const ProjectTaskTransport({
    required this.scan,
    required this.verify,
    required this.publish,
    required this.sign,
  });

  /// Reads events from the relay without checking their signatures. Use it
  /// only to choose which events to pass to [verify].
  final Future<List<NostrEvent>> Function(NostrFilter) scan;

  /// Checks the signatures of [scan] events. Throws when one fails.
  final Future<List<NostrEvent>> Function(List<NostrEvent>) verify;
  final Future<void> Function(NostrEvent) publish;
  final NostrEvent Function(int, String, List<List<String>>, int) sign;

  /// Reads events from the relay and checks every signature.
  Future<List<NostrEvent>> query(NostrFilter filter) async =>
      verify(await scan(filter));
}

/// The isolate captures only public events, never the provider or signing key.
/// The web build has no isolates, so it checks the events in slices instead.
Future<List<NostrEvent>> verifyProjectTaskEvents(List<NostrEvent> events) =>
    kIsWeb
    ? verifyProjectTaskEventsInSlices(events)
    : compute(_verifyProjectTaskEvents, events);

List<NostrEvent> _verifyProjectTaskEvents(List<NostrEvent> events) {
  for (final event in events) {
    nostr.Event.fromMap(event.toJson());
  }
  return events;
}

/// After this much work, [verifyProjectTaskEventsInSlices] lets the page draw
/// and handle input before the next event. One signature check can take
/// longer than this on its own.
const _browserYieldThreshold = Duration(milliseconds: 8);

/// The web build's [verifyProjectTaskEvents]. The browser runs it on the
/// page's only thread, where one signature check takes about 60 ms, so it
/// lets the page run after each [_browserYieldThreshold] of work.
@visibleForTesting
Future<List<NostrEvent>> verifyProjectTaskEventsInSlices(
  List<NostrEvent> events,
) async {
  final slice = Stopwatch()..start();
  for (final event in events) {
    if (slice.elapsed > _browserYieldThreshold) {
      await Future<void>.delayed(Duration.zero);
      slice.reset();
    }
    nostr.Event.fromMap(event.toJson());
  }
  return events;
}

final projectTaskTransportProvider = Provider<ProjectTaskTransport>((ref) {
  final config = ref.watch(relayConfigProvider);
  final session = ref.watch(relaySessionProvider.notifier);
  final verifiedEvents = <String, NostrEvent>{};
  void checkContext() {
    if (!ref.mounted || ref.read(relayConfigProvider) != config) {
      throw StateError('The community changed. Reopen Tasks to continue.');
    }
  }

  return ProjectTaskTransport(
    scan: (filter) async {
      checkContext();
      final events = await session.queryRelay([filter]);
      checkContext();
      return events;
    },
    verify: (events) async {
      checkContext();
      final pending = events
          .where((event) => !verifiedEvents.containsKey(event.id))
          .toList();
      final verified = await verifyProjectTaskEvents(pending);
      checkContext();
      for (final event in verified) {
        verifiedEvents[event.id] = event;
      }
      final result = [for (final event in events) verifiedEvents[event.id]!];
      while (verifiedEvents.length > 20000) {
        verifiedEvents.remove(verifiedEvents.keys.first);
      }
      return result;
    },
    publish: (event) async {
      checkContext();
      await session.publish(event);
      checkContext();
    },
    sign: (kind, content, tags, createdAt) {
      checkContext();
      final nsec = config.nsec;
      if (nsec == null) throw StateError('Sign in to create or assign tasks.');
      return NostrEvent.fromJson(
        nostr.Event.from(
          kind: kind,
          content: content,
          tags: tags,
          createdAt: createdAt,
          secretKey: nostr.Nip19.decode(payload: nsec).data,
        ).toMap(),
      );
    },
  );
});

/// Scan SQL-filtered issue pages before selecting a repository. Relays that
/// post-filter #a after LIMIT can otherwise return a false empty project.
/// The pages hold the tasks of every repository, so [scan] reads them
/// unchecked and only the returned tasks go through [verify].
Future<List<NostrEvent>> loadProjectTaskRoots(
  String repoAddress,
  Future<List<NostrEvent>> Function(NostrFilter) scan, {
  required Future<List<NostrEvent>> Function(List<NostrEvent>) verify,
}) async {
  final roots = <String, NostrEvent>{};
  int? until;
  var limit = 500;
  for (var pageNumber = 0; pageNumber < 40; pageNumber++) {
    final page = await scan(
      NostrFilter(kinds: const [1621], limit: limit, until: until),
    );
    for (final event in page) {
      if (event.kind == 1621 && event.getTagValue('a') == repoAddress) {
        roots[event.id] = event;
      }
    }
    if (roots.length >= 200 || page.length < limit) {
      final sorted = roots.values.toList()
        ..sort((a, b) => ProjectTask.compareEvents(b, a));
      return verify(sorted.take(200).toList());
    }
    final oldest = page.map((e) => e.createdAt).reduce((a, b) => a < b ? a : b);
    if (until == null || oldest < until) {
      until = oldest;
    } else if (limit < 1000) {
      limit = 1000;
    } else {
      throw StateError(
        'Too many tasks share one timestamp to load this repository reliably.',
      );
    }
  }
  throw StateError(
    'Task history is too large to load this repository completely.',
  );
}

/// Complete operation history, with a hard resource bound and explicit failure.
/// Only SQL-pushed #e is sent: #t/#a are post-filtered by older relays.
Future<List<NostrEvent>> loadProjectTaskHistory(
  List<String> ids,
  Future<List<NostrEvent>> Function(NostrFilter) query,
) async {
  final events = <String, NostrEvent>{};
  for (var start = 0; start < ids.length; start += 100) {
    final chunk = ids.skip(start).take(100).toList();
    var limit = 500;
    int? until;
    for (var pageNumber = 0; ; pageNumber++) {
      if (pageNumber >= 40) {
        throw StateError('Task history is too large to load completely.');
      }
      final page = await query(
        NostrFilter(
          kinds: const [1, 1111, 1630, 1631, 1632, 1633],
          tags: {'#e': chunk},
          limit: limit,
          until: until,
        ),
      );
      for (final event in page) {
        events[event.id] = event;
      }
      if (page.length < limit) break;
      final oldest = page
          .map((e) => e.createdAt)
          .reduce((a, b) => a < b ? a : b);
      if (until == null || oldest < until) {
        until = oldest;
      } else if (limit < 1000) {
        limit = 1000;
      } else {
        throw StateError(
          'Task history contains too many events at one timestamp.',
        );
      }
    }
  }
  return events.values.toList();
}

/// Community owners (lowercase hex) from the relay's member list. Empty while
/// the list loads, so a previous community's owners are never trusted.
final projectTaskCommunityOwnersProvider = Provider.autoDispose<Set<String>>((
  ref,
) {
  final membership = ref.watch(communityMembershipProvider);
  if (membership.isLoading || membership.hasError) return const {};
  return {
    for (final member in membership.value?.members ?? const <CommunityMember>[])
      if (member.role == CommunityMemberRole.owner) member.pubkey.toLowerCase(),
  };
});

/// Cached relay state, draft, and signed outbox are scoped to account/community.
class ProjectTaskState {
  const ProjectTaskState({
    this.events = const [],
    this.pending = const [],
    this.title = '',
    this.body = '',
    this.loading = false,
    this.sending = false,
    this.error,
    this.loaded = false,
  });
  final List<NostrEvent> events;
  final List<NostrEvent> pending;
  final String title;
  final String body;
  final bool loading;
  final bool sending;
  final bool loaded;
  final String? error;

  /// Tasks with the base trust rule only (author and repository owner).
  /// Screens use [tasksWith] and the community owners.
  List<ProjectTask> get tasks => tasksWith(const {});

  /// Tasks where [communityOwners] may also assign and change status.
  List<ProjectTask> tasksWith(Set<String> communityOwners) => [
    for (final event in events)
      if (event.kind == 1621)
        ProjectTask.fromEvents(event, events, communityOwners: communityOwners),
  ]..sort((a, b) => ProjectTask.compareEvents(b.root, a.root));
  bool get hasPendingCreate => pending.any((e) => e.kind == 1621);

  ProjectTaskState copyWith({
    List<NostrEvent>? events,
    List<NostrEvent>? pending,
    String? title,
    String? body,
    bool? loading,
    bool? sending,
    bool? loaded,
    String? error,
  }) => ProjectTaskState(
    events: events ?? this.events,
    pending: pending ?? this.pending,
    title: title ?? this.title,
    body: body ?? this.body,
    loading: loading ?? this.loading,
    sending: sending ?? this.sending,
    loaded: loaded ?? this.loaded,
    error: error,
  );
}

class ProjectTaskStore extends Notifier<ProjectTaskState> {
  ProjectTaskStore(this.repoAddress);
  final String repoAddress;
  late String _key;
  late SharedPreferences _prefs;
  late ProjectTaskTransport _transport;
  int _generation = 0;
  int _revision = 0;
  bool _unreadable = false;
  Future<void> _writes = Future.value();

  @override
  ProjectTaskState build() {
    final config = ref.watch(relayConfigProvider);
    final pubkey = ref.watch(myPubkeyProvider);
    _transport = ref.watch(projectTaskTransportProvider);
    _prefs = ref.watch(savedPrefsProvider);
    _key = 'project-tasks-v1:${config.baseUrl}:$pubkey:$repoAddress';
    final generation = ++_generation;
    ref.onDispose(() => _generation++);
    Future.microtask(() {
      if (_current(generation)) unawaited(refresh());
    });
    _unreadable = false;
    final raw = _prefs.getString(_key);
    if (raw == null) return const ProjectTaskState();
    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      List<NostrEvent> parse(String key) => (json[key] as List? ?? [])
          .map((e) => NostrEvent.fromJson(e as Map<String, dynamic>))
          .toList();
      return ProjectTaskState(
        events: parse('events'),
        pending: parse('pending'),
        title: json['title'] as String? ?? '',
        body: json['body'] as String? ?? '',
        loaded: json['loaded'] == true,
      );
    } catch (_) {
      _unreadable = true;
      return const ProjectTaskState(
        error: 'Could not read saved task data. Original data is preserved.',
      );
    }
  }

  bool _current(int generation) => ref.mounted && generation == _generation;

  Future<void> _persist() {
    if (_unreadable) {
      return Future.error(
        StateError(
          'Could not read saved task data. Original data is preserved; writes are blocked.',
        ),
      );
    }
    final key = _key;
    final prefs = _prefs;
    final value = jsonEncode({
      'events': state.events.map((e) => e.toJson()).toList(),
      'pending': state.pending.map((e) => e.toJson()).toList(),
      'title': state.title,
      'body': state.body,
      'loaded': state.loaded,
    });
    final next = _writes.then((_) async {
      if (!await prefs.setString(key, value)) {
        throw StateError('Could not save task data.');
      }
    });
    _writes = next.catchError((Object _) {});
    return next;
  }

  /// Preserve the draft on navigation, failed sends, and app restarts.
  Future<void> saveDraft(String title, String body) async {
    if (state.hasPendingCreate) return;
    state = state.copyWith(title: title, body: body);
    final generation = _generation;
    try {
      await _persist();
    } catch (e) {
      if (_current(generation)) state = state.copyWith(error: '$e');
    }
  }

  Future<void> refresh() async {
    if (state.loading || state.sending) return;
    final generation = _generation;
    final transport = _transport;
    final revision = _revision;
    state = state.copyWith(loading: true);
    try {
      final roots = await loadProjectTaskRoots(
        repoAddress,
        (filter) {
          if (!_current(generation)) throw StateError('Task view changed.');
          return transport.scan(filter);
        },
        verify: (events) {
          if (!_current(generation)) throw StateError('Task view changed.');
          return transport.verify(events);
        },
      );
      final history = await loadProjectTaskHistory(
        roots.map((e) => e.id).toList(),
        (filter) {
          if (!_current(generation)) throw StateError('Task view changed.');
          return transport.query(filter);
        },
      );
      if (!_current(generation)) return;
      if (revision != _revision) {
        state = state.copyWith(loading: false);
        return;
      }
      final merged = {
        for (final e in [...roots, ...history]) e.id: e,
      };
      state = state.copyWith(
        events: merged.values.toList(),
        loading: false,
        loaded: true,
      );
      await _persist();
    } catch (e) {
      if (_current(generation)) {
        state = state.copyWith(loading: false, error: '$e');
      }
    }
  }

  Future<void> createTask({String? channelId}) async {
    if (state.sending) return;
    if (state.hasPendingCreate) return retryPending();
    if (utf8.encode(state.body).length > 65536) {
      throw ArgumentError('Task body is too long.');
    }
    final tags = projectTaskTags(repoAddress: repoAddress, title: state.title);
    if (channelId != null && channelId.isNotEmpty) tags.add(['h', channelId]);
    await _send(
      1621,
      state.body,
      tags,
      DateTime.now().millisecondsSinceEpoch ~/ 1000,
    );
  }

  Future<void> assign(
    ProjectTask task,
    String assignee, {
    required bool assign,
    String? assigneeLabel,
  }) async {
    if (state.sending) return;
    final signer = ref.read(myPubkeyProvider) ?? '';
    final tags = projectTaskAssignmentTags(
      task: task,
      signer: signer,
      assignee: assignee,
      assign: assign,
    );
    if (state.pending.isNotEmpty) {
      throw StateError('Retry the pending task change first.');
    }
    await _send(
      1,
      '${assign ? 'Assigned this task to' : 'Unassigned'} ${assigneeLabel?.trim().isNotEmpty == true ? assigneeLabel!.trim() : assignee.toLowerCase()}',
      tags,
      task.nextOperationTime(
        signer,
        DateTime.now().millisecondsSinceEpoch ~/ 1000,
      ),
    );
  }

  Future<void> _send(
    int kind,
    String content,
    List<List<String>> tags,
    int time,
  ) async {
    final event = _transport.sign(kind, content, tags, time);
    _revision++;
    state = state.copyWith(pending: [...state.pending, event]);
    await retryPending();
  }

  /// Retransmit the exact persisted event, never a second task or operation.
  Future<void> retryPending() async {
    if (state.sending) return;
    _revision++;
    final generation = _generation;
    final transport = _transport;
    state = state.copyWith(sending: true);
    var persisted = false;
    try {
      await _persist(); // Durability before the first network write.
      persisted = true;
      if (!_current(generation)) return;
      for (final event in state.pending.toList()) {
        await transport.publish(event);
        if (!_current(generation)) return;
        final merged = {
          for (final e in [...state.events, event]) e.id: e,
        };
        state = state.copyWith(
          events: merged.values.toList(),
          pending: state.pending.where((e) => e.id != event.id).toList(),
          title: event.kind == 1621 ? '' : null,
          body: event.kind == 1621 ? '' : null,
        );
        await _persist();
      }
      if (_current(generation)) state = state.copyWith(sending: false);
    } catch (e) {
      if (_current(generation)) {
        state = state.copyWith(
          sending: false,
          error: persisted
              ? 'Not confirmed sent. Your change is saved; retry to confirm. $e'
              : 'Could not save your change. It has not been sent. $e',
        );
      }
      rethrow;
    }
  }
}

final projectTaskStoreProvider =
    NotifierProvider.family<ProjectTaskStore, ProjectTaskState, String>(
      ProjectTaskStore.new,
    );
