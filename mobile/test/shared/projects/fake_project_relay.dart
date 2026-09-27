import 'dart:async';

import 'package:buzz/shared/relay/relay.dart';

/// Applies a NIP-01 filter the way the relay's `/query` bridge does: kinds,
/// authors, since, and until are pushed into SQL and limited (newest first,
/// ties by id); generic tag filters such as `#a` are applied only *after* the
/// limit (`filter_fully_pushable` in `crates/buzz-relay/src/handlers/req.rs`),
/// so a page can come back short even when more matches exist.
List<NostrEvent> applyFilter(List<NostrEvent> events, NostrFilter filter) {
  final authors = filter.authors?.map((a) => a.toLowerCase()).toSet();
  final candidates = [
    for (final event in events)
      if (filter.kinds.contains(event.kind) &&
          (authors == null || authors.contains(event.pubkey.toLowerCase())) &&
          (filter.since == null || event.createdAt >= filter.since!) &&
          (filter.until == null || event.createdAt <= filter.until!))
        event,
  ];
  candidates.sort((a, b) {
    final byTime = b.createdAt.compareTo(a.createdAt);
    return byTime != 0 ? byTime : a.id.compareTo(b.id);
  });
  return [
    for (final event in candidates.take(filter.limit))
      if (filter.tags.entries.every((entry) {
        final name = entry.key.substring(1);
        return event.tags.any(
          (tag) =>
              tag.length > 1 && tag[0] == name && entry.value.contains(tag[1]),
        );
      }))
        event,
  ];
}

/// A connected session whose HTTP query bridge serves [events].
class FakeProjectRelaySession extends RelaySessionNotifier {
  FakeProjectRelaySession(this.events);

  List<NostrEvent> events;
  final List<NostrFilter> queries = [];

  /// Kinds whose queries fail with a relay error.
  final Set<int> failingKinds = {};

  /// When set, queries wait for it before answering.
  Completer<void>? gate;

  @override
  SessionState build() => const SessionState(status: SessionStatus.connected);

  @override
  Future<List<NostrEvent>> queryRelay(
    List<NostrFilter> filters, {
    Duration timeout = const Duration(seconds: 8),
  }) async {
    queries.addAll(filters);
    final pending = gate;
    if (pending != null) await pending.future;
    for (final filter in filters) {
      if (filter.kinds.any(failingKinds.contains)) {
        throw RelayException(503, 'relay unavailable');
      }
    }
    return [for (final filter in filters) ...applyFilter(events, filter)];
  }
}
