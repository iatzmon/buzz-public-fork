import 'package:buzz/features/forum/forum_thread_page.dart';
import 'package:buzz/shared/auth/auth_provider.dart';
import 'package:buzz/shared/mentions/agent_identity_provider.dart';
import 'package:buzz/shared/profile/user_cache_provider.dart';
import 'package:buzz/shared/relay/relay.dart';
import 'package:buzz/shared/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:integration_test/integration_test.dart';
import 'package:nostr/nostr.dart' as nostr;
import 'package:shared_preferences/shared_preferences.dart';

import 'forum_approved_fixes_test.dart' show waitFor;
import 'forum_refresh_diagnostic_test.dart'
    show
        channel,
        ForumDiagnosticRelay,
        ForumDiagnosticAuth,
        ForumDiagnosticConfig,
        ForumDiagnosticProfiles;

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('forum thread jump-to-latest reaches the newest reply', (
    tester,
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

    for (var i = 0; i < 40; i++) {
      relay.addReply('Jump reply $i\nSecond line of reply $i');
    }
    // Replies share a timestamp; the page breaks ties by event id.
    final sorted = [...relay.replies]
      ..sort((a, b) {
        final byTime = (a['created_at'] as int).compareTo(
          b['created_at'] as int,
        );
        return byTime == 0
            ? (a['id'] as String).compareTo(b['id'] as String)
            : byTime;
      });
    final newest = (sorted.last['content'] as String).split('\n').first;

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
    final jumpButton = find.byKey(
      const ValueKey('forum-thread-jump-to-latest'),
    );
    await waitFor(
      tester,
      () => find.text('40 replies').evaluate().isNotEmpty,
      'thread with 40 replies rendered',
    );
    await waitFor(
      tester,
      () => jumpButton.evaluate().isNotEmpty,
      'jump button shown while newest reply is below the screen',
    );
    expect(find.textContaining(newest), findsNothing);
    await binding.convertFlutterSurfaceToImage();
    await tester.pump();
    await binding.takeScreenshot('forum-jump-before');

    await tester.tap(jumpButton);
    await waitFor(
      tester,
      () =>
          find.textContaining(newest).evaluate().isNotEmpty &&
          jumpButton.evaluate().isEmpty,
      'newest reply visible and button hidden after tap',
    );
    final screen = tester.view.physicalSize / tester.view.devicePixelRatio;
    final rect = tester.getRect(find.textContaining(newest));
    expect(rect.bottom, lessThanOrEqualTo(screen.height));
    debugPrint('FORUM_JUMP_LATEST PASS newest="$newest" rect=$rect');
    await tester.pump(const Duration(milliseconds: 300));
    await binding.takeScreenshot('forum-jump-after');
    expect(tester.takeException(), isNull);
  });
}
