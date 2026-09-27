import 'dart:convert';
import 'dart:typed_data';

import 'package:nostr/nostr.dart' as nostr;
import 'package:pointycastle/digests/sha256.dart';

import '../relay/nostr_models.dart';

/// NIP-OA (Owner Attestation) — verify the `auth` tag on a kind:0 profile
/// that proves an owner key authorized an agent key.
///
/// Tag format: ["auth", "<owner-pubkey-hex>", "<conditions>", "<sig-hex>"]
/// Preimage:   "nostr:agent-auth:" + agent_pubkey_hex + ":" + conditions
/// Signature:  BIP-340 Schnorr over SHA256(preimage) by the owner key.
///
/// Mirrors `profile_valid_oa_owner_pubkey` in desktop/src-tauri: the tag is
/// verified against the profile event author, so a forged or stale marker
/// cannot turn a person into an agent.
///
/// Returns the owner pubkey (lowercase hex) for the first valid auth tag,
/// or null if none verifies.
String? verifiedOaOwnerPubkey(List<List<String>> tags, String agentPubkey) {
  final agent = agentPubkey.toLowerCase();

  for (final tag in tags) {
    if (tag.length != 4 || tag[0] != 'auth') continue;

    final owner = tag[1].toLowerCase();
    final conditions = tag[2];
    final sig = tag[3];

    // Self-attestation is meaningless and rejected.
    if (owner == agent) continue;
    if (owner.length != 64 || sig.length != 128) continue;
    if (!_validConditions(conditions)) continue;

    final preimage = utf8.encode('nostr:agent-auth:$agent:$conditions');
    final digest = SHA256Digest().process(Uint8List.fromList(preimage));
    final message = digest
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();

    try {
      if (nostr.Schnorr.verify(
        publicKey: owner,
        message: message,
        signature: sig,
      )) {
        return owner;
      }
    } catch (_) {
      // Malformed hex — treat as an invalid tag.
    }
  }

  return null;
}

final _lowercaseHex = RegExp(r'^[0-9a-f]+$');

/// The verified NIP-OA owner of the agent that signed `profile`, or null.
///
/// Stricter than [verifiedOaOwnerPubkey] and mirrors desktop's
/// `profile_valid_oa_owner_pubkey`, so owner-only decisions agree across
/// clients:
/// - `profile` must be kind 0 with a valid event id and signature.
/// - It must carry exactly one `auth` tag; a duplicate (even malformed)
///   rejects the profile rather than falling back to another tag.
/// - The owner key and signature must be canonical lowercase hex.
/// - Every signed condition must hold for the profile event itself
///   (`kind=`, `created_at<`, `created_at>`), judged by event time, not
///   wall-clock time.
String? verifiedProfileOaOwnerPubkey(NostrEvent profile) {
  if (profile.kind != 0) return null;

  final authTags = [
    for (final tag in profile.tags)
      if (tag.isNotEmpty && tag[0] == 'auth') tag,
  ];
  if (authTags.length != 1) return null;
  final tag = authTags.single;
  if (tag.length != 4) return null;
  if (!_lowercaseHex.hasMatch(tag[1]) || !_lowercaseHex.hasMatch(tag[3])) {
    return null;
  }

  if (!_validEventSignature(profile)) return null;

  final owner = verifiedOaOwnerPubkey([tag], profile.pubkey);
  if (owner == null) return null;
  return _conditionsHold(tag[2], profile) ? owner : null;
}

bool _validEventSignature(NostrEvent event) {
  try {
    return nostr.Event(
      event.id,
      event.pubkey,
      event.createdAt,
      event.kind,
      event.tags,
      event.content,
      event.sig,
      verify: false,
    ).isValid();
  } catch (_) {
    return false;
  }
}

/// Evaluates already-validated `conditions` against `event`.
bool _conditionsHold(String conditions, NostrEvent event) {
  if (conditions.isEmpty) return true;
  return conditions.split('&').every((clause) {
    if (clause.startsWith('kind=')) {
      return int.tryParse(clause.substring(5)) == event.kind;
    }
    if (clause.startsWith('created_at<')) {
      final bound = int.tryParse(clause.substring(11));
      return bound != null && event.createdAt < bound;
    }
    if (clause.startsWith('created_at>')) {
      final bound = int.tryParse(clause.substring(11));
      return bound != null && event.createdAt > bound;
    }
    return false;
  });
}

/// Validate the NIP-OA `conditions` string: empty, or `&`-joined clauses of
/// `kind=<n>`, `created_at<<n>`, or `created_at><n>` with canonical decimals.
bool _validConditions(String conditions) {
  if (conditions.isEmpty) return true;
  if (conditions.contains(RegExp(r'\s'))) return false;

  for (final clause in conditions.split('&')) {
    final match = RegExp(
      r'^(?:kind=|created_at<|created_at>)(0|[1-9][0-9]*)$',
    ).firstMatch(clause);
    if (match == null) return false;
    final value = int.tryParse(match.group(1)!);
    if (value == null || value > 4294967295) return false;
    if (clause.startsWith('kind=') && value > 65535) return false;
  }

  return true;
}
