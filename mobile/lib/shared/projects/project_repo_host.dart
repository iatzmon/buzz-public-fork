import 'package:flutter/foundation.dart';

import 'project_clone_url.dart';
import 'project_models.dart';

/// Where a repository's git data lives, relative to the active relay.
sealed class ProjectRepoHost {
  const ProjectRepoHost();
}

/// Hosted by the active Buzz relay at `<relay-origin>/git/<owner>/<repo>`.
final class BuzzRepoHost extends ProjectRepoHost {
  const BuzzRepoHost();

  @override
  bool operator ==(Object other) => other is BuzzRepoHost;

  @override
  int get hashCode => (BuzzRepoHost).hashCode;
}

/// Hosted elsewhere, e.g. `github.com`. [host] includes a non-default port.
final class ExternalRepoHost extends ProjectRepoHost {
  final String host;
  const ExternalRepoHost(this.host);

  @override
  bool operator ==(Object other) =>
      other is ExternalRepoHost && other.host == host;

  @override
  int get hashCode => host.hashCode;
}

/// No clone URL or relay origin could be resolved.
final class UnresolvedRepoHost extends ProjectRepoHost {
  const UnresolvedRepoHost();

  @override
  bool operator ==(Object other) => other is UnresolvedRepoHost;

  @override
  int get hashCode => (UnresolvedRepoHost).hashCode;
}

final _buzzGitPath = RegExp(
  r'^/git/[0-9a-f]{64}/[^/]+/?$',
  caseSensitive: false,
);

/// Classifies [cloneUrl] against [relayOrigin] with the same origin and path
/// boundary Desktop uses (`projectRepoHost` in
/// `desktop/src/features/projects/lib/projectRepoHost.ts`). Presentation only.
ProjectRepoHost classifyRepoHost(String? cloneUrl, String? relayOrigin) {
  if (cloneUrl == null || cloneUrl.isEmpty) return const UnresolvedRepoHost();
  if (relayOrigin == null || relayOrigin.isEmpty) {
    return const UnresolvedRepoHost();
  }
  final clone = _absoluteUri(cloneUrl);
  final relay = _absoluteUri(relayOrigin);
  if (clone == null || relay == null) return const UnresolvedRepoHost();
  final sameOrigin =
      clone.scheme == relay.scheme &&
      _hostWithPort(clone) == _hostWithPort(relay);
  if (sameOrigin && _buzzGitPath.hasMatch(clone.path)) {
    return const BuzzRepoHost();
  }
  return ExternalRepoHost(_hostWithPort(clone));
}

/// Classifies a repository by its first effective clone URL.
ProjectRepoHost repoHostForRepository(
  ProjectRepository? repository,
  String? relayOrigin,
) {
  if (repository == null) return const UnresolvedRepoHost();
  final cloneUrl = effectiveCloneUrls(
    repository.cloneUrls,
    relayOrigin,
    repository.owner,
    repository.dtag,
  ).firstOrNull;
  return classifyRepoHost(cloneUrl, relayOrigin);
}

/// Presentation facts a repository row needs.
@immutable
class ProjectRepoPresentation {
  final ProjectRepoHost host;

  /// The `web` tag when it is an http(s) URL.
  final String? webUrl;

  /// The link for an "Open on `host`" action: [webUrl] for external repos
  /// only, matching Desktop's `useProjectRepoPresentation`.
  final String? externalUrl;

  const ProjectRepoPresentation({
    required this.host,
    required this.webUrl,
    required this.externalUrl,
  });
}

/// Host classification plus a safe web link for [repository].
ProjectRepoPresentation projectRepoPresentation(
  ProjectRepository? repository,
  String? relayOrigin,
) {
  final host = repoHostForRepository(repository, relayOrigin);
  final raw = repository?.webUrl;
  final webUrl = raw != null && isSafeHttpUrl(raw) ? raw : null;
  return ProjectRepoPresentation(
    host: host,
    webUrl: webUrl,
    externalUrl: host is ExternalRepoHost ? webUrl : null,
  );
}

/// Human-readable location: `github.com/org/repo` for external repositories
/// (`.git` stripped) or `<ownerLabel>/<dtag>` for Buzz-hosted ones, where
/// [ownerLabel] falls back to a shortened owner pubkey.
String? repositoryDisplayPath(
  ProjectRepository? repository,
  String? relayOrigin, {
  String? ownerLabel,
}) {
  if (repository == null) return null;
  final cloneUrl = effectiveCloneUrls(
    repository.cloneUrls,
    relayOrigin,
    repository.owner,
    repository.dtag,
  ).firstOrNull;
  if (cloneUrl == null) return null;
  if (classifyRepoHost(cloneUrl, relayOrigin) is BuzzRepoHost) {
    final label = ownerLabel?.trim();
    final owner = label != null && label.isNotEmpty
        ? label
        : '${repository.owner.substring(0, 8)}…';
    return '$owner/${repository.dtag}';
  }
  final uri = _absoluteUri(cloneUrl);
  if (uri == null) return null;
  final path = uri.path
      .replaceFirst(RegExp(r'\.git$'), '')
      .replaceFirst(RegExp(r'/+$'), '');
  return '${_hostWithPort(uri)}$path';
}

/// Whether [url] parses as an absolute http or https URL.
bool isSafeHttpUrl(String url) {
  final uri = _absoluteUri(url);
  return uri != null && (uri.scheme == 'http' || uri.scheme == 'https');
}

Uri? _absoluteUri(String value) {
  final uri = Uri.tryParse(value);
  if (uri == null || !uri.hasScheme || uri.host.isEmpty) return null;
  return uri;
}

String _hostWithPort(Uri uri) =>
    uri.hasPort ? '${uri.host}:${uri.port}' : uri.host;
