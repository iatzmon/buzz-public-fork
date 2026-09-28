import 'package:flutter/foundation.dart';

/// Whether a NIP-MP project is listed in the community's project directory.
enum ProjectVisibility { listed, unlisted }

/// A NIP-34 repository announcement (kind:30617) read model.
///
/// Mirrors Desktop's `Repository` in
/// `desktop/src/features/projects/projectModels.ts`.
@immutable
class ProjectRepository {
  /// `<owner>:<dtag>`.
  final String id;
  final String dtag;

  /// The `name` tag, falling back to [dtag].
  final String name;
  final String description;

  /// Advertised `clone` URLs, or the derived Buzz-hosted clone URL when the
  /// announcement advertises none (see `effectiveCloneUrls`).
  final List<String> cloneUrls;

  /// The raw `web` tag. Use `projectRepoPresentation` before opening it.
  final String? webUrl;

  /// Lowercase hex pubkey of the announcement signer.
  final String owner;

  /// Union of `p` and `auth` tag values.
  final List<String> contributors;
  final int createdAt;
  final String status;
  final String defaultBranch;

  /// `30617:<owner>:<dtag>` coordinate.
  final String repoAddress;

  /// Lowercase hex pubkeys from the NIP-34 `maintainers` tag(s).
  final List<String> maintainers;

  /// The validated `buzz-channel` UUID, if any.
  final String? channelId;

  const ProjectRepository({
    required this.id,
    required this.dtag,
    required this.name,
    required this.description,
    required this.cloneUrls,
    required this.webUrl,
    required this.owner,
    required this.contributors,
    required this.createdAt,
    required this.status,
    required this.defaultBranch,
    required this.repoAddress,
    required this.maintainers,
    required this.channelId,
  });

  /// Whether [pubkey] signs this repository or is listed as a maintainer.
  bool authorizes(String pubkey) {
    final normalized = pubkey.toLowerCase();
    return owner == normalized || maintainers.contains(normalized);
  }
}

/// A project read model: either an announced NIP-MP project (kind:30621) or a
/// legacy project synthesized from an unclaimed repository ([legacy] true).
///
/// Mirrors Desktop's `Project` in
/// `desktop/src/features/projects/projectModels.ts`.
@immutable
class Project {
  /// The project coordinate ([projectAddress]); for legacy projects this is
  /// the repository coordinate.
  final String id;
  final String dtag;
  final String name;
  final String description;

  /// Lowercase hex pubkey of the project signer.
  final String owner;
  final int createdAt;

  /// The project home channel (`buzz-channel` tag). Always null for legacy
  /// projects. The home may be a stream or a forum channel; only the id is
  /// recorded here. Use `findProjectHomeByChannelId` to resolve an
  /// authoritative home.
  final String? projectChannelId;

  /// Extra streams from repeatable `buzz-related-channel` tags.
  final List<String> relatedChannelIds;

  /// `active`, `unlisted`, or the legacy repository's `status` tag.
  final String status;

  /// `30621:<owner>:<dtag>`, or the repository coordinate for legacy projects.
  final String projectAddress;
  final String? primaryRepositoryAddress;

  /// Sorted member repository coordinates.
  final List<String> repositoryAddresses;

  /// Relay hint per member coordinate, from the third `a` tag element.
  final Map<String, String> repositoryRelayHints;

  /// Resolved, visible member repositories.
  final List<ProjectRepository> repositories;

  /// Member coordinates with no resolvable repository announcement.
  final List<String> unavailableRepositoryAddresses;
  final ProjectVisibility visibility;

  /// True when synthesized from a repository no NIP-MP project claims.
  final bool legacy;

  const Project({
    required this.id,
    required this.dtag,
    required this.name,
    required this.description,
    required this.owner,
    required this.createdAt,
    required this.projectChannelId,
    required this.relatedChannelIds,
    required this.status,
    required this.projectAddress,
    required this.primaryRepositoryAddress,
    required this.repositoryAddresses,
    required this.repositoryRelayHints,
    required this.repositories,
    required this.unavailableRepositoryAddresses,
    required this.visibility,
    required this.legacy,
  });

  /// True for an announced NIP-MP project, excluding repository-only models.
  bool get isExplicit => !legacy;

  /// The primary repository, else the first resolved repository.
  ProjectRepository? get primaryRepository {
    for (final repository in repositories) {
      if (repository.repoAddress == primaryRepositoryAddress) {
        return repository;
      }
    }
    return repositories.isEmpty ? null : repositories.first;
  }

  /// Returns a copy with [repository] appended to the member set.
  Project withAbsorbedRepository(ProjectRepository repository) {
    if (repositoryAddresses.contains(repository.repoAddress)) return this;
    return Project(
      id: id,
      dtag: dtag,
      name: name,
      description: description,
      owner: owner,
      createdAt: createdAt,
      projectChannelId: projectChannelId,
      relatedChannelIds: relatedChannelIds,
      status: status,
      projectAddress: projectAddress,
      primaryRepositoryAddress:
          primaryRepositoryAddress ?? repository.repoAddress,
      repositoryAddresses: List.unmodifiable([
        ...repositoryAddresses,
        repository.repoAddress,
      ]),
      repositoryRelayHints: repositoryRelayHints,
      repositories: List.unmodifiable([...repositories, repository]),
      unavailableRepositoryAddresses: unavailableRepositoryAddresses,
      visibility: visibility,
      legacy: legacy,
    );
  }
}
