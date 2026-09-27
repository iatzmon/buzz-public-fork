import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:buzz/features/forum/forum_provider.dart';
import 'package:buzz/features/forum/forum_thread_history.dart';
import 'package:buzz/shared/relay/relay.dart';
import 'package:flutter_test/flutter_test.dart';

const channel = 'forum';
const rootId = 'root';
NostrEvent event(String id, int time, {int kind = 45003, String? target}) =>
    NostrEvent(
      id: id,
      pubkey: 'author',
      createdAt: time,
      kind: kind,
      content: id,
      tags: [
        ['h', channel],
        ['e', target ?? rootId, '', 'reply'],
      ],
      sig: '',
    );

class TestConfig extends RelayConfigNotifier {
  @override
  RelayConfig build() => const RelayConfig(baseUrl: 'https://first.example');
  void switchCommunity() {
    state = const RelayConfig(baseUrl: 'https://second.example');
  }
}

class TestRelay extends RelaySessionNotifier {
  @override
  SessionState build() =>
      const SessionState(status: SessionStatus.disconnected);
  final events = <NostrEvent>[event(rootId, 10000, kind: 45001)];
  final requests = <NostrFilter>[];
  bool failReplies = false;
  @override
  Future<List<NostrEvent>> queryRelay(
    List<NostrFilter> filters, {
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final filter = filters.single;
    requests.add(filter);
    if (failReplies && filter.kinds.contains(45003) && filter.ids == null) {
      throw StateError('offline');
    }
    final rows =
        events
            .where(
              (e) =>
                  filter.kinds.contains(e.kind) &&
                  (filter.ids == null || filter.ids!.contains(e.id)) &&
                  (filter.since == null || e.createdAt >= filter.since!) &&
                  (filter.tags['#e'] == null ||
                      e.tags.any(
                        (t) => t[0] == 'e' && filter.tags['#e']!.contains(t[1]),
                      )) &&
                  (filter.until == null ||
                      e.createdAt < filter.until! ||
                      (e.createdAt == filter.until &&
                          (filter.extensions['before_id'] == null ||
                              e.id.compareTo(
                                    filter.extensions['before_id']! as String,
                                  ) >
                                  0))),
            )
            .toList()
          ..sort((a, b) {
            final time = b.createdAt.compareTo(a.createdAt);
            return time == 0 ? a.id.compareTo(b.id) : time;
          });
    return rows.take(filter.limit).toList();
  }
}

void main() {
  test('reports a root removed after an earlier successful load', () async {
    final relay = TestRelay()..events.add(event('reply', 11000));
    final history = ForumThreadHistory();
    await history.load(
      relay,
      channelId: channel,
      eventId: rootId,
      isCurrent: () => true,
    );
    relay.events.removeWhere((e) => e.id == rootId);
    await expectLater(
      history.load(
        relay,
        channelId: channel,
        eventId: rootId,
        isCurrent: () => true,
      ),
      throwsA(isA<ForumThreadUnavailable>()),
    );
  });

  test(
    'provider refresh keeps incremental history and community switch resets it',
    () async {
      final relay = TestRelay()
        ..events.addAll([event('old', 11000), event('new', 15000)]);
      final config = TestConfig();
      final container = ProviderContainer(
        overrides: [
          relaySessionProvider.overrideWith(() => relay),
          relayConfigProvider.overrideWith(() => config),
        ],
      );
      addTearDown(container.dispose);
      const key = (channelId: channel, eventId: rootId);
      final subscription = container.listen(
        forumThreadProvider(key),
        (_, _) {},
      );
      addTearDown(subscription.close);
      await container.read(forumThreadProvider(key).future);
      relay.requests.clear();
      relay.events.add(event('latest', 16000));
      container.invalidate(forumThreadProvider(key));
      final result = await container.read(forumThreadProvider(key).future);
      expect(result.replies.map((r) => r.eventId), ['old', 'new', 'latest']);
      expect(
        relay.requests
            .singleWhere((f) => f.kinds.contains(45003) && f.ids == null)
            .since,
        isNotNull,
      );
      relay.requests.clear();
      config.switchCommunity();
      await container.read(forumThreadProvider(key).future);
      expect(
        relay.requests
            .singleWhere((f) => f.kinds.contains(45003) && f.ids == null)
            .since,
        isNull,
      );
    },
  );

  test(
    'loads more than one page including replies sharing a timestamp',
    () async {
      final relay = TestRelay();
      relay.events.addAll(
        List.generate(250, (i) => event(i.toString().padLeft(64, '0'), 12000)),
      );
      final history = ForumThreadHistory();
      final result = await history.load(
        relay,
        channelId: channel,
        eventId: rootId,
        isCurrent: () => true,
      );
      expect(result.replies, hasLength(250));
      expect(result.replies.map((r) => r.eventId).toSet(), hasLength(250));
    },
  );

  test(
    'refresh merges late and same-second replies without downloading old history',
    () async {
      final relay = TestRelay()
        ..events.addAll([event('old', 11000), event('new', 15000)]);
      final history = ForumThreadHistory();
      await history.load(
        relay,
        channelId: channel,
        eventId: rootId,
        isCurrent: () => true,
      );
      relay.requests.clear();
      relay.events.addAll([event('same-second', 15000), event('late', 14500)]);
      final result = await history.load(
        relay,
        channelId: channel,
        eventId: rootId,
        isCurrent: () => true,
      );
      expect(
        result.replies.map((r) => r.eventId),
        containsAll(['old', 'new', 'same-second', 'late']),
      );
      final filter = relay.requests.singleWhere(
        (f) => f.kinds.contains(45003) && f.ids == null,
      );
      expect(filter.since, greaterThan(11000));
      expect(filter.since, lessThanOrEqualTo(14500));
    },
  );

  test('only removes marker targets actually absent from the relay', () async {
    final relay = TestRelay()
      ..events.addAll([event('kept', 15000), event('deleted', 15001)]);
    final history = ForumThreadHistory();
    await history.load(
      relay,
      channelId: channel,
      eventId: rootId,
      isCurrent: () => true,
    );
    relay.events.removeWhere((e) => e.id == 'deleted');
    relay.events.addAll([
      event('authorized-marker', 16000, kind: 9005, target: 'deleted'),
      event('unauthorized-marker', 16001, kind: 5, target: 'kept'),
    ]);
    final result = await history.load(
      relay,
      channelId: channel,
      eventId: rootId,
      isCurrent: () => true,
    );
    expect(result.replies.map((r) => r.eventId), ['kept']);
  });

  test(
    'failed refresh retains old replies for the next successful refresh',
    () async {
      final relay = TestRelay()
        ..events.addAll([event('old', 11000), event('new', 15000)]);
      final history = ForumThreadHistory();
      await history.load(
        relay,
        channelId: channel,
        eventId: rootId,
        isCurrent: () => true,
      );
      relay.failReplies = true;
      await expectLater(
        history.load(
          relay,
          channelId: channel,
          eventId: rootId,
          isCurrent: () => true,
        ),
        throwsStateError,
      );
      relay.failReplies = false;
      relay.events.add(event('latest', 16000));
      final result = await history.load(
        relay,
        channelId: channel,
        eventId: rootId,
        isCurrent: () => true,
      );
      expect(result.replies.map((r) => r.eventId), ['old', 'new', 'latest']);
    },
  );

  test('retired request cannot move the incremental cursor', () async {
    final relay = TestRelay()..events.add(event('old', 11000));
    final history = ForumThreadHistory();
    await expectLater(
      history.load(
        relay,
        channelId: channel,
        eventId: rootId,
        isCurrent: () => false,
      ),
      throwsStateError,
    );
    relay.requests.clear();
    await history.load(
      relay,
      channelId: channel,
      eventId: rootId,
      isCurrent: () => true,
    );
    expect(relay.requests.singleWhere((f) => f.ids == null).since, isNull);
  });
}
