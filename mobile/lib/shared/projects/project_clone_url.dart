final _hexPubkey = RegExp(r'^[0-9a-fA-F]{64}$');

/// The canonical Buzz-hosted clone URL `<relay-origin>/git/<owner>/<dtag>`,
/// or null when the inputs cannot produce one.
///
/// Mirrors `deriveRelayCloneUrl` in
/// `desktop/src/features/projects/lib/projectCloneUrl.ts`.
String? deriveRelayCloneUrl(String? relayOrigin, String owner, String dtag) {
  if (relayOrigin == null || relayOrigin.isEmpty) return null;
  if (owner.isEmpty || dtag.isEmpty || !_hexPubkey.hasMatch(owner)) {
    return null;
  }
  final origin = relayOrigin.replaceFirst(RegExp(r'/+$'), '');
  return '$origin/git/${owner.toLowerCase()}/$dtag';
}

/// Explicit `clone` URLs when advertised, otherwise the derived Buzz-hosted
/// clone URL (or none). Explicit URLs always win — NIP-34 permits pointing
/// `clone` at an external host such as GitHub.
List<String> effectiveCloneUrls(
  List<String> cloneUrls,
  String? relayOrigin,
  String owner,
  String dtag,
) {
  if (cloneUrls.isNotEmpty) return cloneUrls;
  final derived = deriveRelayCloneUrl(relayOrigin, owner, dtag);
  return derived == null ? const [] : [derived];
}

/// The HTTP origin (`scheme://host[:port]`) of a relay base URL, or null.
String? relayOriginFromBaseUrl(String baseUrl) {
  final uri = Uri.tryParse(baseUrl);
  if (uri == null || !uri.hasScheme || uri.host.isEmpty) return null;
  final scheme = switch (uri.scheme) {
    'wss' => 'https',
    'ws' => 'http',
    final other => other,
  };
  final port = uri.hasPort ? ':${uri.port}' : '';
  return '$scheme://${uri.host}$port';
}
