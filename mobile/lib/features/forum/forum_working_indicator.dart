import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../shared/mentions/agent_identity_provider.dart';
import '../../shared/profile/user_cache_provider.dart';
import '../../shared/profile/user_profile.dart';
import '../../shared/theme/theme.dart';
import '../../shared/utils/string_utils.dart';
import '../channels/small_avatar.dart';
import '../channels/typing_text_shimmer.dart';

/// What a [ForumWorkingIndicator] is reporting activity on.
enum ForumWorkingScope {
  /// A specific post's thread: the people are writing a reply.
  reply,

  /// The forum as a whole: a new post, or a reply the sender did not tag.
  forum,
}

/// Compact "Scout is working…" status for people writing in a forum.
///
/// Agents read as "working" and people as "typing", matching the channel
/// typing indicator's wording. The row is one screen-reader stop whose label
/// states what the activity is about; avatars and the shimmer are decorative.
class ForumWorkingIndicator extends ConsumerWidget {
  final String channelId;
  final List<String> pubkeys;
  final ForumWorkingScope scope;

  /// Whether to draw the rounded composer-adjacent container; cards use the
  /// bare inline row.
  final bool contained;

  const ForumWorkingIndicator({
    super.key,
    required this.channelId,
    required this.pubkeys,
    required this.scope,
    this.contained = false,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profiles = <String, UserProfile>{};
    for (final pubkey in pubkeys) {
      final profile =
          ref.watch(userCacheProvider.select((cache) => cache[pubkey])) ??
          ref.read(userCacheProvider.notifier).get(pubkey);
      if (profile != null) profiles[pubkey] = profile;
    }
    final knownAgents = ref.watch(agentMentionPubkeysProvider(channelId));
    final directoryNames = ref.watch(agentDirectoryDisplayNamesProvider);
    final names = [
      for (final pubkey in pubkeys)
        profiles[pubkey]?.label ??
            directoryNames[pubkey] ??
            shortPubkey(pubkey),
    ];
    final anyAgent = pubkeys.any(
      (pubkey) =>
          knownAgents.contains(pubkey) || profiles[pubkey]?.ownerPubkey != null,
    );
    final text = forumWorkingText(names, anyAgent: anyAgent);
    final semanticLabel = forumWorkingSemanticLabel(
      names,
      anyAgent: anyAgent,
      scope: scope,
    );
    final visiblePubkeys = pubkeys.take(3).toList();
    final avatarSize = contained ? 24.0 : 18.0;
    final avatarStep = avatarSize * 0.6;

    final row = Row(
      children: [
        SizedBox(
          width: avatarSize + (visiblePubkeys.length - 1) * avatarStep,
          height: avatarSize,
          child: Stack(
            children: [
              for (var i = 0; i < visiblePubkeys.length; i++)
                Positioned(
                  left: i * avatarStep,
                  child: SmallAvatar(
                    pubkey: visiblePubkeys[i],
                    userCache: profiles,
                    size: avatarSize,
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(width: Grid.xxs),
        Flexible(
          child: TypingTextShimmer(
            text,
            style: context.textTheme.labelSmall?.copyWith(
              color: context.colors.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );

    return Semantics(
      container: true,
      label: semanticLabel,
      excludeSemantics: true,
      child: contained
          ? Padding(
              padding: const EdgeInsets.only(
                left: Grid.twelve,
                right: Grid.twelve,
                bottom: Grid.xxs,
              ),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(Grid.xxs),
                decoration: BoxDecoration(
                  color: context.colors.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(Radii.dialog),
                  border: Border.all(
                    color: Colors.black.withValues(alpha: 0.04),
                    width: 1,
                  ),
                ),
                child: row,
              ),
            )
          : row,
    );
  }
}

/// Visible status text, e.g. "Scout is working…".
String forumWorkingText(List<String> names, {required bool anyAgent}) {
  final verb = anyAgent ? 'working' : 'typing';
  return '${_subject(names)} ${_be(names)} $verb…';
}

/// Screen-reader label, e.g. "Scout is working on a reply".
String forumWorkingSemanticLabel(
  List<String> names, {
  required bool anyAgent,
  required ForumWorkingScope scope,
}) {
  final activity = switch ((anyAgent, scope)) {
    (true, ForumWorkingScope.reply) => 'working on a reply',
    (false, ForumWorkingScope.reply) => 'typing a reply',
    (true, ForumWorkingScope.forum) => 'working in this forum',
    (false, ForumWorkingScope.forum) => 'typing in this forum',
  };
  return '${_subject(names)} ${_be(names)} $activity';
}

String _subject(List<String> names) => switch (names.length) {
  0 => 'Someone',
  1 => names[0],
  2 => '${names[0]} and ${names[1]}',
  _ => '${names[0]} and ${names.length - 1} others',
};

String _be(List<String> names) => names.length > 1 ? 'are' : 'is';
