part of '../project_page.dart';

/// The project's apps. Tapping one opens it in the tab (web) or in the
/// browser (native builds).
class _AppsList extends StatelessWidget {
  const _AppsList({required this.apps, required this.onOpen});

  final List<ProjectApp> apps;
  final ValueChanged<ProjectApp> onOpen;

  @override
  Widget build(BuildContext context) {
    if (apps.isEmpty) {
      return const ProjectEmptyState(
        key: ValueKey('project-apps-empty'),
        icon: LucideIcons.appWindow,
        message: 'This project has no apps.',
        detail:
            'An agent can add one with the Buzz CLI: '
            'buzz projects update <project> --add-app <https URL> '
            '--app-label <name>',
      );
    }
    final muted = context.textTheme.bodySmall?.copyWith(
      color: context.colors.onSurfaceVariant,
    );
    return AppListCard(
      dividerIndent: Grid.xs + 32 + Grid.xs,
      verticalPadding: Grid.xxs,
      children: [
        for (final (index, app) in apps.indexed)
          KeyedSubtree(
            key: ValueKey('project-app-$index'),
            child: AppListRowRaw(
              leading: const _RowIcon(icon: LucideIcons.appWindow),
              title: Text(
                app.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.textTheme.bodyLarge,
              ),
              subtitle: Text(
                app.host,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: muted,
              ),
              trailing: Icon(
                projectAppsCanEmbed
                    ? LucideIcons.chevronRight
                    : LucideIcons.externalLink,
                size: 18,
                color: context.colors.onSurfaceVariant,
              ),
              verticalPadding: Grid.twelve,
              onTap: () => onOpen(app),
            ),
          ),
      ],
    );
  }
}

/// One project app filling the tab, under a header with its label, a way
/// back to the list, and "open in new tab".
class _AppView extends ConsumerWidget {
  const _AppView({
    super.key,
    required this.app,
    required this.project,
    required this.onBack,
  });

  final ProjectApp app;
  final Project project;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final host = BuzzProjectAppHost(
      context: context,
      ref: ref,
      project: project,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Grid.xxs),
          child: Row(
            children: [
              IconButton(
                key: const ValueKey('project-app-back'),
                tooltip: 'All apps',
                icon: const Icon(LucideIcons.arrowLeft, size: 18),
                onPressed: onBack,
              ),
              Expanded(
                child: Text(
                  app.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.textTheme.titleSmall,
                ),
              ),
              IconButton(
                key: const ValueKey('project-app-open-external'),
                tooltip: 'Open in new tab',
                icon: const Icon(LucideIcons.externalLink, size: 18),
                onPressed: () => _openExternal(context, app.url),
              ),
            ],
          ),
        ),
        Divider(height: 1, color: context.colors.outlineVariant),
        Expanded(
          child: ProjectAppFrame(
            url: app.url,
            title: app.label,
            onMessage:
                ({required origin, required fromAppFrame, required data}) =>
                    handleProjectAppMessage(
                      app: app,
                      projectApps: project.apps,
                      origin: origin,
                      fromAppFrame: fromAppFrame,
                      data: data,
                      host: host,
                    ),
          ),
        ),
      ],
    );
  }
}
