import 'dart:convert';

import 'package:nostr/nostr.dart' as nostr;

import '../crypto/nip44.dart';
import 'nostr_models.dart';

/// Builds a signed NIP-AO control frame (kind 24200) from the owner to one of
/// the owner's agents. The payload is NIP-44 encrypted to the agent; the tags
/// match desktop's `build_agent_observer_frame` (`p` and `agent` both name the
/// agent, `frame` is `control`). The relay forwards it only when the signer
/// owns the agent, and the harness checks the sender again.
NostrEvent buildObserverControlEvent({
  required String ownerPrivkeyHex,
  required String agentPubkey,
  required Map<String, Object?> payload,
  int? createdAt,
}) {
  final agent = agentPubkey.toLowerCase();
  final conversationKey = getConversationKey(ownerPrivkeyHex, agent);
  final event = nostr.Event.from(
    kind: EventKind.agentObserverFrame,
    content: nip44Encrypt(conversationKey, jsonEncode(payload)),
    tags: [
      ['p', agent],
      ['agent', agent],
      ['frame', 'control'],
    ],
    secretKey: ownerPrivkeyHex,
    createdAt: createdAt,
    verify: false,
  );
  return NostrEvent.fromJson(event.toMap());
}

/// The `cancel_turn` control payload that stops exactly [turnId]. Send it only
/// to a turn whose telemetry advertised `cancelByTurnId: true`; an older
/// runtime ignores `turnId` and cancels whatever runs in the channel.
Map<String, Object?> cancelTurnPayload({
  required String channelId,
  required String turnId,
  required String requestId,
}) => {
  'type': 'cancel_turn',
  'channelId': channelId,
  'turnId': turnId,
  'requestId': requestId,
};
