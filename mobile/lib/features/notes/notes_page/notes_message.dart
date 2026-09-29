part of '../notes_page.dart';

/// A centered icon and message for the empty and error states.
class _NotesMessage extends StatelessWidget {
  const _NotesMessage({
    required this.icon,
    required this.message,
    required this.detail,
    this.action,
    this.isError = false,
  });

  final IconData icon;
  final String message;
  final String detail;
  final Widget? action;
  final bool isError;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(
      horizontal: Grid.gutter,
      vertical: Grid.lg,
    ),
    child: Column(
      children: [
        Icon(
          icon,
          size: Grid.lg,
          color: isError
              ? context.colors.error
              : context.colors.onSurfaceVariant,
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
        const SizedBox(height: Grid.half),
        Text(
          detail,
          textAlign: TextAlign.center,
          style: context.textTheme.bodySmall?.copyWith(
            color: context.colors.onSurfaceVariant,
          ),
        ),
        ?action,
      ],
    ),
  );
}
