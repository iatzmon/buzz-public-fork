import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../shared/deeplink/deep_link.dart';
import '../../shared/relay/relay.dart';
import '../../shared/widgets/buzz_loading_indicator.dart';
import '../forum/forum_thread_page.dart';
import '../forum/forum_models.dart';
import 'channel.dart';
import 'channel_detail_page.dart';
import 'channel_messages_provider.dart';

/// Resolves the selected event, including notifications created by older builds
/// that carry no thread metadata. RelaySession verifies fetched events.
final notificationEventProvider = FutureProvider.autoDispose
    .family<NostrEvent, ({String channelId, String eventId, bool isForum})>((
      ref,
      target,
    ) async {
      if (!target.isForum) {
        final cached = ref
            .read(channelMessagesProvider(target.channelId))
            .value;
        final event = cached
            ?.where(
              (event) =>
                  event.id == target.eventId &&
                  event.channelId == target.channelId &&
                  const [9, 40002, 45001, 45003].contains(event.kind),
            )
            .firstOrNull;
        if (event != null) return event;
      }
      final events = await ref
          .read(relaySessionProvider.notifier)
          .fetchHistory(
            NostrFilter(
              kinds: const [9, 40002, 45001, 45003],
              ids: [target.eventId],
              tags: {
                '#h': [target.channelId],
              },
              limit: 1,
            ),
          );
      final event = events
          .where(
            (event) =>
                event.id == target.eventId &&
                event.channelId == target.channelId &&
                const [9, 40002, 45001, 45003].contains(event.kind),
          )
          .firstOrNull;
      if (event == null) throw StateError('Notification message unavailable');
      return event;
    });

/// Opens a notification's actual conversation after resolving its message.
class NotificationDestination extends ConsumerWidget {
  const NotificationDestination({
    super.key,
    required this.channel,
    required this.link,
  });

  final Channel channel;
  final MessageDeepLink link;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final provider = notificationEventProvider((
      channelId: channel.id,
      eventId: link.messageId,
      isForum: channel.isForum,
    ));
    return ref
        .watch(provider)
        .when(
          loading: () => const Scaffold(
            body: Center(
              child: BuzzLoadingIndicator(semanticLabel: 'Opening message'),
            ),
          ),
          error: (_, _) => Scaffold(
            appBar: AppBar(title: const Text('Notification')),
            body: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'Could not load this message. It may be unavailable.',
                  ),
                  TextButton(
                    onPressed: () => ref.invalidate(provider),
                    child: const Text('Retry'),
                  ),
                ],
              ),
            ),
          ),
          data: (event) {
            if (channel.isForum) {
              return ForumThreadPage(
                channelId: channel.id,
                postEventId: event.kind == 45001
                    ? event.id
                    : event.threadReference.rootId ??
                          event.parentEventId ??
                          event.id,
                currentPubkey: ref.watch(myPubkeyProvider),
                isMember: channel.isMember,
                isArchived: channel.isArchived,
                initialMessageId: event.id,
                initialReply: event.kind == 45003
                    ? ThreadReply.fromEvent(event)
                    : null,
              );
            }
            final broadcast = event.tags.any(
              (tag) =>
                  tag.length >= 2 && tag[0] == 'broadcast' && tag[1] == '1',
            );
            return ChannelDetailPage(
              channel: channel,
              initialMessageId: event.id,
              initialThreadRootId: broadcast
                  ? null
                  : event.parentEventId ?? event.id,
              initialThreadRouteBehavior:
                  InitialThreadRouteBehavior.replaceCurrentRoute,
            );
          },
        );
  }
}
