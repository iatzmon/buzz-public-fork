import '../../shared/relay/relay.dart';
import 'forum_models.dart';

/// A successful relay read confirmed the thread is no longer available.
class ForumThreadUnavailable extends StateError {
  ForumThreadUnavailable() : super('Forum thread is unavailable');
}

/// Incremental, community-scoped history for one forum thread.
/// Commits only complete reads; superseded and failed refreshes retain the cache.
class ForumThreadHistory {
  final _replies = <String, NostrEvent>{};
  int? _since;

  Future<ForumThreadResponse> load(
    RelaySessionNotifier session, {
    required String channelId,
    required String eventId,
    required bool Function() isCurrent,
  }) async {
    final results = await Future.wait([
      session.queryRelay([
        NostrFilter(
          kinds: const [9, 40002, 45001, 45003],
          ids: [eventId],
          tags: {
            '#h': [channelId],
          },
          limit: 1,
        ),
      ]),
      _pages(
        session,
        NostrFilter(
          kinds: const [9, 45003],
          tags: {
            '#h': [channelId],
            '#e': [eventId],
          },
          since: _since,
          limit: 100,
        ),
        isCurrent,
      ),
      if (_replies.isNotEmpty)
        _pages(
          session,
          NostrFilter(
            kinds: const [EventKind.deletion, EventKind.nip29DeleteEvent],
            tags: {
              '#h': [channelId],
              '#e': _replies.keys.toList(),
            },
            since: _since,
            limit: 100,
          ),
          isCurrent,
        ),
    ]);
    if (!isCurrent()) throw StateError('Thread refresh superseded');
    final roots = results[0].where(
      (e) => e.id == eventId && e.channelId == channelId,
    );
    if (roots.isEmpty) throw ForumThreadUnavailable();
    final root = roots.first;
    final next = {..._replies};
    for (final reply in results[1]) {
      if (reply.channelId == channelId && reply.id != eventId) {
        next[reply.id] = reply;
      }
    }
    // A deletion marker is only a hint. Re-read its cached targets so an
    // unauthorized kind-5 marker cannot hide another author's message.
    final targets = results.length < 3
        ? <String>{}
        : {
            for (final deletion in results[2])
              for (final tag in deletion.tags)
                if (tag.length > 1 && tag[0] == 'e' && next.containsKey(tag[1]))
                  tag[1],
          };
    final ids = targets.toList();
    for (var offset = 0; offset < ids.length; offset += 100) {
      final batch = ids.skip(offset).take(100).toList();
      final existing = await session.queryRelay([
        NostrFilter(
          kinds: const [9, 45003],
          ids: batch,
          tags: {
            '#h': [channelId],
          },
          limit: 100,
        ),
      ]);
      if (!isCurrent()) throw StateError('Thread refresh superseded');
      final present = existing.map((e) => e.id).toSet();
      for (final id in batch) {
        if (!present.contains(id)) next.remove(id);
      }
    }
    if (next.length > 10000) {
      throw StateError('Forum thread exceeds history limit');
    }
    var newest = root.createdAt;
    for (final reply in next.values) {
      if (reply.createdAt > newest) newest = reply.createdAt;
    }
    // Relay ingestion permits 15 minutes of clock skew in either direction.
    // Overlap both ends, including same-second events, then deduplicate by id.
    final since = newest > 1800 ? newest - 1800 : 0;
    _replies
      ..clear()
      ..addAll(next);
    _since = since;
    return ForumThreadResponse.fromEvents(
      root: root,
      replies: next.values.toList(),
    );
  }

  Future<List<NostrEvent>> _pages(
    RelaySessionNotifier session,
    NostrFilter filter,
    bool Function() isCurrent,
  ) async {
    final all = <String, NostrEvent>{};
    var current = filter;
    String? previousCursor;
    for (var page = 0; page < 100; page++) {
      final events = await session.queryRelay([current]);
      if (!isCurrent()) throw StateError('Thread refresh superseded');
      for (final event in events) {
        all[event.id] = event;
      }
      if (events.length < filter.limit) return all.values.toList();
      final last = events.last;
      final cursor = '${last.createdAt}:${last.id}';
      if (cursor == previousCursor) {
        throw StateError('Thread cursor did not advance');
      }
      previousCursor = cursor;
      current = NostrFilter(
        kinds: filter.kinds,
        tags: filter.tags,
        since: filter.since,
        limit: filter.limit,
        until: last.createdAt,
        extensions: {'before_id': last.id},
      );
    }
    throw StateError('Forum thread exceeds history page limit');
  }
}
