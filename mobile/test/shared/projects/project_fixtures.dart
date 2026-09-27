import 'package:buzz/shared/relay/nostr_models.dart';

/// Real-shaped relay fixtures for the project data layer tests.
///
/// Pubkeys are 64-char lowercase hex, channel ids are v4 UUIDs, and clone
/// URLs follow the Buzz relay (`<origin>/git/<owner>/<repo>`) and GitHub
/// shapes that `buzz repos create` and `buzz projects create` publish.
const relayOrigin = 'https://buzz.example.com';

const alice =
    '3bf0c63fcb93463407af97a5e5ee64fa883d107ef9e558472c4eb9aaaefa459d';
const bob = '82341f882b6eabcd2ba7f1ef90aad961cf074af15b9ef44a09f9d2a8fbfbe6a2';
const carol =
    'e88a691e98d9987c964521dff60025f60700378a4879180dcbbb4a5027850411';

/// A stream (chat) channel used as a project home.
const streamHomeChannel = '0f8e5b1c-3a2d-4c6e-9b7a-1d2e3f4a5b6c';

/// A forum channel used as a project home.
const forumHomeChannel = '7c1d2e3f-4a5b-4c6d-8e9f-0a1b2c3d4e5f';

int _nextId = 0;

String _eventId() => (++_nextId).toRadixString(16).padLeft(64, '0');

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
  String? id,
}) => NostrEvent(
  id: id ?? _eventId(),
  pubkey: owner,
  createdAt: createdAt,
  kind: EventKind.repoAnnouncement,
  content: '',
  sig: 'f' * 128,
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
}) => NostrEvent(
  id: _eventId(),
  pubkey: owner,
  createdAt: createdAt,
  kind: EventKind.projectAnnouncement,
  content: '',
  sig: 'f' * 128,
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
}) => NostrEvent(
  id: _eventId(),
  pubkey: author,
  createdAt: createdAt,
  kind: EventKind.deletion,
  content: 'deleted',
  sig: 'f' * 128,
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
