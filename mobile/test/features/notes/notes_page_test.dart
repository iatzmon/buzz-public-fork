import 'package:buzz/features/notes/long_note.dart';
import 'package:buzz/features/notes/notes_page.dart';
import 'package:buzz/shared/deeplink/deep_link.dart';
import 'package:buzz/shared/deeplink/pending_deep_link_provider.dart';
import 'package:buzz/shared/profile/user_cache_provider.dart';
import 'package:buzz/shared/projects/project_event_verification.dart';
import 'package:buzz/shared/profile/user_profile.dart';
import 'package:buzz/shared/relay/relay.dart';
import 'package:buzz/shared/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../shared/projects/project_fixtures.dart';

final _agent = testKey(1);
final _other = testKey(2);
const _channel = '9299f664-9e23-4ae8-84ab-50527da0c3a9';

/// A signed long-form note, as the relay would serve it.
NostrEvent _note({
  String? author,
  int time = 100,
  int kind = longNoteKind,
  String? slug = 'retro',
  String? title = 'Relay retro',
  String? summary,
  String content = 'Body',
  int? publishedAt,
}) => signedEvent(
  pubkey: author ?? _agent,
  kind: kind,
  createdAt: time,
  tags: [
    if (slug != null) ['d', slug],
    if (title != null) ['title', title],
    if (summary != null) ['summary', summary],
    if (publishedAt != null) ['published_at', '$publishedAt'],
  ],
  content: content,
);

class _Config extends RelayConfigNotifier {
  @override
  RelayConfig build() => const RelayConfig(baseUrl: 'https://notes.example');
}

class _Session extends RelaySessionNotifier {
  _Session(this.respond);

  final Future<List<NostrEvent>> Function(List<NostrFilter>) respond;
  final filters = <List<NostrFilter>>[];

  @override
  SessionState build() => const SessionState(status: SessionStatus.connected);

  @override
  Future<List<NostrEvent>> queryRelay(
    List<NostrFilter> filters, {
    Duration timeout = const Duration(seconds: 8),
  }) {
    this.filters.add(filters);
    return respond(filters);
  }
}

class _Profiles extends UserCacheNotifier {
  @override
  Map<String, UserProfile> build() => {
    _agent: UserProfile(pubkey: _agent, displayName: 'Claude Forge'),
  };

  @override
  Future<bool> preload(List<String> pubkeys) async => true;
}

void main() {
  late _Session session;

  Future<ProviderContainer> pump(
    WidgetTester tester,
    Future<List<NostrEvent>> Function(List<NostrFilter>) respond,
  ) async {
    session = _Session(respond);
    final container = ProviderContainer(
      overrides: [
        relayConfigProvider.overrideWith(_Config.new),
        relaySessionProvider.overrideWith(() => session),
        userCacheProvider.overrideWith(_Profiles.new),
        // The production check, inline: widget tests cannot wait on compute.
        longNoteVerifierProvider.overrideWithValue(
          (events) async => events.where(isVerifiedProjectEvent).toList(),
        ),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(theme: AppTheme.light(), home: const NotesPage()),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  test('keeps the newest version of each note, newest first', () {
    final notes = latestLongNotes([
      _note(time: 10, title: 'Old title'),
      _note(time: 30, title: 'New title'),
      _note(time: 20, author: _other, title: null, slug: 'plan'),
      _note(time: 99, slug: null),
      _note(time: 99, kind: 1),
    ]);
    expect(notes.map((n) => n.title), ['New title', 'plan']);
    expect(notes.first.updatedAt, 30);
  });

  testWidgets('lists notes and opens one in the reader', (tester) async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    await pump(
      tester,
      (_) async => [
        _note(
          time: now - 3600,
          publishedAt: now - 3 * 86400,
          summary: 'What went well',
          content: 'The relay stayed up all week.',
        ),
        _note(time: now - 7200, author: _other, slug: 'plan', title: 'Plan'),
      ],
    );
    expect(session.filters.single.single.kinds, [longNoteKind]);
    expect(find.text('Relay retro'), findsOneWidget);
    expect(find.text('Claude Forge · 1h ago'), findsOneWidget);
    expect(find.text('Plan'), findsOneWidget);

    await tester.tap(find.text('Relay retro'));
    await tester.pumpAndSettle();
    expect(find.text('What went well'), findsOneWidget);
    expect(find.text('The relay stayed up all week.'), findsOneWidget);
    expect(
      find.text('Claude Forge · updated 1h ago · first published 3d ago'),
      findsOneWidget,
    );
  });

  testWidgets('drops a note whose signature does not match its content', (
    tester,
  ) async {
    await pump(
      tester,
      (_) async => [
        _note(title: 'Genuine'),
        tampered(_note(slug: 'forged', title: 'Forged')),
      ],
    );
    expect(find.text('Genuine'), findsOneWidget);
    expect(find.text('Forged'), findsNothing);
  });

  testWidgets('says when there are no notes', (tester) async {
    await pump(tester, (_) async => []);
    expect(find.text('No notes yet.'), findsOneWidget);
  });

  testWidgets('a failed load shows an error and Retry loads again', (
    tester,
  ) async {
    var fail = true;
    await pump(tester, (_) async {
      if (fail) throw StateError('Offline');
      return [_note()];
    });
    expect(find.text('Notes could not load.'), findsOneWidget);
    fail = false;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.text('Relay retro'), findsOneWidget);
    expect(session.filters, hasLength(2));
  });

  testWidgets('a failed refresh keeps the notes and shows the error', (
    tester,
  ) async {
    var fail = false;
    final container = await pump(tester, (_) async {
      if (fail) throw StateError('Offline');
      return [_note()];
    });
    fail = true;
    container.invalidate(longNotesProvider);
    await tester.pumpAndSettle();
    expect(find.text('Relay retro'), findsOneWidget);
    expect(find.text('Notes could not refresh.'), findsOneWidget);
    fail = false;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.text('Notes could not refresh.'), findsNothing);
    expect(find.text('Relay retro'), findsOneWidget);
  });

  for (final accountOnly in [false, true]) {
    testWidgets(
      'an open note hides after a ${accountOnly ? 'same-community account' : 'community'} change',
      (tester) async {
        final container = await pump(
          tester,
          (_) async => [_note(content: 'Private body')],
        );
        await tester.tap(find.text('Relay retro'));
        await tester.pumpAndSettle();
        expect(find.text('Private body'), findsOneWidget);
        container
            .read(relayConfigProvider.notifier)
            .update(
              baseUrl: accountOnly
                  ? 'https://notes.example'
                  : 'https://other.example',
              nsec: accountOnly ? 'second' : null,
            );
        await tester.pumpAndSettle();
        expect(find.text('Private body'), findsNothing);
        expect(find.text('Community or account changed.'), findsOneWidget);
      },
    );
  }

  testWidgets('a Buzz link in a note goes to the in-app link handler', (
    tester,
  ) async {
    final container = await pump(
      tester,
      (_) async => [
        _note(content: 'See [the thread](buzz://channel/$_channel).'),
      ],
    );
    await tester.tap(find.text('Relay retro'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('the thread'));
    await tester.pumpAndSettle();
    expect(
      container.read(pendingDeepLinkProvider),
      isA<ChannelDeepLink>().having((l) => l.channelId, 'channel', _channel),
    );
  });
}
