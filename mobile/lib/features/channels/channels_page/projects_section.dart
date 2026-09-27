part of '../channels_page.dart';

const _kProjectsShowAddedValue = 'projects_show_added';
const _kProjectsShowOwnedValue = 'projects_show_owned';
const _kProjectsSortNameValue = 'projects_sort_name';
const _kProjectsSortCreatedValue = 'projects_sort_created';
const _kProjectsBrowseValue = 'projects_browse';

/// Whether the Projects section shows: once projects load, and only when the
/// community has a project or the viewer's list is not empty.
bool _projectsSectionVisible(WidgetRef ref) {
  final snapshot = ref.watch(activeProjectsProvider).value;
  final projects = ref.watch(sidebarProjectsProvider);
  if (snapshot == null || projects == null) return false;
  return projects.isNotEmpty || snapshot.projects.any((p) => p.isExplicit);
}

/// The channel list's Projects section: the projects the viewer added (or
/// owns), mirroring Desktop's sidebar Projects section. Hidden while the
/// community has no projects.
class _ProjectsSection extends HookConsumerWidget {
  final bool showTopDivider;

  const _ProjectsSection({required this.showTopDivider});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final expanded = useState(true);
    final view = ref.watch(projectSidebarViewProvider);
    final projects = ref.watch(sidebarProjectsProvider);
    if (projects == null || !_projectsSectionVisible(ref)) {
      return const SizedBox.shrink();
    }

    Future<void> browse() => showBuzzModalBottomSheet<void>(
      context: context,
      title: 'Browse projects',
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => const _BrowseProjectsSheet(),
    );

    return Column(
      key: const ValueKey('channels-projects-section'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (showTopDivider) const _SectionDivider(),
        _ProjectsSectionHeader(
          expanded: expanded.value,
          onToggle: () => expanded.value = !expanded.value,
          view: view,
          onBrowse: browse,
        ),
        _AnimatedSectionBody(
          expanded: expanded.value,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (projects.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(
                    left: _kChannelLabelInset - Grid.xxs,
                    right: _kChannelSectionInset,
                  ),
                  child: TextButton(
                    key: const ValueKey('channels-projects-browse-empty'),
                    onPressed: browse,
                    child: Text(
                      view.filter == SidebarProjectsFilter.owned
                          ? 'You own no projects. Browse projects'
                          : 'No projects added. Browse projects',
                    ),
                  ),
                )
              else
                for (final project in projects) _ProjectTile(project: project),
              const SizedBox(height: _kExpandedSectionTrailingPadding),
            ],
          ),
        ),
      ],
    );
  }
}

class _ProjectsSectionHeader extends ConsumerWidget {
  final bool expanded;
  final VoidCallback onToggle;
  final ProjectSidebarView view;
  final Future<void> Function() onBrowse;

  const _ProjectsSectionHeader({
    required this.expanded,
    required this.onToggle,
    required this.view,
    required this.onBrowse,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sectionColor = navigationSectionForeground(context);

    return GestureDetector(
      onTap: onToggle,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          Grid.gutter,
          _kSectionHeaderVerticalPadding,
          Grid.gutter,
          _kSectionHeaderVerticalPadding,
        ),
        child: Row(
          children: [
            SizedBox(
              width: _kChannelLeadingWidth,
              child: Align(
                alignment: Alignment.centerLeft,
                child: Icon(
                  LucideIcons.folders,
                  size: _kChannelIconSize,
                  color: sectionColor,
                ),
              ),
            ),
            const SizedBox(width: _kChannelLabelGap),
            Text(
              'Projects',
              style: contentListTitleTextStyle.copyWith(
                color: sectionColor,
                fontWeight: FontWeight.w600,
              ),
            ),
            const Spacer(),
            Builder(
              builder: (buttonContext) => IconButton(
                key: const ValueKey('sort-menu-Projects'),
                tooltip: 'Projects options',
                visualDensity: VisualDensity.compact,
                icon: Icon(
                  LucideIcons.ellipsisVertical,
                  size: _kChannelIconSize,
                  color: sectionColor,
                ),
                onPressed: () async {
                  final value = await showAnchoredPopover<String>(
                    context: buttonContext,
                    width: 232,
                    alignment: AnchoredPopoverAlignment.end,
                    color: context.colors.surface,
                    elevation: 4,
                    shadowColor: context.colors.shadow.withValues(alpha: 0.18),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(Radii.md),
                      side: BorderSide(color: context.colors.outline),
                    ),
                    surfaceKey: const ValueKey('projects-options-popover'),
                    items: [
                      _sortMenuItem(
                        value: _kProjectsShowAddedValue,
                        label: 'Show: Added',
                        selected: view.filter == SidebarProjectsFilter.added,
                      ),
                      _sortMenuItem(
                        value: _kProjectsShowOwnedValue,
                        label: 'Show: Owned by me',
                        selected: view.filter == SidebarProjectsFilter.owned,
                      ),
                      const PopupMenuDivider(),
                      _sortMenuItem(
                        value: _kProjectsSortNameValue,
                        label: 'Sort: A–Z',
                        selected: view.sort == SidebarProjectsSort.name,
                      ),
                      _sortMenuItem(
                        value: _kProjectsSortCreatedValue,
                        label: 'Sort: Newest',
                        selected: view.sort == SidebarProjectsSort.created,
                      ),
                      const PopupMenuDivider(),
                      const PopupMenuItem(
                        value: _kProjectsBrowseValue,
                        child: Text('Browse all projects'),
                      ),
                    ],
                  );
                  final notifier = ref.read(
                    projectSidebarViewProvider.notifier,
                  );
                  switch (value) {
                    case _kProjectsShowAddedValue:
                      unawaited(
                        notifier.setFilter(SidebarProjectsFilter.added),
                      );
                    case _kProjectsShowOwnedValue:
                      unawaited(
                        notifier.setFilter(SidebarProjectsFilter.owned),
                      );
                    case _kProjectsSortNameValue:
                      unawaited(notifier.setSort(SidebarProjectsSort.name));
                    case _kProjectsSortCreatedValue:
                      unawaited(notifier.setSort(SidebarProjectsSort.created));
                    case _kProjectsBrowseValue:
                      await onBrowse();
                  }
                },
              ),
            ),
            const SizedBox(width: Grid.quarter),
            _SectionChevron(expanded: expanded, color: sectionColor),
          ],
        ),
      ),
    );
  }
}

class _ProjectTile extends ConsumerWidget {
  final Project project;

  const _ProjectTile({required this.project});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final contentColor = navigationPrimaryForeground(
      context,
    ).withValues(alpha: 0.8);

    return InkWell(
      key: ValueKey('channels-project-${project.projectAddress}'),
      borderRadius: BorderRadius.circular(Radii.md),
      onTap: () => openProject(context, ref, project),
      onLongPress: () => _showProjectActions(context, ref),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: _kChannelSectionInset,
          vertical: _kChannelRowVerticalPadding,
        ),
        child: Row(
          children: [
            SizedBox(
              width: _kChannelLeadingWidth,
              child: Align(
                alignment: Alignment.centerLeft,
                child: Icon(
                  LucideIcons.folder,
                  size: _kChannelIconSize,
                  color: contentColor,
                ),
              ),
            ),
            const SizedBox(width: _kChannelLabelGap),
            Expanded(
              child: Text(
                project.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: contentListTitleTextStyle.copyWith(color: contentColor),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showProjectActions(BuildContext context, WidgetRef ref) async {
    unawaited(HapticFeedback.selectionClick());
    final added = ref
        .read(projectSidebarMembershipProvider)
        .selectedAddresses
        .contains(project.projectAddress);
    final action = await showBuzzModalBottomSheet<String>(
      context: context,
      title: project.name,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(LucideIcons.info),
              title: const Text('Project details'),
              onTap: () => Navigator.of(sheetContext).pop('details'),
            ),
            if (added)
              ListTile(
                leading: const Icon(LucideIcons.listMinus),
                title: const Text('Remove from list'),
                onTap: () => Navigator.of(sheetContext).pop('remove'),
              ),
          ],
        ),
      ),
    );
    if (!context.mounted) return;
    switch (action) {
      case 'details':
        await AdaptiveWorkspace.open(
          context,
          MaterialPageRoute<void>(
            builder: (_) => ProjectPage(projectAddress: project.projectAddress),
          ),
        );
      case 'remove':
        await ref
            .read(projectSidebarMembershipProvider.notifier)
            .remove(project.projectAddress);
    }
  }
}

class _BrowseProjectsSheet extends ConsumerWidget {
  const _BrowseProjectsSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final projectsAsync = ref.watch(activeProjectsProvider);
    final added = ref.watch(projectSidebarMembershipProvider).selectedAddresses;
    final projects =
        projectsAsync.value?.projects.where((p) => p.isExplicit).toList() ??
        const <Project>[];
    projects.sort(
      (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
    );

    final Widget body;
    if (projects.isEmpty && projectsAsync.isLoading) {
      body = const Padding(
        padding: EdgeInsets.all(Grid.sm),
        child: Center(child: BuzzLoadingIndicator()),
      );
    } else if (projects.isEmpty) {
      body = Padding(
        padding: const EdgeInsets.all(Grid.sm),
        child: Text(
          projectsAsync.hasError
              ? 'Projects could not be loaded.'
              : 'This community has no projects yet.',
          textAlign: TextAlign.center,
        ),
      );
    } else {
      body = Flexible(
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final project in projects)
              _BrowseProjectRow(
                project: project,
                added: added.contains(project.projectAddress),
              ),
          ],
        ),
      );
    }

    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              Grid.gutter,
              0,
              Grid.gutter,
              Grid.xxs,
            ),
            child: Text(
              'Add a project to show it in your list.',
              style: context.textTheme.bodyMedium?.copyWith(
                color: context.colors.onSurfaceVariant,
              ),
            ),
          ),
          body,
        ],
      ),
    );
  }
}

class _BrowseProjectRow extends ConsumerWidget {
  final Project project;
  final bool added;

  const _BrowseProjectRow({required this.project, required this.added});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final description = project.description.trim();
    return ListTile(
      key: ValueKey('browse-project-${project.projectAddress}'),
      leading: const Icon(LucideIcons.folder),
      title: Text(project.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: description.isEmpty
          ? null
          : Text(description, maxLines: 2, overflow: TextOverflow.ellipsis),
      onTap: () => AdaptiveWorkspace.open(
        context,
        MaterialPageRoute<void>(
          builder: (_) => ProjectPage(projectAddress: project.projectAddress),
        ),
      ),
      trailing: added
          ? OutlinedButton(
              key: ValueKey('browse-project-remove-${project.dtag}'),
              onPressed: () => ref
                  .read(projectSidebarMembershipProvider.notifier)
                  .remove(project.projectAddress),
              child: const Text('Remove'),
            )
          : FilledButton(
              key: ValueKey('browse-project-add-${project.dtag}'),
              onPressed: () => ref
                  .read(projectSidebarMembershipProvider.notifier)
                  .add(project.projectAddress),
              child: const Text('Add'),
            ),
    );
  }
}
