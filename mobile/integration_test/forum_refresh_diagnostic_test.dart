import 'dart:convert';
import 'dart:io';

import 'package:buzz/features/forum/forum_thread_page.dart';
import 'package:buzz/shared/auth/auth_provider.dart';
import 'package:buzz/shared/mentions/agent_identity_provider.dart';
import 'package:buzz/shared/profile/user_cache_provider.dart';
import 'package:buzz/shared/profile/user_profile.dart';
import 'package:buzz/shared/relay/relay.dart';
import 'package:buzz/shared/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:integration_test/integration_test.dart';
import 'package:nostr/nostr.dart' as nostr;
import 'package:shared_preferences/shared_preferences.dart';

const channel = '11111111-1111-4111-8111-111111111111';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'forum refresh over real Android websocket transport',
    (tester) async {
      final relay = await ForumDiagnosticRelay.start();
      final identity = nostr.Keys.generate();
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final container = ProviderContainer(
        overrides: [
          savedPrefsProvider.overrideWithValue(prefs),
          authProvider.overrideWith(ForumDiagnosticAuth.new),
          relayConfigProvider.overrideWith(
            () => ForumDiagnosticConfig(relay.url, identity.nsec),
          ),
          userCacheProvider.overrideWith(ForumDiagnosticProfiles.new),
          knownAgentPubkeysProvider.overrideWithValue({}),
          channelBotPubkeysProvider(channel).overrideWith((ref) async => {}),
        ],
      );
      addTearDown(() async {
        container.dispose();
        await relay.close();
      });
      await container.read(authProvider.future);
      container.read(relaySessionProvider.notifier);
      Future<void> waitUntil(
        bool Function() ready,
        String label, {
        int seconds = 16,
      }) async {
        final deadline = DateTime.now().add(Duration(seconds: seconds));
        while (!ready() && DateTime.now().isBefore(deadline)) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(
          ready(),
          isTrue,
          reason:
              '$label; requests=${relay.requests}, connections=${relay.connections}',
        );
        debugPrint(
          'FORUM_DIAGNOSTIC PASS $label requests=${relay.requests} connections=${relay.connections}',
        );
      }

      await waitUntil(
        () =>
            container.read(relaySessionProvider).status ==
            SessionStatus.connected,
        'NIP-42 connected',
      );
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: AppTheme.light(),
            home: ForumThreadPage(
              channelId: channel,
              postEventId: relay.root['id'] as String,
              currentPubkey: null,
              isMember: false,
              isArchived: false,
            ),
          ),
        ),
      );
      await waitUntil(
        () => find
            .text('No replies yet. Be the first to respond.')
            .evaluate()
            .isNotEmpty,
        'initial empty thread',
      );
      relay.addReply('Reply while the thread stays open');
      await waitUntil(
        () => find
            .text('Reply while the thread stays open')
            .evaluate()
            .isNotEmpty,
        'ordinary polling shows new reply',
      );
      await binding.convertFlutterSurfaceToImage();
      await tester.pump();
      await binding.takeScreenshot('01-live-reply');

      await relay.disconnectClients();
      relay.addReply('Reply after connection recovery');
      await waitUntil(
        () =>
            find.text('Reply after connection recovery').evaluate().isNotEmpty,
        'closed socket reconnects and refreshes',
      );
      await binding.takeScreenshot('02-reconnected-reply');

      var sawPaused = false;
      final lifecycle = container.listen(appLifecycleProvider, (_, state) {
        if (state == AppLifecycleState.paused) {
          sawPaused = true;
          relay.addReply('Reply after returning to the app');
        }
      });
      addTearDown(lifecycle.close);
      debugPrint('FORUM_NATIVE_BACKGROUND_REQUEST');
      await waitUntil(
        () =>
            sawPaused &&
            container.read(appLifecycleProvider) == AppLifecycleState.resumed,
        'native Android pause and resume observed',
        seconds: 25,
      );
      await waitUntil(
        () =>
            find.text('Reply after returning to the app').evaluate().isNotEmpty,
        'background lifecycle recovery',
      );
      await binding.takeScreenshot('03-resumed-reply');

      // Keep TCP/websocket alive but withhold history responses. This is an
      // explicit fault injection, not a claim about the owner's connection.
      relay.stallCurrentConnections = true;
      relay.addReply('Reply held behind stalled history');
      await tester.pump(const Duration(seconds: 22));
      expect(find.text('Reply held behind stalled history'), findsNothing);
      debugPrint(
        'FORUM_DIAGNOSTIC OBSERVED stalled history hides new reply; errorVisible=${find.text('Failed to load thread').evaluate().isNotEmpty}; connections=${relay.connections}',
      );
      await binding.takeScreenshot('04-stalled-history');
      relay.stallCurrentConnections = false;
      final connectionsBeforeRecovery = relay.connections;
      await waitUntil(
        () => find
            .text('Reply held behind stalled history')
            .evaluate()
            .isNotEmpty,
        'history responses resume without restart or forced reconnect',
      );
      expect(relay.connections, connectionsBeforeRecovery);
      await binding.takeScreenshot('05-recovered-history');
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}

class ForumDiagnosticAuth extends AuthNotifier {
  @override
  Future<AuthState> build() async =>
      const AuthState(status: AuthStatus.authenticated);
}

class ForumDiagnosticConfig extends RelayConfigNotifier {
  ForumDiagnosticConfig(this.url, this.key);
  final String url;
  final String key;
  @override
  RelayConfig build() => RelayConfig(baseUrl: url, nsec: key);
}

class ForumDiagnosticProfiles extends UserCacheNotifier {
  @override
  Map<String, UserProfile> build() => {};
  @override
  UserProfile? get(String pubkey) =>
      UserProfile(pubkey: pubkey, displayName: 'Test participant');
}

class ForumDiagnosticRelay {
  ForumDiagnosticRelay(this.server) {
    root = event(45001, 'Forum refresh diagnostic', [
      ['h', channel],
    ]);
    server.listen((request) async {
      if (!WebSocketTransformer.isUpgradeRequest(request)) {
        var response = <Map<String, dynamic>>[];
        if (request.uri.path == '/query') {
          final filters =
              jsonDecode(await utf8.decoder.bind(request).join())
                  as List<dynamic>;
          for (final raw in filters) {
            final filter = raw as Map<String, dynamic>;
            if ((filter['kinds'] as List<dynamic>?)?.contains(45001) == true &&
                filter['top_level'] == true &&
                filter['include_summaries'] == true) {
              requests++;
              response.add(root);
              if (replies.isNotEmpty) {
                final last = replies
                    .map((r) => r['created_at'] as int)
                    .reduce((a, b) => a > b ? a : b);
                response.add(
                  event(
                    39005,
                    jsonEncode({
                      'reply_count': replies.length,
                      'descendant_count': replies.length,
                      'last_reply_at': last,
                      'participants': replies
                          .map((r) => r['pubkey'])
                          .toSet()
                          .toList(),
                    }),
                    [
                      ['e', root['id'] as String],
                      ['d', root['id'] as String],
                      ['h', channel],
                    ],
                  ),
                );
              }
              response.add(
                event(
                  39006,
                  jsonEncode({'has_more': false, 'next_cursor': null}),
                  [
                    ['h', channel],
                  ],
                ),
              );
            }
          }
        }
        request.response.statusCode = 200;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode(response));
        await request.response.close();
        return;
      }
      final socket = await WebSocketTransformer.upgrade(request);
      clients.add(socket);
      connections++;
      socket.add(jsonEncode(['AUTH', 'local-test-challenge']));
      socket.listen(
        (raw) {
          if (socket.readyState != WebSocket.open) return;
          final frame = jsonDecode(raw as String) as List<dynamic>;
          if (frame[0] == 'AUTH') {
            socket.add(jsonEncode(['OK', (frame[1] as Map)['id'], true, '']));
          } else if (frame[0] == 'REQ') {
            requests++;
            if (stallCurrentConnections) return;
            final filter = frame[2] as Map<String, dynamic>;
            final events = filter.containsKey('ids')
                ? (hideRoot ? <Map<String, dynamic>>[] : [root])
                : filter.containsKey('#e')
                ? replies
                : (filter['kinds'] as List<dynamic>?)?.contains(45001) == true
                ? [root]
                : <Map<String, dynamic>>[];
            for (final event in events) {
              socket.add(jsonEncode(['EVENT', frame[1], event]));
            }
            socket.add(jsonEncode(['EOSE', frame[1]]));
          }
        },
        onDone: () => clients.remove(socket),
        onError: (Object _) => clients.remove(socket),
      );
    });
  }
  static Future<ForumDiagnosticRelay> start() async => ForumDiagnosticRelay(
    await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
  );
  final HttpServer server;
  final keys = nostr.Keys.generate();
  late final Map<String, dynamic> root;
  final replies = <Map<String, dynamic>>[];
  final clients = <WebSocket>{};
  int requests = 0;
  int connections = 0;
  bool stallCurrentConnections = false;
  bool hideRoot = false;
  String get url => 'http://127.0.0.1:${server.port}';
  Map<String, dynamic> event(int kind, String text, List<List<String>> tags) =>
      nostr.Event.from(
        kind: kind,
        content: text,
        tags: tags,
        secretKey: nostr.Nip19.decode(payload: keys.nsec).data,
      ).toMap();
  void addReply(String text) => replies.add(
    event(45003, text, [
      ['h', channel],
      ['e', root['id'] as String, '', 'reply'],
    ]),
  );
  Future<void> disconnectClients() async {
    for (final socket in clients.toList()) {
      await socket.close();
    }
  }

  Future<void> close() async {
    await disconnectClients();
    await server.close(force: true);
  }
}
