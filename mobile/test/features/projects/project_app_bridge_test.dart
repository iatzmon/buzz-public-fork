import 'dart:convert';

import 'package:buzz/features/projects/project_apps/project_app_bridge.dart';
import 'package:buzz/shared/projects/projects.dart';
import 'package:flutter_test/flutter_test.dart';

const _channel = '7c1d2e3f-4a5b-4c6d-8e9f-0a1b2c3d4e5f';
const _messageId =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

final _apps = projectAppsFromTags([
  ['buzz-app', 'https://side-hustles.acs.example.com/', 'Side Hustles'],
  ['buzz-app', 'https://board.example.com/app', 'Board'],
]);
final _app = _apps.first;

class _Host implements ProjectAppHost {
  final drafts = <String>[];
  final buzzLinks = <Uri>[];
  final webLinks = <Uri>[];
  Object? failWith;

  @override
  Future<void> draftMessage(String text) async {
    if (failWith case final error?) throw error;
    drafts.add(text);
  }

  @override
  Future<void> openBuzzLink(Uri uri) async {
    if (failWith case final error?) throw error;
    buzzLinks.add(uri);
  }

  @override
  Future<void> openWebLink(Uri uri) async {
    if (failWith case final error?) throw error;
    webLinks.add(uri);
  }
}

Future<Map<String, Object?>?> _send(
  _Host host,
  Object? data, {
  String origin = 'https://side-hustles.acs.example.com',
  bool fromAppFrame = true,
  List<ProjectApp>? projectApps,
}) => handleProjectAppMessage(
  app: _app,
  projectApps: projectApps ?? _apps,
  origin: origin,
  fromAppFrame: fromAppFrame,
  data: data,
  host: host,
);

Map<String, Object?> _uiMessage(Object? content, {Object? id = 7}) => {
  'jsonrpc': '2.0',
  'id': id,
  'method': 'ui/message',
  'params': {'role': 'user', 'content': content},
};

Map<String, Object?> _openLink(String url, {Object? id = 3}) => {
  'jsonrpc': '2.0',
  'id': id,
  'method': 'ui/open-link',
  'params': {'url': url},
};

Object? _errorCode(Map<String, Object?>? reply) =>
    (reply!['error']! as Map)['code'];

Object? _errorMessage(Map<String, Object?>? reply) =>
    (reply!['error']! as Map)['message'];

void main() {
  group('message acceptance', () {
    final request = _uiMessage({'type': 'text', 'text': 'hi'});

    test('accepts the app frame at the app origin', () async {
      final host = _Host();
      final reply = await _send(host, request);
      expect(reply, {'jsonrpc': '2.0', 'id': 7, 'result': <String, Object?>{}});
      expect(host.drafts, ['hi']);
    });

    test('ignores another origin, even one of the project apps', () async {
      final host = _Host();
      expect(
        await _send(host, request, origin: 'https://evil.example.com'),
        isNull,
      );
      expect(
        await _send(host, request, origin: 'https://board.example.com'),
        isNull,
      );
      expect(
        await _send(
          host,
          request,
          origin: 'http://side-hustles.acs.example.com',
        ),
        isNull,
      );
      expect(await _send(host, request, origin: 'null'), isNull);
      expect(host.drafts, isEmpty);
    });

    test('ignores messages from any window but the app frame', () async {
      final host = _Host();
      expect(await _send(host, request, fromAppFrame: false), isNull);
      expect(host.drafts, isEmpty);
    });

    test('ignores an app the project no longer lists', () async {
      final host = _Host();
      expect(await _send(host, request, projectApps: [_apps.last]), isNull);
      expect(host.drafts, isEmpty);
    });
  });

  group('JSON-RPC framing', () {
    test('ignores data that is not a JSON-RPC 2.0 request', () async {
      final host = _Host();
      for (final data in <Object?>[
        null,
        'hello',
        '{not json',
        42,
        const ['ui/message'],
        {'method': 'ui/message', 'id': 1},
        {'jsonrpc': '1.0', 'method': 'ui/message', 'id': 1},
        {'jsonrpc': '2.0', 'id': 1, 'result': <String, Object?>{}},
        {'jsonrpc': '2.0', 'method': 5, 'id': 1},
      ]) {
        expect(await _send(host, data), isNull, reason: '$data');
      }
      expect(host.drafts, isEmpty);
    });

    test('decodes a JSON string payload', () async {
      final host = _Host();
      final reply = await _send(
        host,
        jsonEncode(_uiMessage({'type': 'text', 'text': 'from json'})),
      );
      expect(reply!['result'], isEmpty);
      expect(host.drafts, ['from json']);
    });

    test('ignores an oversized JSON string', () async {
      final host = _Host();
      final text = 'x' * maxProjectAppMessageLength;
      expect(
        await _send(
          host,
          jsonEncode(_uiMessage({'type': 'text', 'text': text})),
        ),
        isNull,
      );
    });

    test('acts on no notification and replies to none', () async {
      final host = _Host();
      final notification = {
        'jsonrpc': '2.0',
        'method': 'ui/message',
        'params': {
          'role': 'user',
          'content': {'type': 'text', 'text': 'hi'},
        },
      };
      expect(await _send(host, notification), isNull);
      expect(
        await _send(host, {
          'jsonrpc': '2.0',
          'method': 'ui/notifications/initialized',
        }),
        isNull,
      );
      expect(host.drafts, isEmpty);
    });

    test('keeps string and number ids, and a null id', () async {
      final host = _Host();
      final content = {'type': 'text', 'text': 'hi'};
      expect((await _send(host, _uiMessage(content, id: 'a1')))!['id'], 'a1');
      expect((await _send(host, _uiMessage(content, id: 2.0)))!['id'], 2.0);
      final withNull = await _send(host, _uiMessage(content, id: null));
      expect(withNull!.containsKey('id'), isTrue);
      expect(withNull['id'], isNull);
    });

    test('answers an invalid id with Invalid Request', () async {
      final host = _Host();
      final reply = await _send(
        host,
        _uiMessage({'type': 'text', 'text': 'hi'}, id: const {'x': 1}),
      );
      expect(reply!['id'], isNull);
      expect(_errorCode(reply), ProjectAppRpcError.invalidRequest);
      expect(host.drafts, isEmpty);
    });

    test('answers any other method with Method not found', () async {
      final host = _Host();
      for (final method in ['tools/call', 'ui/initialize', 'ui/unknown']) {
        final reply = await _send(host, {
          'jsonrpc': '2.0',
          'id': 9,
          'method': method,
          'params': <String, Object?>{},
        });
        expect(reply!['id'], 9);
        expect(_errorCode(reply), ProjectAppRpcError.methodNotFound);
        expect(_errorMessage(reply), 'Method not found');
      }
    });
  });

  group('ui/message', () {
    test('accepts one text block (MCP Apps spec)', () async {
      final host = _Host();
      await _send(
        host,
        _uiMessage({'type': 'text', 'text': '  @Claude Forge dig deeper  '}),
      );
      expect(host.drafts, ['@Claude Forge dig deeper']);
    });

    test('accepts a list of text blocks (ext-apps SDK)', () async {
      final host = _Host();
      final reply = await _send(
        host,
        _uiMessage([
          {'type': 'text', 'text': 'First'},
          {'type': 'text', 'text': ''},
          {'type': 'text', 'text': 'Second'},
        ]),
      );
      expect(reply!['result'], isEmpty);
      expect(host.drafts, ['First\n\nSecond']);
    });

    test('rejects malformed params without drafting', () async {
      final host = _Host();
      final bad = <Object?>[
        null,
        {
          'role': 'assistant',
          'content': {'type': 'text', 'text': 'hi'},
        },
        {
          'content': {'type': 'text', 'text': 'hi'},
        },
        {'role': 'user'},
        {'role': 'user', 'content': 'hi'},
        {
          'role': 'user',
          'content': {'type': 'text', 'text': '   '},
        },
        {
          'role': 'user',
          'content': {'type': 'text', 'text': 5},
        },
        {
          'role': 'user',
          'content': [
            {'type': 'text', 'text': 'hi'},
            {'type': 'image', 'data': 'AAAA', 'mimeType': 'image/png'},
          ],
        },
        {'role': 'user', 'content': const <Object?>[]},
      ];
      for (final params in bad) {
        final reply = await _send(host, {
          'jsonrpc': '2.0',
          'id': 1,
          'method': 'ui/message',
          'params': params,
        });
        expect(_errorCode(reply), ProjectAppRpcError.invalidParams);
        expect(_errorMessage(reply), 'Invalid message format');
      }
      expect(host.drafts, isEmpty);
    });

    test('rejects text over the draft limit', () async {
      final host = _Host();
      final reply = await _send(
        host,
        _uiMessage({
          'type': 'text',
          'text': 'x' * (maxProjectAppDraftLength + 1),
        }),
      );
      expect(_errorCode(reply), ProjectAppRpcError.invalidParams);
      expect(host.drafts, isEmpty);
    });

    test('replies with the host refusal', () async {
      final host = _Host()
        ..failWith = const ProjectAppHostException(
          'This project has no home channel.',
        );
      final reply = await _send(
        host,
        _uiMessage({'type': 'text', 'text': 'hi'}),
      );
      expect(reply!['id'], 7);
      expect(_errorCode(reply), ProjectAppRpcError.denied);
      expect(_errorMessage(reply), 'This project has no home channel.');
    });

    test('replies Internal error when the host fails', () async {
      final host = _Host()..failWith = StateError('boom');
      final reply = await _send(
        host,
        _uiMessage({'type': 'text', 'text': 'hi'}),
      );
      expect(_errorCode(reply), ProjectAppRpcError.internalError);
    });
  });

  group('ui/open-link', () {
    test('routes buzz:// channel and message links inside Buzz', () async {
      final host = _Host();
      final channelLink = 'buzz://channel/$_channel';
      final messageLink = 'buzz://message?channel=$_channel&id=$_messageId';
      expect((await _send(host, _openLink(channelLink)))!['result'], isEmpty);
      expect((await _send(host, _openLink(messageLink)))!['result'], isEmpty);
      expect(host.buzzLinks.map((uri) => uri.toString()), [
        channelLink,
        messageLink,
      ]);
      expect(host.webLinks, isEmpty);
    });

    test('opens https links in a new tab', () async {
      final host = _Host();
      final reply = await _send(
        host,
        _openLink('https://www.reddit.com/r/sidehustle/comments/abc'),
      );
      expect(reply!['result'], isEmpty);
      expect(host.webLinks.single.host, 'www.reddit.com');
      expect(host.buzzLinks, isEmpty);
    });

    test('rejects every other link', () async {
      final host = _Host();
      for (final url in [
        'http://example.com/',
        'javascript:alert(1)',
        'data:text/html,hi',
        'file:///etc/passwd',
        'https://user:pw@example.com/',
        'buzz://join?relay=wss://evil.example.com&code=abc',
        'buzz://repo?owner=x&d=y',
        'buzz://channel/not-a-uuid',
        'not a url at all',
      ]) {
        final reply = await _send(host, _openLink(url));
        expect(_errorCode(reply), ProjectAppRpcError.denied, reason: url);
        expect(_errorMessage(reply), 'Policy violation', reason: url);
      }
      expect(host.buzzLinks, isEmpty);
      expect(host.webLinks, isEmpty);
    });

    test('rejects a missing url with Invalid URL', () async {
      final host = _Host();
      final reply = await _send(host, {
        'jsonrpc': '2.0',
        'id': 4,
        'method': 'ui/open-link',
        'params': {'href': 'https://example.com'},
      });
      expect(_errorCode(reply), ProjectAppRpcError.invalidParams);
      expect(_errorMessage(reply), 'Invalid URL');
    });
  });
}
