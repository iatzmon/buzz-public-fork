/// Shared project data layer: NIP-MP projects (kind:30621), NIP-34
/// repositories (kind:30617), deletion tombstones, project-home lookup,
/// repository host classification, and sidebar membership.
///
/// UI entry points:
/// - [activeProjectsProvider] — the active community's [ProjectsSnapshot]
///   (cached last-good snapshot first when offline; loading/error keep the
///   previous snapshot in `.value`);
///   [activeProjectsNotifierProvider] exposes `refresh()`.
/// - [projectHomeForChannelProvider] / [isProjectHomeChannelProvider] — the
///   project whose home is a channel (stream or forum).
/// - [projectByAddressProvider] — lookup by project address.
/// - [sidebarProjectsProvider], [projectSidebarMembershipProvider],
///   [projectSidebarViewProvider] — the sidebar's "added"/"owned" list.
/// - [listProjectBoundChannels] — the home, related, and repository channels.
/// - [projectRepoPresentation] — Buzz-hosted vs external host and the
///   "Open on `host`" link for a repository.
/// - [ProjectApp] / [projectAppsFromTags] — web apps linked with `buzz-app`
///   tags.
library;

export 'project_apps.dart';
export 'project_bound_channels.dart';
export 'project_enumeration.dart' show ProjectsLoadException;
export 'project_home.dart'
    show
        findProjectHomeByChannelId,
        hasAuthoritativeHomeBinding,
        isProjectHomeChannel;
export 'project_models.dart';
export 'project_repo_host.dart';
export 'project_sidebar_membership.dart'
    show
        ProjectSidebarMembershipStore,
        SidebarProjectsFilter,
        SidebarProjectsSort;
export 'project_sidebar_provider.dart';
export 'project_snapshot.dart' show ProjectScope, ProjectsSnapshot;
export 'projects_provider.dart';
