import 'package:buzz/features/channels/channel.dart';
import 'package:buzz/features/forum/forum_posts_view.dart';
import 'package:buzz/features/forum/forum_thread_page.dart';
import 'package:buzz/shared/auth/auth_provider.dart';
import 'package:buzz/shared/mentions/agent_identity_provider.dart';
import 'package:buzz/shared/profile/user_cache_provider.dart';
import 'package:buzz/shared/relay/relay.dart';
import 'package:buzz/shared/theme/theme.dart';
import 'package:buzz/shared/widgets/bee_refresh_indicator.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:integration_test/integration_test.dart';
import 'package:nostr/nostr.dart' as nostr;
import 'package:shared_preferences/shared_preferences.dart';

import 'forum_refresh_diagnostic_test.dart'
    show
        channel,
        ForumDiagnosticRelay,
        ForumDiagnosticAuth,
        ForumDiagnosticConfig,
        ForumDiagnosticProfiles;

Future<void> waitFor(
  WidgetTester tester,
  bool Function() ready,
  String label, {
  int seconds = 6,
}) async {
  final deadline = DateTime.now().add(Duration(seconds: seconds));
  while (!ready() && DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  expect(ready(), isTrue, reason: label);
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  Future<({ProviderContainer container, ForumDiagnosticRelay relay})> setup(
    WidgetTester tester,
  ) async {
    final relay = await ForumDiagnosticRelay.start();
    final identity = nostr.Keys.generate();
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(
      retry: (_, _) => null,
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
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 300));
      container.dispose();
      await relay.close();
    });
    await container.read(authProvider.future);
    container.read(relaySessionProvider.notifier);
    await waitFor(
      tester,
      () =>
          container.read(relaySessionProvider).status ==
          SessionStatus.connected,
      'fixture connected',
    );
    return (container: container, relay: relay);
  }

  Widget wrap(ProviderContainer container, Widget home) =>
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(theme: AppTheme.light(), home: home),
      );

  for (final initialState in ['empty', 'populated', 'failed']) {
    testWidgets(
      'pull refresh works on $initialState thread before periodic poll',
      (tester) async {
        final fixture = await setup(tester);
        if (initialState == 'populated') {
          fixture.relay.addReply('Existing reply');
        }
        fixture.relay.hideRoot = initialState == 'failed';
        await tester.pumpWidget(
          wrap(
            fixture.container,
            ForumThreadPage(
              channelId: channel,
              postEventId: fixture.relay.root['id'] as String,
              currentPubkey: null,
              isMember: false,
              isArchived: false,
            ),
          ),
        );
        await waitFor(
          tester,
          () => find
              .text(
                initialState == 'failed'
                    ? 'Failed to load thread'
                    : 'Forum refresh diagnostic',
              )
              .evaluate()
              .isNotEmpty,
          'initial $initialState state rendered',
        );
        fixture.relay.hideRoot = false;
        fixture.relay.addReply('Reply fetched by manual refresh');
        final requestsBefore = fixture.relay.requests;
        if (initialState == 'failed') {
          expect(find.text('Retry'), findsOneWidget);
          await tester.tap(find.text('Retry'));
        } else {
          expect(
            find.byType(BeeRefreshIndicator),
            findsOneWidget,
            reason: 'Pull refresh must be reachable in $initialState state',
          );
          final scrollable = find
              .descendant(
                of: find.byType(BeeRefreshIndicator),
                matching: find.byType(Scrollable),
              )
              .first;
          await tester.drag(scrollable, const Offset(0, 360));
        }
        await waitFor(
          tester,
          () => find
              .text('Reply fetched by manual refresh')
              .evaluate()
              .isNotEmpty,
          'gesture loads new reply without waiting for ten-second poll',
          seconds: 3,
        );
        expect(fixture.relay.requests, greaterThan(requestsBefore));
        debugPrint('FORUM_APPROVED_FIX PASS $initialState manual refresh');
        await binding.convertFlutterSurfaceToImage();
        await tester.pump();
        await binding.takeScreenshot('refresh-$initialState');
        await tester.pumpWidget(const SizedBox.shrink());
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('forum list displays mixed reply count and latest activity', (
    tester,
  ) async {
    final fixture = await setup(tester);
    fixture.relay.addReply('Forum reply');
    fixture.relay.replies.add(
      fixture.relay.event(9, 'Chat reply', [
        ['h', channel],
        ['e', fixture.relay.root['id'] as String, '', 'reply'],
      ]),
    );
    final forum = Channel(
      id: channel,
      name: 'Forum diagnostic',
      channelType: 'forum',
      visibility: 'open',
      description: '',
      createdBy: fixture.relay.root['pubkey'] as String,
      createdAt: DateTime.now(),
      memberCount: 2,
      isMember: false,
    );
    await tester.pumpWidget(
      wrap(
        fixture.container,
        Scaffold(body: ForumPostsView(channel: forum, currentPubkey: null)),
      ),
    );
    await waitFor(
      tester,
      () => find.text('2 replies').evaluate().isNotEmpty,
      'both message kinds counted',
    );
    expect(find.textContaining('last '), findsOneWidget);
    await binding.convertFlutterSurfaceToImage();
    await tester.pump();
    await binding.takeScreenshot('list-two-replies');
    fixture.relay.addReply('Another forum reply');
    await tester.drag(
      find
          .descendant(
            of: find.byType(BeeRefreshIndicator),
            matching: find.byType(Scrollable),
          )
          .first,
      const Offset(0, 360),
    );
    await waitFor(
      tester,
      () => find.text('3 replies').evaluate().isNotEmpty,
      'list refresh updates count',
      seconds: 3,
    );
    await binding.takeScreenshot('list-three-replies');
    debugPrint('FORUM_APPROVED_FIX PASS list counts and last activity');
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });
}
