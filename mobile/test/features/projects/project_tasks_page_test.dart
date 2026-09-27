import 'package:buzz/features/projects/project_tasks_page.dart';
import 'package:buzz/shared/profile/user_cache_provider.dart';
import 'package:buzz/shared/profile/user_profile.dart';
import 'package:buzz/shared/projects/project_task_store.dart';
import 'package:buzz/shared/relay/relay.dart';
import 'package:buzz/shared/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _owner = 'b' * 64;
final _viewer = 'a' * 64;
final _repo = '30617:$_owner:app';
final _secondRepo = '30617:$_owner:website';
NostrEvent _event(
  String id, {
  int kind = 1621,
  String? signer,
  List<List<String>>? tags,
  String content = 'Read the task details',
}) => NostrEvent(
  id: id.padLeft(64, '0'),
  pubkey: signer ?? _owner,
  createdAt: 10,
  kind: kind,
  tags:
      tags ??
      [
        ['a', _repo],
        ['subject', 'Mobile project task'],
      ],
  content: content,
  sig: '0' * 128,
);

class _Config extends RelayConfigNotifier {
  @override
  RelayConfig build() => const RelayConfig(baseUrl: 'https://tasks.example');
}

class _Profiles extends UserCacheNotifier {
  @override
  Map<String, UserProfile> build() => {
    _viewer: UserProfile(pubkey: _viewer, displayName: 'You'),
  };
  @override
  Future<bool> preload(List<String> pubkeys) async => true;
}

void main() {
  Future<ProviderContainer> pump(
    WidgetTester tester, {
    bool fail = false,
    required List<NostrEvent> published,
    Map<String, String>? repositories,
    bool accountSwitch = false,
    List<NostrEvent> history = const [],
  }) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(
      overrides: [
        savedPrefsProvider.overrideWithValue(prefs),
        relayConfigProvider.overrideWith(_Config.new),
        myPubkeyProvider.overrideWith(
          (ref) =>
              accountSwitch && ref.watch(relayConfigProvider).nsec == 'second'
              ? 'd' * 64
              : _viewer,
        ),
        userCacheProvider.overrideWith(_Profiles.new),
        projectTaskTransportProvider.overrideWithValue(
          ProjectTaskTransport(
            query: (filter) async {
              if (filter.kinds.contains(1621)) {
                return [_event('1')];
              }
              return history;
            },
            publish: (e) async {
              published.add(e);
              if (fail) throw StateError('Offline');
            },
            sign: (kind, content, tags, time) => _event(
              '99',
              kind: kind,
              signer: _viewer,
              tags: tags,
              content: content,
            ),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(),
          home: ProjectTasksPage(
            repositories: repositories ?? {_repo: 'App'},
            channelId: 'channel',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  testWidgets(
    'opens actual task detail and self-assigns through signed operation',
    (tester) async {
      final published = <NostrEvent>[];
      await pump(tester, published: published);
      await tester.tap(find.text('Mobile project task'));
      await tester.pumpAndSettle();
      expect(find.text('Read the task details'), findsOneWidget);
      expect(find.text('Assign member'), findsNothing);
      await tester.tap(find.text('Assign to me'));
      await tester.pumpAndSettle();
      expect(published.single.kind, 1);
      expect(published.single.tags, contains(equals(['t', 'assignment'])));
      expect(published.single.tags, contains(equals(['p', _viewer])));
      expect(find.text('You'), findsNWidgets(2));
      expect(find.byTooltip('Unassign You'), findsOneWidget);
    },
  );
  testWidgets(
    'failed create keeps draft and exposes retry after navigating away',
    (tester) async {
      final published = <NostrEvent>[];
      await pump(tester, published: published, fail: true);
      await tester.tap(find.byTooltip('Create task'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Title'),
        'Save my task',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Description'),
        'Keep this body',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Create task'));
      await tester.pumpAndSettle();
      expect(find.text('Retry send'), findsOneWidget);
      expect(find.text('Save my task'), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('1 change(s) waiting for confirmation'), findsOneWidget);
      await tester.tap(find.byTooltip('Create task'));
      await tester.pumpAndSettle();
      expect(find.text('Save my task'), findsOneWidget);
      expect(find.text('Keep this body'), findsOneWidget);
    },
  );
  testWidgets(
    'repository switch does not show tasks from previous repository',
    (tester) async {
      await pump(
        tester,
        published: [],
        repositories: {_repo: 'App', _secondRepo: 'Website'},
      );
      expect(find.text('Mobile project task'), findsOneWidget);
      await tester.tap(find.text('App'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Website').last);
      await tester.pumpAndSettle();
      expect(find.text('Mobile project task'), findsNothing);
      expect(find.text('No tasks yet.'), findsOneWidget);
    },
  );
  for (final compose in [false, true]) {
    testWidgets(
      'same-community account switch hides ${compose ? 'compose' : 'detail'} actions',
      (tester) async {
        final published = <NostrEvent>[];
        final container = await pump(
          tester,
          published: published,
          accountSwitch: true,
        );
        await tester.tap(
          compose
              ? find.byTooltip('Create task')
              : find.text('Mobile project task'),
        );
        await tester.pumpAndSettle();
        if (compose) {
          await tester.enterText(
            find.widgetWithText(TextField, 'Title'),
            'Private draft',
          );
          await tester.pumpAndSettle();
        }
        container
            .read(relayConfigProvider.notifier)
            .update(baseUrl: 'https://tasks.example', nsec: 'second');
        await tester.pumpAndSettle();
        expect(
          find.text('Community or account changed. Reopen Tasks to continue.'),
          findsOneWidget,
        );
        expect(find.text('Assign to me'), findsNothing);
        expect(find.widgetWithText(FilledButton, 'Create task'), findsNothing);
        expect(find.text('Private draft'), findsNothing);
        expect(published, isEmpty);
      },
    );
  }
  testWidgets('malformed signed assignment cannot crash task detail', (
    tester,
  ) async {
    await pump(
      tester,
      published: [],
      history: [
        _event(
          '2',
          kind: 1,
          tags: [
            ['e', _event('1').id],
            ['a', _repo],
            ['p', 'x'],
            ['t', 'assignment'],
          ],
        ),
      ],
    );
    await tester.tap(find.text('Mobile project task'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Unassigned'), findsOneWidget);
  });
  testWidgets('community switch hides an open task and its action controls', (
    tester,
  ) async {
    final container = await pump(tester, published: []);
    await tester.tap(find.text('Mobile project task'));
    await tester.pumpAndSettle();
    container
        .read(relayConfigProvider.notifier)
        .update(baseUrl: 'https://other.example');
    await tester.pumpAndSettle();
    expect(find.text('Mobile project task'), findsNothing);
    expect(find.text('Assign to me'), findsNothing);
    expect(
      find.text('Community or account changed. Reopen Tasks to continue.'),
      findsOneWidget,
    );
  });
}
