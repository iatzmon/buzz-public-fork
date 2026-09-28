import 'dart:convert';

import '../relay/nostr_models.dart';
import 'project_apps.dart';
import 'project_clone_url.dart';
import 'project_models.dart';

/// NIP-MP rule `member-cap`: a project carries at most 64 member `a` tags.
const maxProjectMembers = 64;

/// Repeatable project tag naming an extra stream besides `buzz-channel`.
const projectRelatedChannelTag = 'buzz-related-channel';

/// Cap on extra project streams so a tag list cannot grow without bound.
const maxProjectRelatedChannels = 64;

const _maxDTagBytes = 1024;
const _singletonMetadataTags = [
  'name',
  'description',
  'buzz-channel',
  'buzz-visibility',
];
const _maxMetadataTagBytes = {
  'name': 256,
  'description': 2048,
  'buzz-channel': 256,
  'buzz-visibility': 256,
};

final _anyCaseHexPubkey = RegExp(r'^[a-fA-F0-9]{64}$');
final _lowercaseHexPubkey = RegExp(r'^[0-9a-f]{64}$');
final _channelUuid = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
  caseSensitive: false,
);

/// Whether [value] is a Buzz channel UUID usable as a project channel binding.
bool isValidProjectChannelId(String value) => _channelUuid.hasMatch(value);

bool _isValidDTag(String value) =>
    value.isNotEmpty && utf8.encode(value).length <= _maxDTagBytes;

/// The first [name] tag's value, or null when that tag is absent or empty.
String? _tag(List<List<String>> tags, String name) {
  final value = _firstValue(tags, name);
  return value == null || value.isEmpty ? null : value;
}

List<String> _allTags(List<List<String>> tags, String name) => [
  for (final tag in tags)
    if (tag.length > 1 && tag[0] == name && tag[1].isNotEmpty) tag[1],
];

List<String> _allTagValues(List<List<String>> tags, String name) => [
  for (final tag in tags)
    if (tag.isNotEmpty && tag[0] == name)
      for (final value in tag.skip(1))
        if (value.isNotEmpty) value,
];

/// Parses a `30617:<lowercase-hex64>:<dtag>` member coordinate, or null.
({String owner, String dtag})? parseRepositoryAddress(String value) {
  final first = value.indexOf(':');
  if (first < 0) return null;
  final second = value.indexOf(':', first + 1);
  if (value.substring(0, first) != '${EventKind.repoAnnouncement}' ||
      second < 0) {
    return null;
  }
  final owner = value.substring(first + 1, second);
  final dtag = value.substring(second + 1);
  return _lowercaseHexPubkey.hasMatch(owner) && _isValidDTag(dtag)
      ? (owner: owner, dtag: dtag)
      : null;
}

/// Returns the first NIP-MP envelope violation of a kind:30621 tag list, or
/// null when the envelope is valid.
///
/// Mirrors `validateProjectEventEnvelope` in Desktop's `projectModels.ts`, so
/// a later write path can reuse it to reject the same heads the reader drops.
String? projectEnvelopeViolation(List<List<String>> tags) {
  final dTags = [
    for (final tag in tags)
      if (tag.isNotEmpty && tag[0] == 'd') tag,
  ];
  if (dTags.length != 1 || dTags[0].length < 2 || dTags[0][1].isEmpty) {
    return "expected exactly one non-empty 'd' tag, found ${dTags.length}";
  }
  if (!_isValidDTag(dTags[0][1])) {
    return "'d' tag value exceeds the maximum byte length";
  }
  for (final name in _singletonMetadataTags) {
    final count = tags.where((tag) => tag.isNotEmpty && tag[0] == name).length;
    if (count > 1) return "duplicate '$name' tag";
  }
  for (final entry in _maxMetadataTagBytes.entries) {
    final value = _firstValue(tags, entry.key);
    if (value != null && utf8.encode(value).length > entry.value) {
      return "'${entry.key}' tag exceeds the ${entry.value}-byte limit";
    }
  }
  final memberTags = [
    for (final tag in tags)
      if (tag.isNotEmpty && tag[0] == 'a') tag,
  ];
  if (memberTags.length > maxProjectMembers) {
    return 'project exceeds the $maxProjectMembers-member limit';
  }
  final seen = <String>{};
  for (final tag in memberTags) {
    if (tag.length < 2 || tag[1].isEmpty) {
      return "'a' tag is missing a repository address";
    }
    final address = tag[1];
    if (tag.length != 2 && tag.length != 3) {
      return "'a' tag for '$address' must have 2 or 3 elements";
    }
    if (parseRepositoryAddress(address) == null) {
      return "invalid repository address '$address'";
    }
    if (!seen.add(address)) return "duplicate repository address '$address'";
  }
  return null;
}

/// First value of a tag even when empty (envelope checks count raw tags).
String? _firstValue(List<List<String>> tags, String name) {
  for (final tag in tags) {
    if (tag.isNotEmpty && tag[0] == name) {
      return tag.length > 1 ? tag[1] : null;
    }
  }
  return null;
}

/// Parses a kind:30617 repository announcement, or null when malformed.
///
/// [relayOrigin] is used to derive the Buzz-hosted clone URL when the
/// announcement advertises no `clone` tag.
ProjectRepository? repositoryFromEvent(NostrEvent event, String? relayOrigin) {
  final dtag = _tag(event.tags, 'd');
  if (event.kind != EventKind.repoAnnouncement ||
      dtag == null ||
      !_isValidDTag(dtag) ||
      !_anyCaseHexPubkey.hasMatch(event.pubkey)) {
    return null;
  }
  final owner = event.pubkey.toLowerCase();
  List<String> cloneTagValues = const [];
  for (final tag in event.tags) {
    if (tag.isNotEmpty && tag[0] == 'clone') {
      cloneTagValues = [
        for (final value in tag.skip(1))
          if (value.isNotEmpty) value,
      ];
      break;
    }
  }
  final channel = _tag(event.tags, 'buzz-channel');
  return ProjectRepository(
    id: '$owner:$dtag',
    dtag: dtag,
    name: _tag(event.tags, 'name') ?? dtag,
    description: _tag(event.tags, 'description') ?? event.content,
    cloneUrls: List.unmodifiable(
      effectiveCloneUrls(cloneTagValues, relayOrigin, owner, dtag),
    ),
    webUrl: _tag(event.tags, 'web'),
    owner: owner,
    contributors: List.unmodifiable({
      ..._allTags(event.tags, 'p'),
      ..._allTags(event.tags, 'auth'),
    }),
    createdAt: event.createdAt,
    status: _tag(event.tags, 'status') ?? 'active',
    defaultBranch: _tag(event.tags, 'default-branch') ?? 'main',
    repoAddress: '${EventKind.repoAnnouncement}:$owner:$dtag',
    maintainers: List.unmodifiable([
      for (final maintainer in _allTagValues(event.tags, 'maintainers'))
        if (_anyCaseHexPubkey.hasMatch(maintainer)) maintainer.toLowerCase(),
    ]),
    channelId: channel != null && isValidProjectChannelId(channel)
        ? channel
        : null,
  );
}

/// Parses a kind:30621 NIP-MP project announcement, or null when invalid.
///
/// [repositoriesByAddress] holds every resolvable repository (to compute
/// unavailable members); [visibleRepositoriesByAddress] excludes hidden ones.
Project? explicitProjectFromEvent(
  NostrEvent event,
  Map<String, ProjectRepository> repositoriesByAddress,
  Map<String, ProjectRepository> visibleRepositoriesByAddress,
) {
  if (event.kind != EventKind.projectAnnouncement ||
      !_anyCaseHexPubkey.hasMatch(event.pubkey) ||
      projectEnvelopeViolation(event.tags) != null) {
    return null;
  }
  final dtag = _firstValue(event.tags, 'd')!;
  final repositoryAddresses = <String>[];
  final relayHints = <String, String>{};
  for (final tag in event.tags) {
    if (tag.isEmpty || tag[0] != 'a') continue;
    repositoryAddresses.add(tag[1]);
    if (tag.length > 2 && tag[2].isNotEmpty) relayHints[tag[1]] = tag[2];
  }
  repositoryAddresses.sort();
  String? primary;
  for (final address in repositoryAddresses) {
    if (visibleRepositoriesByAddress[address]?.dtag == dtag) {
      primary = address;
      break;
    }
  }
  primary ??= repositoryAddresses
      .where(visibleRepositoriesByAddress.containsKey)
      .firstOrNull;

  final owner = event.pubkey.toLowerCase();
  final projectAddress = '${EventKind.projectAnnouncement}:$owner:$dtag';
  final visibility = _tag(event.tags, 'buzz-visibility') == 'unlisted'
      ? ProjectVisibility.unlisted
      : ProjectVisibility.listed;
  final channel = _tag(event.tags, 'buzz-channel');
  final projectChannelId = channel != null && isValidProjectChannelId(channel)
      ? channel
      : null;
  final relatedChannelIds = {
    for (final id in _allTags(event.tags, projectRelatedChannelTag))
      if (isValidProjectChannelId(id) && id != projectChannelId) id,
  }.take(maxProjectRelatedChannels).toList(growable: false);

  return Project(
    id: projectAddress,
    dtag: dtag,
    name: _tag(event.tags, 'name') ?? dtag,
    description: _tag(event.tags, 'description') ?? '',
    owner: owner,
    createdAt: event.createdAt,
    projectChannelId: projectChannelId,
    relatedChannelIds: relatedChannelIds,
    status: visibility == ProjectVisibility.listed ? 'active' : 'unlisted',
    projectAddress: projectAddress,
    primaryRepositoryAddress: primary,
    repositoryAddresses: List.unmodifiable(repositoryAddresses),
    repositoryRelayHints: Map.unmodifiable(relayHints),
    repositories: List.unmodifiable([
      for (final address in repositoryAddresses)
        ?visibleRepositoriesByAddress[address],
    ]),
    unavailableRepositoryAddresses: List.unmodifiable(
      repositoryAddresses.where((a) => !repositoriesByAddress.containsKey(a)),
    ),
    visibility: visibility,
    legacy: false,
    apps: projectAppsFromTags(event.tags),
  );
}

/// Synthesizes a legacy project from a repository no NIP-MP project claims.
///
/// Legacy projects never have a home channel, matching Desktop's
/// `repositoryToLegacyProject`.
Project legacyProjectFromRepository(ProjectRepository repository) => Project(
  id: repository.repoAddress,
  dtag: repository.dtag,
  name: repository.name,
  description: repository.description,
  owner: repository.owner,
  createdAt: repository.createdAt,
  projectChannelId: null,
  relatedChannelIds: const [],
  status: repository.status,
  projectAddress: repository.repoAddress,
  primaryRepositoryAddress: repository.repoAddress,
  repositoryAddresses: List.unmodifiable([repository.repoAddress]),
  repositoryRelayHints: const {},
  repositories: List.unmodifiable([repository]),
  unavailableRepositoryAddresses: const [],
  visibility: ProjectVisibility.listed,
  legacy: true,
);
