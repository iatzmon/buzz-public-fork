import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../shared/profile/user_cache_provider.dart';
import '../../shared/profile/user_profile.dart';
import '../../shared/theme/theme.dart';
import '../../shared/widgets/avatar_image.dart';

/// Task statuses in the order the Tasks list groups them.
const projectTaskStatusOrder = [
  'In Progress',
  'In Review',
  'Triage',
  'Backlog',
  'Done',
  'Closed',
];

/// Whether [status] is finished (Done or Closed).
bool isProjectTaskClosed(String status) =>
    status == 'Done' || status == 'Closed';

/// Icon and color for a task status. Matches Desktop's status visuals.
({IconData icon, Color color}) projectTaskStatusStyle(
  BuildContext context,
  String status,
) => switch (status) {
  'In Progress' => (
    icon: LucideIcons.circleDot,
    color: context.appColors.warning,
  ),
  'In Review' => (
    icon: LucideIcons.circleDot,
    color: context.appColors.success,
  ),
  'Triage' => (
    icon: LucideIcons.circleDashed,
    color: context.appColors.warning,
  ),
  'Done' => (icon: LucideIcons.circleCheck, color: context.colors.primary),
  'Closed' => (icon: LucideIcons.circleX, color: context.colors.error),
  _ => (icon: LucideIcons.circle, color: context.colors.onSurfaceVariant),
};

/// A task status icon in its status color.
class ProjectTaskStatusIcon extends StatelessWidget {
  const ProjectTaskStatusIcon({
    super.key,
    required this.status,
    this.size = 18,
  });

  final String status;
  final double size;

  @override
  Widget build(BuildContext context) {
    final style = projectTaskStatusStyle(context, status);
    return Icon(style.icon, size: size, color: style.color);
  }
}

/// A rounded status label with its icon.
class ProjectTaskStatusPill extends StatelessWidget {
  const ProjectTaskStatusPill({super.key, required this.status});

  final String status;

  @override
  Widget build(BuildContext context) {
    final style = projectTaskStatusStyle(context, status);
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: Grid.xxs,
        vertical: Grid.half,
      ),
      decoration: BoxDecoration(
        color: style.color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(Radii.full),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(style.icon, size: 14, color: style.color),
          const SizedBox(width: Grid.half),
          Text(
            status,
            style: context.textTheme.labelMedium?.copyWith(
              color: style.color,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

/// A person's avatar from the profile cache, with an initial as fallback.
class ProjectPersonAvatar extends ConsumerWidget {
  const ProjectPersonAvatar({
    super.key,
    required this.pubkey,
    this.radius = 16,
  });

  final String pubkey;
  final double radius;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(
      userCacheProvider.select((cache) => cache[pubkey.toLowerCase()]),
    );
    final initial = (profile ?? UserProfile(pubkey: pubkey)).initial;
    return AvatarImage(
      imageUrl: profile?.avatarUrl,
      radius: radius,
      isAgent: profile?.ownerPubkey != null,
      backgroundColor: context.colors.primaryContainer,
      fallback: Text(
        initial,
        style: TextStyle(
          fontSize: radius * 0.85,
          fontWeight: FontWeight.w600,
          color: context.colors.onPrimaryContainer,
        ),
      ),
    );
  }
}

/// Up to three overlapping assignee avatars, then a "+n" count.
class ProjectAssigneeFacepile extends StatelessWidget {
  const ProjectAssigneeFacepile({
    super.key,
    required this.pubkeys,
    this.radius = 11,
  });

  final List<String> pubkeys;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final shown = pubkeys.take(3).toList();
    final extra = pubkeys.length - shown.length;
    final step = radius * 1.35;
    final ring = context.colors.surfaceContainerHighest;
    return ExcludeSemantics(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: radius * 2 + step * (shown.length - 1) + 2,
            height: radius * 2 + 2,
            child: Stack(
              children: [
                for (var i = 0; i < shown.length; i++)
                  Positioned(
                    left: step * i,
                    child: Container(
                      padding: const EdgeInsets.all(1),
                      decoration: BoxDecoration(
                        color: ring,
                        shape: BoxShape.circle,
                      ),
                      child: ProjectPersonAvatar(
                        pubkey: shown[i],
                        radius: radius,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (extra > 0) ...[
            const SizedBox(width: Grid.half),
            Text(
              '+$extra',
              style: context.textTheme.labelSmall?.copyWith(
                color: context.colors.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// A centered icon, message, and optional action for empty and error states.
class ProjectEmptyState extends StatelessWidget {
  const ProjectEmptyState({
    super.key,
    required this.icon,
    required this.message,
    this.detail,
    this.action,
    this.isError = false,
  });

  final IconData icon;
  final String message;
  final String? detail;
  final Widget? action;
  final bool isError;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(
      horizontal: Grid.gutter,
      vertical: Grid.lg,
    ),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          icon,
          size: Grid.lg,
          color: isError
              ? context.colors.error
              : context.colors.onSurfaceVariant.withValues(alpha: 0.7),
        ),
        const SizedBox(height: Grid.xxs),
        Semantics(
          liveRegion: isError,
          child: Text(
            message,
            textAlign: TextAlign.center,
            style: context.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        if (detail case final detail?) ...[
          const SizedBox(height: Grid.half),
          Text(
            detail,
            textAlign: TextAlign.center,
            style: context.textTheme.bodyMedium?.copyWith(
              color: context.colors.onSurfaceVariant,
            ),
          ),
        ],
        if (action case final action?) ...[
          const SizedBox(height: Grid.xs),
          action,
        ],
      ],
    ),
  );
}

/// A rounded notice with an icon and an optional action, for stale data,
/// failed loads, and changes waiting to send.
class ProjectNotice extends StatelessWidget {
  const ProjectNotice({
    super.key,
    required this.icon,
    required this.text,
    this.actionLabel,
    this.onAction,
    this.actionKey,
    this.isError = false,
    this.margin = const EdgeInsets.fromLTRB(
      Grid.gutter,
      Grid.half,
      Grid.gutter,
      Grid.half,
    ),
  });

  /// Space around the notice. Defaults to the page gutter.
  final EdgeInsetsGeometry margin;
  final IconData icon;
  final String text;
  final String? actionLabel;
  final VoidCallback? onAction;
  final Key? actionKey;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final color = isError
        ? context.colors.error
        : context.colors.onSurfaceVariant;
    return Padding(
      padding: margin,
      child: Container(
        padding: const EdgeInsets.fromLTRB(
          Grid.twelve,
          Grid.half,
          Grid.half,
          Grid.half,
        ),
        constraints: const BoxConstraints(minHeight: Grid.xl - Grid.xxs),
        decoration: BoxDecoration(
          color: (isError ? context.colors.error : context.colors.onSurface)
              .withValues(alpha: 0.07),
          borderRadius: BorderRadius.circular(Radii.lg),
        ),
        child: Row(
          children: [
            Icon(icon, size: 16, color: color),
            const SizedBox(width: Grid.xxs),
            Expanded(
              child: Semantics(
                liveRegion: true,
                child: Text(
                  text,
                  style: context.textTheme.bodySmall?.copyWith(color: color),
                ),
              ),
            ),
            if (actionLabel case final label?)
              TextButton(
                key: actionKey,
                onPressed: onAction,
                child: Text(label),
              ),
          ],
        ),
      ),
    );
  }
}
