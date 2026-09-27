import 'package:flutter/foundation.dart';
import 'package:nostr/nostr.dart' as nostr;

import '../relay/nostr_models.dart';

/// Checks a batch of relay events before they are folded or cached.
typedef ProjectEventVerifier =
    Future<List<NostrEvent>> Function(List<NostrEvent> events);

/// Whether [event]'s id matches its content and its signature verifies.
bool isVerifiedProjectEvent(NostrEvent event) {
  try {
    nostr.Event(
      event.id,
      event.pubkey,
      event.createdAt,
      event.kind,
      event.tags,
      event.content,
      event.sig,
    );
    return true;
  } on Object {
    return false;
  }
}

/// Keeps only the events whose id and signature verify, off the UI isolate.
///
/// The relay is not trusted: a forged or altered event is dropped, never
/// shown or cached.
Future<List<NostrEvent>> verifyProjectEvents(List<NostrEvent> events) async {
  if (events.isEmpty) return const [];
  final verified = await compute(
    _selectVerifiedProjectEvents,
    events,
    debugLabel: 'buzz-project-event-verify',
  );
  final dropped = events.length - verified.length;
  if (dropped > 0) {
    debugPrint('[projects] dropped $dropped events that failed verification');
  }
  return verified;
}

List<NostrEvent> _selectVerifiedProjectEvents(List<NostrEvent> events) => [
  for (final event in events)
    if (isVerifiedProjectEvent(event)) event,
];
