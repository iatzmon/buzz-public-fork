import 'package:characters/characters.dart';
import 'package:flutter/foundation.dart';

/// Repeatable project tag naming a web app: `["buzz-app", url, label]`.
///
/// Client convention documented in `docs/nips/NIP-MP.md`; the relay passes it
/// through as an unrecognized tag.
const projectAppTag = 'buzz-app';

/// Cap on apps read from one project so a tag list cannot grow without bound.
const maxProjectApps = 20;

/// Longest app URL a client accepts, in characters.
const maxProjectAppUrlLength = 2048;

/// Longest label a client shows, in characters; longer labels are cut.
const maxProjectAppLabelLength = 80;

/// A web app linked from a project with a `buzz-app` tag.
@immutable
class ProjectApp {
  const ProjectApp._({required this.uri, required this.label});

  /// The app's address. Always `https:` with a host and no user info.
  final Uri uri;

  /// The tag's label, or the URL host when the tag has none.
  final String label;

  /// The URL as written in the tag, normalized by [Uri].
  String get url => uri.toString();

  /// `https://host[:port]`, compared with a browser `MessageEvent.origin`.
  String get origin => uri.origin;

  String get host => uri.host;

  @override
  bool operator ==(Object other) =>
      other is ProjectApp && other.url == url && other.label == label;

  @override
  int get hashCode => Object.hash(url, label);
}

/// Parses [raw] as a project app URL, or null when it is not an `https:` URL
/// with a host, or when it carries user info.
Uri? parseProjectAppUrl(String raw) {
  final value = raw.trim();
  if (value.isEmpty || value.length > maxProjectAppUrlLength) return null;
  final uri = Uri.tryParse(value);
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty) {
    return null;
  }
  return uri;
}

/// The project's apps from its `buzz-app` tags, in tag order.
///
/// Skips tags whose URL is not accepted by [parseProjectAppUrl], keeps the
/// first tag for a repeated URL, and reads at most [maxProjectApps] apps.
List<ProjectApp> projectAppsFromTags(List<List<String>> tags) {
  final apps = <ProjectApp>[];
  final seen = <String>{};
  for (final tag in tags) {
    if (apps.length >= maxProjectApps) break;
    if (tag.length < 2 || tag[0] != projectAppTag) continue;
    final uri = parseProjectAppUrl(tag[1]);
    if (uri == null || !seen.add(uri.toString())) continue;
    final rawLabel = (tag.length > 2 ? tag[2].trim() : '').characters;
    final label = rawLabel.isEmpty
        ? uri.host
        : rawLabel.length > maxProjectAppLabelLength
        ? '${rawLabel.take(maxProjectAppLabelLength - 1)}…'
        : rawLabel.toString();
    apps.add(ProjectApp._(uri: uri, label: label));
  }
  return List.unmodifiable(apps);
}
