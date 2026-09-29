import 'package:buzz/features/notes/long_note.dart';
import 'package:buzz/features/notes/notes_page.dart';
import 'package:buzz/shared/profile/user_cache_provider.dart';
import 'package:buzz/shared/profile/user_profile.dart';
import 'package:buzz/shared/relay/relay.dart';
import 'package:buzz/shared/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

final _agent = 'a' * 64;
final _other = 'b' * 64;

NostrEvent _note(
  String id, {
  String? author,
  int time = 100,
  int kind = longNoteKind,
  String? slug = 'retro',
  String? title = 'Relay retro',
  String? summary,
  String content = 'Body',
  int? publishedAt,
}) => NostrEvent(
  id: id.padLeft(64, '0'),
  pubkey: author ?? _agent,
  createdAt: time,
  kind: kind,
  tags: [
    if (slug != null) ['d', slug],
    if (title != null) ['title', title],
    if (summary != null) ['summary', summary],
    if (publishedAt != null) ['published_at', '$publishedAt'],
  ],
  content: content,
  sig: '0' * 128,
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
  Future<_Session> pump(
    WidgetTester tester,
    Future<List<NostrEvent>> Function(List<NostrFilter>) respond,
  ) async {
    final session = _Session(respond);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          relayConfigProvider.overrideWith(_Config.new),
          relaySessionProvider.overrideWith(() => session),
          userCacheProvider.overrideWith(_Profiles.new),
        ],
        child: MaterialApp(theme: AppTheme.light(), home: const NotesPage()),
      ),
    );
    await tester.pumpAndSettle();
    return session;
  }

  test('keeps the newest version of each note, newest first', () {
    final notes = latestLongNotes([
      _note('1', time: 10, title: 'Old title'),
      _note('2', time: 30, title: 'New title'),
      _note('3', time: 20, author: _other, title: null, slug: 'plan'),
      _note('4', time: 99, slug: null),
      _note('5', time: 99, kind: 1),
    ]);
    expect(notes.map((n) => n.title), ['New title', 'plan']);
    expect(notes.first.updatedAt, 30);
  });

  testWidgets('lists notes and opens one in the reader', (tester) async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final session = await pump(
      tester,
      (_) async => [
        _note(
          '1',
          time: now - 3600,
          publishedAt: now - 3 * 86400,
          summary: 'What went well',
          content: 'The relay stayed up all week.',
        ),
        _note(
          '2',
          time: now - 7200,
          author: _other,
          slug: 'plan',
          title: 'Plan',
        ),
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

  testWidgets('says when there are no notes', (tester) async {
    await pump(tester, (_) async => []);
    expect(find.text('No notes yet.'), findsOneWidget);
  });

  testWidgets('a failed load shows an error and Retry loads again', (
    tester,
  ) async {
    var fail = true;
    final session = await pump(tester, (_) async {
      if (fail) throw StateError('Offline');
      return [_note('1')];
    });
    expect(find.text('Notes could not load.'), findsOneWidget);
    fail = false;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.text('Relay retro'), findsOneWidget);
    expect(session.filters, hasLength(2));
  });
}
