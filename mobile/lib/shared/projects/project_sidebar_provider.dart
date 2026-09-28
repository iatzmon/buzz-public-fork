import 'dart:convert';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../relay/relay.dart';
import '../theme/theme_provider.dart';
import 'project_models.dart';
import 'project_sidebar_membership.dart';
import 'projects_provider.dart';

const _membershipPrefsKey = 'buzz.sidebar.projects.membership.v1';
const _viewPrefsKey = 'buzz.sidebar.projects.view.v1';

/// Community- and identity-scoped preference keys (canonical + pre-canonical
/// origin), following `recentSearchesProvider`.
({String canonical, String legacy})? _scopedKeys(Ref ref, String base) {
  final config = ref.watch(relayConfigProvider);
  final pubkey = ref.watch(myPubkeyProvider)?.toLowerCase();
  if (pubkey == null || pubkey.isEmpty) return null;
  return (
    canonical: '$base:${config.baseUrl}:$pubkey',
    legacy: '$base:${config.storedOrigin}:$pubkey',
  );
}

String? _readScoped(
  SharedPreferences prefs,
  ({String canonical, String legacy}) keys,
) => readMigratedPref<String>(
  prefs,
  canonicalKey: keys.canonical,
  legacyKey: keys.legacy,
  read: prefs.getString,
  write: prefs.setString,
);

/// Device-local sidebar membership ("added" projects) for the active
/// community and account.
///
/// State is authoritative in memory; SharedPreferences is its durable mirror.
/// When a write fails the in-memory state keeps the change and the next
/// successful write persists the accumulated store.
class ProjectSidebarMembershipNotifier
    extends Notifier<ProjectSidebarMembershipStore> {
  String? _key;

  @override
  ProjectSidebarMembershipStore build() {
    final keys = _scopedKeys(ref, _membershipPrefsKey);
    _key = keys?.canonical;
    if (keys == null) return const ProjectSidebarMembershipStore();
    return ProjectSidebarMembershipStore.decode(
      _readScoped(ref.read(savedPrefsProvider), keys),
    );
  }

  /// Adds [projectAddress] to the sidebar. Resolves to whether the change was
  /// persisted; false also when there is no signing identity.
  Future<bool> add(String projectAddress) => _set(projectAddress, true);

  /// Removes [projectAddress] from the sidebar. Resolves like [add].
  Future<bool> remove(String projectAddress) => _set(projectAddress, false);

  Future<bool> _set(String projectAddress, bool selected) async {
    final key = _key;
    if (key == null || projectAddress.isEmpty) return false;
    final next = state.withSelection(
      projectAddress,
      selected: selected,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
    state = next;
    try {
      return await ref.read(savedPrefsProvider).setString(key, next.encode());
    } on Exception {
      return false;
    }
  }
}

/// Sidebar membership for the active community and account.
final projectSidebarMembershipProvider =
    NotifierProvider<
      ProjectSidebarMembershipNotifier,
      ProjectSidebarMembershipStore
    >(ProjectSidebarMembershipNotifier.new);

/// The sidebar's project filter and sort.
typedef ProjectSidebarView = ({
  SidebarProjectsFilter filter,
  SidebarProjectsSort sort,
});

const _defaultView = (
  filter: SidebarProjectsFilter.added,
  sort: SidebarProjectsSort.name,
);

/// Device-local sidebar filter/sort, scoped like the membership and stored as
/// one snapshot so a change is a single write.
class ProjectSidebarViewNotifier extends Notifier<ProjectSidebarView> {
  String? _key;

  @override
  ProjectSidebarView build() {
    final keys = _scopedKeys(ref, _viewPrefsKey);
    _key = keys?.canonical;
    if (keys == null) return _defaultView;
    final raw = _readScoped(ref.read(savedPrefsProvider), keys);
    if (raw == null) return _defaultView;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return _defaultView;
      return (
        filter: decoded['filter'] == SidebarProjectsFilter.owned.name
            ? SidebarProjectsFilter.owned
            : SidebarProjectsFilter.added,
        sort: decoded['sort'] == SidebarProjectsSort.created.name
            ? SidebarProjectsSort.created
            : SidebarProjectsSort.name,
      );
    } on FormatException {
      return _defaultView;
    }
  }

  /// Sets the filter; resolves to whether it was persisted.
  Future<bool> setFilter(SidebarProjectsFilter filter) =>
      _set((filter: filter, sort: state.sort));

  /// Sets the sort; resolves to whether it was persisted.
  Future<bool> setSort(SidebarProjectsSort sort) =>
      _set((filter: state.filter, sort: sort));

  Future<bool> _set(ProjectSidebarView view) async {
    state = view;
    final key = _key;
    if (key == null) return false;
    try {
      return await ref
          .read(savedPrefsProvider)
          .setString(
            key,
            jsonEncode({'filter': view.filter.name, 'sort': view.sort.name}),
          );
    } on Exception {
      return false;
    }
  }
}

/// Sidebar filter/sort for the active community and account.
final projectSidebarViewProvider =
    NotifierProvider<ProjectSidebarViewNotifier, ProjectSidebarView>(
      ProjectSidebarViewNotifier.new,
    );

/// Explicit projects for the sidebar under the current membership and view,
/// from the last loaded snapshot. Null before the first successful load —
/// watch [activeProjectsProvider] for loading and error state.
final sidebarProjectsProvider = Provider<List<Project>?>((ref) {
  final snapshot = ref.watch(activeProjectsProvider).value;
  if (snapshot == null) return null;
  final view = ref.watch(projectSidebarViewProvider);
  return listSidebarProjects(
    projects: snapshot.projects,
    addedProjectAddresses: ref
        .watch(projectSidebarMembershipProvider)
        .selectedAddresses,
    currentPubkey: snapshot.scope.viewerPubkey,
    filter: view.filter,
    sort: view.sort,
  );
});
