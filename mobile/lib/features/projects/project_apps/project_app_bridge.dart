import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../../shared/deeplink/deep_link.dart';
import '../../../shared/projects/projects.dart';

/// JSON-RPC 2.0 error codes the app bridge replies with.
abstract final class ProjectAppRpcError {
  static const invalidRequest = -32600;
  static const methodNotFound = -32601;
  static const invalidParams = -32602;
  static const internalError = -32603;

  /// MCP Apps "implementation-defined" code for a request the host refused.
  static const denied = -32000;
}

/// Longest raw message the bridge decodes, in characters.
const maxProjectAppMessageLength = 64 * 1024;

/// Longest draft text a `ui/message` request may carry, in characters.
const maxProjectAppDraftLength = 8000;

/// A request the host refused; replied to the app as a JSON-RPC error.
class ProjectAppHostException implements Exception {
  const ProjectAppHostException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// What an embedded project app may ask Buzz to do.
///
/// Implementations throw [ProjectAppHostException] to refuse a request.
abstract interface class ProjectAppHost {
  /// Puts [text] into a draft in the project's home channel and shows it.
  /// Never sends it.
  Future<void> draftMessage(String text);

  /// Opens a validated `buzz://` channel or message link inside Buzz.
  Future<void> openBuzzLink(Uri uri);

  /// Opens a validated `https:` link in a new browser tab.
  Future<void> openWebLink(Uri uri);
}

/// Whether a `message` event may reach the bridge for [app].
///
/// The event must come from [app]'s own frame ([fromAppFrame]) and from
/// [app]'s origin, and [app] must still be one of the current project's apps.
bool acceptsProjectAppMessage({
  required ProjectApp app,
  required List<ProjectApp> projectApps,
  required String origin,
  required bool fromAppFrame,
}) =>
    fromAppFrame &&
    origin == app.origin &&
    projectApps.any((candidate) => candidate.url == app.url);

/// Handles one `message` event from an embedded project app.
///
/// Returns the JSON-RPC response to post back to the app, or null when the
/// event is ignored: it failed [acceptsProjectAppMessage], is not a JSON-RPC
/// 2.0 request, or is a notification (no `id`).
///
/// Supports the MCP Apps (2026-01-26) requests `ui/message` and
/// `ui/open-link`; any other method gets "Method not found".
Future<Map<String, Object?>?> handleProjectAppMessage({
  required ProjectApp app,
  required List<ProjectApp> projectApps,
  required String origin,
  required bool fromAppFrame,
  required Object? data,
  required ProjectAppHost host,
}) async {
  if (!acceptsProjectAppMessage(
    app: app,
    projectApps: projectApps,
    origin: origin,
    fromAppFrame: fromAppFrame,
  )) {
    return null;
  }
  final request = _decodeRequest(data);
  if (request == null) return null;
  final id = request['id'];
  // Notifications get no reply and cause no action.
  if (!request.containsKey('id')) return null;
  if (id != null && id is! String && id is! num) {
    return _error(null, ProjectAppRpcError.invalidRequest, 'Invalid Request');
  }
  final params = request['params'];
  try {
    switch (request['method']) {
      case 'ui/message':
        final text = _messageText(params);
        if (text == null) {
          return _error(
            id,
            ProjectAppRpcError.invalidParams,
            'Invalid message format',
          );
        }
        if (text.length > maxProjectAppDraftLength) {
          return _error(
            id,
            ProjectAppRpcError.invalidParams,
            'Message is too long',
          );
        }
        await host.draftMessage(text);
        return _result(id);
      case 'ui/open-link':
        final url = params is Map ? params['url'] : null;
        if (url is! String) {
          return _error(id, ProjectAppRpcError.invalidParams, 'Invalid URL');
        }
        final link = classifyProjectAppLink(url);
        switch (link) {
          case ProjectAppBuzzLink(:final uri):
            await host.openBuzzLink(uri);
          case ProjectAppWebLink(:final uri):
            await host.openWebLink(uri);
          case null:
            return _error(id, ProjectAppRpcError.denied, 'Policy violation');
        }
        return _result(id);
      default:
        return _error(
          id,
          ProjectAppRpcError.methodNotFound,
          'Method not found',
        );
    }
  } on ProjectAppHostException catch (error) {
    return _error(id, ProjectAppRpcError.denied, error.message);
  } catch (error) {
    debugPrint('project-app: ${request['method']} failed: $error');
    return _error(id, ProjectAppRpcError.internalError, 'Internal error');
  }
}

/// A link an app asked Buzz to open.
sealed class ProjectAppLink {
  const ProjectAppLink(this.uri);

  final Uri uri;
}

/// A `buzz://` channel or message link, opened inside Buzz.
final class ProjectAppBuzzLink extends ProjectAppLink {
  const ProjectAppBuzzLink(super.uri);
}

/// An `https:` link, opened in a new browser tab.
final class ProjectAppWebLink extends ProjectAppLink {
  const ProjectAppWebLink(super.uri);
}

/// Classifies [url] for `ui/open-link`, or null when Buzz must refuse it.
///
/// Accepts `buzz://` channel and message links, and `https:` URLs with a host
/// and no user info. Refuses every other scheme and other `buzz://` links
/// (such as community invites).
ProjectAppLink? classifyProjectAppLink(String url) {
  if (url.length > maxProjectAppUrlLength) return null;
  final uri = Uri.tryParse(url.trim());
  if (uri == null) return null;
  if (uri.scheme == 'buzz') {
    return switch (parseBuzzDeepLink(uri)) {
      ChannelDeepLink() || MessageDeepLink() => ProjectAppBuzzLink(uri),
      _ => null,
    };
  }
  final web = parseProjectAppUrl(url);
  return web == null ? null : ProjectAppWebLink(web);
}

/// The request object in [data], or null when it is not JSON-RPC 2.0.
///
/// [data] is the structured-clone payload (a map) or a JSON string.
Map<Object?, Object?>? _decodeRequest(Object? data) {
  var value = data;
  if (value is String) {
    if (value.length > maxProjectAppMessageLength) return null;
    try {
      value = jsonDecode(value);
    } on FormatException {
      return null;
    }
  }
  if (value is! Map) return null;
  if (value['jsonrpc'] != '2.0' || value['method'] is! String) return null;
  return value;
}

/// The draft text of `ui/message` params, or null when malformed.
///
/// `content` is one text block (as in the MCP Apps spec) or a list of blocks
/// (as in the ext-apps SDK). Every block must be text.
String? _messageText(Object? params) {
  if (params is! Map || params['role'] != 'user') return null;
  final content = params['content'];
  final blocks = content is List ? content : [content];
  final parts = <String>[];
  for (final block in blocks) {
    if (block is! Map || block['type'] != 'text') return null;
    final text = block['text'];
    if (text is! String) return null;
    if (text.trim().isNotEmpty) parts.add(text.trim());
  }
  return parts.isEmpty ? null : parts.join('\n\n');
}

Map<String, Object?> _result(Object? id) => {
  'jsonrpc': '2.0',
  'id': id,
  'result': const <String, Object?>{},
};

Map<String, Object?> _error(Object? id, int code, String message) => {
  'jsonrpc': '2.0',
  'id': id,
  'error': {'code': code, 'message': message},
};
