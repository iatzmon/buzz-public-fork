import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../relay/relay.dart';
import '../theme/theme_provider.dart';
import 'project_clone_url.dart';
import 'project_enumeration.dart';
import 'project_models.dart';
import 'project_snapshot.dart';

/// The active [ProjectScope], or null without a signing identity.
final projectScopeProvider = Provider<ProjectScope?>((ref) {
  final baseUrl = ref.watch(relayConfigProvider.select((c) => c.baseUrl));
  final pubkey = ref.watch(myPubkeyProvider)?.toLowerCase();
  if (pubkey == null || pubkey.isEmpty) return null;
  return (
    relayBaseUrl: baseUrl,
    relayOrigin: relayOriginFromBaseUrl(baseUrl),
    viewerPubkey: pubkey,
  );
});

/// Loads the scope's projects (kind:30621), repositories (kind:30617), and
/// their kind:5 tombstones over the relay's HTTP query bridge.
///
/// Offline first: the scope's last-good snapshot is emitted from the device
/// cache before the relay answers, and stays in `state.value` while loading
/// or after a failure. Failures still surface as [AsyncError] — never as an
/// empty collection.
///
/// Refresh triggers: first watch, [refresh], app resume when the snapshot is
/// older than [staleAfter], and a relay reconnect while in error.
class ProjectsNotifier extends StreamNotifier<ProjectsSnapshot> {
  ProjectsNotifier(this.scope);

  final ProjectScope scope;

  /// Desktop's `PROJECTS_STALE_TIME_MS`.
  static const staleAfter = Duration(minutes: 5);

  bool _emitted = false;

  @override
  Stream<ProjectsSnapshot> build() async* {
    ref.listen(appLifecycleProvider, (previous, next) {
      if (next == AppLifecycleState.resumed &&
          previous != AppLifecycleState.resumed) {
        unawaited(refreshIfStale());
      }
    });
    ref.listen(relaySessionProvider, (previous, next) {
      if (next.status == SessionStatus.connected &&
          previous?.status != SessionStatus.connected &&
          state.hasError) {
        unawaited(refresh());
      }
    });

    if (!_emitted) {
      final cached = readCachedProjectsSnapshot(
        ref.read(savedPrefsProvider),
        scope,
      );
      if (cached != null) {
        _emitted = true;
        yield cached;
      }
    }
    final fresh = await _load();
    _emitted = true;
    yield fresh;
  }

  /// Reloads from the relay. Resolves once the reload settles; a failure is
  /// reported through [state], not thrown.
  Future<void> refresh() async {
    ref.invalidateSelf();
    try {
      await future;
    } on Object {
      // Surfaced through `state` as AsyncError with the previous value.
    }
  }

  /// Reloads when the last relay fetch is older than [staleAfter], came from
  /// the cache, failed, or never happened.
  Future<void> refreshIfStale() async {
    final snapshot = state.value;
    if (snapshot != null &&
        !snapshot.fromCache &&
        !state.hasError &&
        DateTime.now().difference(snapshot.fetchedAt) < staleAfter) {
      return;
    }
    await refresh();
  }

  bool _scopeIsActive() {
    final config = ref.read(relayConfigProvider);
    return config.baseUrl == scope.relayBaseUrl &&
        ref.read(myPubkeyProvider)?.toLowerCase() == scope.viewerPubkey;
  }

  Future<ProjectsSnapshot> _load() async {
    // The session queries whichever relay is active now; never let a retired
    // scope's instance query (or describe) the replacement community.
    bool cancelled() => !ref.mounted || !_scopeIsActive();
    if (cancelled()) throw const ProjectsCancelledException();
    final session = ref.read(relaySessionProvider.notifier);
    final events = await fetchProjectEvents(
      (filter) => session.queryRelay([filter]),
      isCancelled: cancelled,
    );
    if (cancelled()) throw const ProjectsCancelledException();
    final fetchedAt = DateTime.now();
    unawaited(
      writeCachedProjectEvents(
        ref.read(savedPrefsProvider),
        scope,
        events,
        fetchedAt,
      ).catchError((Object error) {
        debugPrint('[projects] snapshot cache write failed: $error');
        return false;
      }),
    );
    return ProjectsSnapshot.fromEvents(scope, events, fetchedAt: fetchedAt);
  }
}

/// Project collections keyed by scope. Prefer [activeProjectsProvider].
///
/// Automatic provider retry is off: a failed load stays an [AsyncError] until
/// an explicit trigger (refresh, reconnect, stale resume), so `refresh()`
/// settles promptly and the UI can offer its own retry affordance.
final projectsProvider = StreamNotifierProvider.autoDispose
    .family<ProjectsNotifier, ProjectsSnapshot, ProjectScope>(
      ProjectsNotifier.new,
      retry: (_, _) => null,
    );

/// The active community's project collection.
///
/// Loading and error states keep the previous (or cached) snapshot in
/// `.value`. Without a signing identity this is an [AsyncError] with a
/// [StateError].
final activeProjectsProvider = Provider<AsyncValue<ProjectsSnapshot>>((ref) {
  final scope = ref.watch(projectScopeProvider);
  if (scope == null) {
    return AsyncError(
      StateError('No signing identity available'),
      StackTrace.current,
    );
  }
  return ref.watch(projectsProvider(scope));
});

/// The active scope's [ProjectsNotifier] (for [ProjectsNotifier.refresh]),
/// or null without a signing identity.
final activeProjectsNotifierProvider = Provider<ProjectsNotifier?>((ref) {
  final scope = ref.watch(projectScopeProvider);
  return scope == null ? null : ref.watch(projectsProvider(scope).notifier);
});

/// The project whose authoritative home is the given channel, from the
/// current snapshot; null when none (or before any snapshot — watch
/// [activeProjectsProvider] for load status).
final projectHomeForChannelProvider = Provider.autoDispose
    .family<Project?, String>(
      (ref, channelId) => ref
          .watch(activeProjectsProvider)
          .value
          ?.projectHomeForChannel(channelId),
    );

/// Whether the given channel is a project home, from the current snapshot;
/// false before any snapshot.
final isProjectHomeChannelProvider = Provider.autoDispose.family<bool, String>(
  (ref, channelId) =>
      ref
          .watch(activeProjectsProvider)
          .value
          ?.isProjectHomeChannel(channelId) ??
      false,
);

/// The project with the given address, from the current snapshot.
final projectByAddressProvider = Provider.autoDispose.family<Project?, String>(
  (ref, address) =>
      ref.watch(activeProjectsProvider).value?.projectByAddress(address),
);
