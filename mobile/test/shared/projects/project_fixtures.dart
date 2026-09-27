import 'dart:convert';

import 'package:buzz/shared/relay/nostr_models.dart';
import 'package:nostr/nostr.dart' as nostr;
import 'package:pointycastle/digests/sha256.dart';

/// Real-shaped relay fixtures for the project data layer tests.
///
/// Pubkeys are 64-char lowercase hex, channel ids are v4 UUIDs, and clone
/// URLs follow the Buzz relay (`<origin>/git/<owner>/<repo>`) and GitHub
/// shapes that `buzz repos create` and `buzz projects create` publish.
///
/// Events by a key from [testKey] (and alice, bob, carol, and agent) carry a
/// real id and signature, so they pass verification on receipt. Other authors
/// get a placeholder signature that fails it.
const relayOrigin = 'https://buzz.example.com';

// Public test-only secrets: `a` * 63 + n.
const alice =
    'f2dafe376020f5c6d5a6a2429eb0b646e587e7296a8a308e1db9ddfe568a2f8e';
const bob = 'cef96df569ac9c6a6f182a64aaa1eae76e65127e363414f0419e7c7e572eb18a';
const carol =
    'c70be00355d81b1c9893a62c61c26060dc9e1da374c91e2570974cc918cbc433';

/// An agent key whose NIP-OA owner is established per test with [oaAuthTag].
const agent =
    '8c1a47dcde1648404a6b830041e912c1e703cd96f4eeb026de78ad052f9625e6';

final Map<String, String> _secrets = {
  for (var n = 1; n <= 4; n++) nostr.Keys(_secret(n)).public: _secret(n),
};

String _secret(int n) => n.toRadixString(16).padLeft(64, 'a');

/// A signable test pubkey for any positive [n]; 1–4 are alice, bob, carol,
/// and agent.
String testKey(int n) {
  final secret = _secret(n);
  final pubkey = nostr.Keys(secret).public;
  _secrets[pubkey] = secret;
  return pubkey;
}

/// A NIP-OA `auth` tag in which [owner] attests [agentPubkey].
List<String> oaAuthTag(
  String owner,
  String agentPubkey, {
  String conditions = '',
}) {
  final preimage = utf8.encode('nostr:agent-auth:$agentPubkey:$conditions');
  final digest = SHA256Digest()
      .process(preimage)
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join();
  final sig = nostr.Schnorr.sign(secretKey: _secrets[owner]!, message: digest);
  return ['auth', owner, conditions, sig];
}

/// A stream (chat) channel used as a project home.
const streamHomeChannel = '0f8e5b1c-3a2d-4c6e-9b7a-1d2e3f4a5b6c';

/// A forum channel used as a project home.
const forumHomeChannel = '7c1d2e3f-4a5b-4c6d-8e9f-0a1b2c3d4e5f';

int _nextId = 0;

String _eventId() => (++_nextId).toRadixString(16).padLeft(64, '0');

/// A signed event by [pubkey] when its secret is known; otherwise an event
/// with a placeholder id and signature.
NostrEvent signedEvent({
  required String pubkey,
  required int kind,
  required int createdAt,
  required List<List<String>> tags,
  String content = '',
}) {
  final secret = _secrets[pubkey.toLowerCase()];
  if (secret == null) {
    return NostrEvent(
      id: _eventId(),
      pubkey: pubkey,
      createdAt: createdAt,
      kind: kind,
      content: content,
      sig: 'f' * 128,
      tags: tags,
    );
  }
  final event = nostr.Event.from(
    secretKey: secret,
    kind: kind,
    createdAt: createdAt,
    tags: tags,
    content: content,
  );
  return NostrEvent(
    id: event.id,
    pubkey: event.pubkey,
    createdAt: event.createdAt,
    kind: event.kind,
    content: event.content,
    sig: event.sig,
    tags: tags,
  );
}

/// [event] with [content] changed and its original id and signature, as a
/// relay forging content would serve it.
NostrEvent tampered(NostrEvent event, {String content = 'tampered'}) =>
    NostrEvent(
      id: event.id,
      pubkey: event.pubkey,
      createdAt: event.createdAt,
      kind: event.kind,
      content: content,
      sig: event.sig,
      tags: event.tags,
    );

NostrEvent repoEvent({
  required String owner,
  required String dtag,
  int createdAt = 1_700_000_000,
  String? name,
  String? description,
  List<String>? clone,
  String? web,
  String? channel,
  List<String> maintainers = const [],
  List<List<String>> extraTags = const [],
}) => signedEvent(
  pubkey: owner,
  createdAt: createdAt,
  kind: EventKind.repoAnnouncement,
  tags: [
    ['d', dtag],
    if (name != null) ['name', name],
    if (description != null) ['description', description],
    if (clone != null) ['clone', ...clone],
    if (web != null) ['web', web],
    ['relays', 'wss://buzz.example.com'],
    if (maintainers.isNotEmpty) ['maintainers', ...maintainers],
    if (channel != null) ['buzz-channel', channel],
    ...extraTags,
  ],
);

NostrEvent projectEvent({
  required String owner,
  required String dtag,
  required List<String> repoAddresses,
  int createdAt = 1_700_000_100,
  String? name,
  String? description,
  String? channel,
  String? visibility,
  List<List<String>> extraTags = const [],
}) => signedEvent(
  pubkey: owner,
  createdAt: createdAt,
  kind: EventKind.projectAnnouncement,
  tags: [
    ['d', dtag],
    if (name != null) ['name', name],
    if (description != null) ['description', description],
    for (final address in repoAddresses) ['a', address],
    if (channel != null) ['buzz-channel', channel],
    if (visibility != null) ['buzz-visibility', visibility],
    ...extraTags,
  ],
);

NostrEvent deletionEvent({
  required String author,
  required List<String> coordinates,
  required int createdAt,
}) => signedEvent(
  pubkey: author,
  createdAt: createdAt,
  kind: EventKind.deletion,
  content: 'deleted',
  tags: [
    for (final coordinate in coordinates) ['a', coordinate],
    ['k', '${coordinate0Kind(coordinates)}'],
  ],
);

int coordinate0Kind(List<String> coordinates) =>
    int.parse(coordinates.first.split(':').first);

String repoAddress(String owner, String dtag) => '30617:$owner:$dtag';

String projectAddress(String owner, String dtag) => '30621:$owner:$dtag';

/// A community-shaped event set covering every read-model rule under test.
class CommunityFixture {
  /// Alice's GitHub-backed repository bound to the stream home.
  final githubRepo = repoEvent(
    owner: alice,
    dtag: 'buzz',
    name: 'buzz',
    description: 'Nostr-native team chat',
    clone: ['https://github.com/block/buzz.git'],
    web: 'https://github.com/block/buzz',
    channel: streamHomeChannel,
  );

  /// Alice's Buzz-hosted repository (no `clone` tag; URL is derived).
  final buzzHostedRepo = repoEvent(
    owner: alice,
    dtag: 'buzz-infra',
    name: 'buzz-infra',
    channel: streamHomeChannel,
  );

  /// Bob's repository listing Alice as a maintainer: Alice's project claims it
  /// only through `maintainers`.
  final maintainerRepo = repoEvent(
    owner: bob,
    dtag: 'forum-docs',
    name: 'Forum Docs',
    clone: ['$relayOrigin/git/$bob/forum-docs'],
    maintainers: [alice.toUpperCase()],
    channel: forumHomeChannel,
  );

  /// Carol's repository that no project claims: a legacy project.
  final legacyRepo = repoEvent(
    owner: carol,
    dtag: 'sandbox',
    name: 'Sandbox',
    description: 'Scratch repository',
    clone: ['https://gitlab.com/carol/sandbox.git'],
  );

  /// Bob's repository that Alice lists without authorization: stays legacy.
  final unauthorizedRepo = repoEvent(
    owner: bob,
    dtag: 'private-notes',
    name: 'Private Notes',
  );

  late final platformProject = projectEvent(
    owner: alice,
    dtag: 'platform',
    name: 'Platform',
    description: 'Relay, desktop, and mobile',
    channel: streamHomeChannel,
    repoAddresses: [
      repoAddress(alice, 'buzz'),
      repoAddress(alice, 'buzz-infra'),
      repoAddress(bob, 'private-notes'),
    ],
  );

  late final forumProject = projectEvent(
    owner: alice,
    dtag: 'docs',
    name: 'Docs',
    channel: forumHomeChannel,
    createdAt: 1_700_000_200,
    repoAddresses: [repoAddress(bob, 'forum-docs')],
  );

  late final deletedProject = projectEvent(
    owner: alice,
    dtag: 'retired',
    name: 'Retired',
    createdAt: 1_700_000_300,
    repoAddresses: [],
  );

  late final retiredTombstone = deletionEvent(
    author: alice,
    coordinates: [projectAddress(alice, 'retired')],
    createdAt: 1_700_000_400,
  );

  List<NostrEvent> get projectEvents => [
    platformProject,
    forumProject,
    deletedProject,
  ];

  List<NostrEvent> get repositoryEvents => [
    githubRepo,
    buzzHostedRepo,
    maintainerRepo,
    legacyRepo,
    unauthorizedRepo,
  ];

  List<NostrEvent> get deletionEvents => [retiredTombstone];

  List<NostrEvent> get allEvents => [
    ...projectEvents,
    ...repositoryEvents,
    ...deletionEvents,
  ];
}
