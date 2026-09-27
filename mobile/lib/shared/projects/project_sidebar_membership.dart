import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'project_models.dart';

/// One project's sidebar membership with its last-writer-wins timestamp.
@immutable
class ProjectSidebarMembershipEntry {
  final bool selected;

  /// Milliseconds since epoch of the last change.
  final int updatedAt;

  const ProjectSidebarMembershipEntry({
    required this.selected,
    required this.updatedAt,
  });

  Map<String, Object> toJson() => {
    'selected': selected,
    'updatedAt': updatedAt,
  };
}

/// The projects a user added to their sidebar ("added" projects), keyed by
/// project address.
///
/// The JSON shape matches Desktop's `ProjectSidebarMembershipStore`
/// (`{version: 1, projects: {<address>: {selected, updatedAt}}}`) so a later
/// cross-device sync can merge entries per address. Removals are recorded as
/// `selected: false` rather than deleted for the same reason.
@immutable
class ProjectSidebarMembershipStore {
  final Map<String, ProjectSidebarMembershipEntry> projects;

  const ProjectSidebarMembershipStore({this.projects = const {}});

  /// Addresses currently added to the sidebar.
  Set<String> get selectedAddresses => {
    for (final entry in projects.entries)
      if (entry.value.selected) entry.key,
  };

  /// Returns a copy recording [address] as added or removed at [updatedAt].
  ProjectSidebarMembershipStore withSelection(
    String address, {
    required bool selected,
    required int updatedAt,
  }) => ProjectSidebarMembershipStore(
    projects: Map.unmodifiable({
      ...projects,
      address: ProjectSidebarMembershipEntry(
        selected: selected,
        updatedAt: updatedAt,
      ),
    }),
  );

  String encode() => jsonEncode({
    'version': 1,
    'projects': {
      for (final entry in projects.entries) entry.key: entry.value.toJson(),
    },
  });

  /// Parses a stored payload, accepting Desktop's legacy array-of-addresses
  /// form. Malformed payloads yield an empty store; malformed entries are
  /// dropped individually.
  static ProjectSidebarMembershipStore decode(String? raw) {
    if (raw == null || raw.isEmpty) {
      return const ProjectSidebarMembershipStore();
    }
    final Object? value;
    try {
      value = jsonDecode(raw);
    } on FormatException {
      return const ProjectSidebarMembershipStore();
    }
    if (value is List) {
      return ProjectSidebarMembershipStore(
        projects: Map.unmodifiable({
          for (final address in value)
            if (address is String && address.isNotEmpty)
              address: const ProjectSidebarMembershipEntry(
                selected: true,
                updatedAt: 0,
              ),
        }),
      );
    }
    if (value is! Map || value['version'] != 1) {
      return const ProjectSidebarMembershipStore();
    }
    final projects = value['projects'];
    if (projects is! Map) return const ProjectSidebarMembershipStore();
    return ProjectSidebarMembershipStore(
      projects: Map.unmodifiable({
        for (final entry in projects.entries)
          if (entry.key is String &&
              (entry.key as String).isNotEmpty &&
              entry.value is Map &&
              entry.value['selected'] is bool &&
              entry.value['updatedAt'] is int &&
              (entry.value['updatedAt'] as int) >= 0)
            entry.key as String: ProjectSidebarMembershipEntry(
              selected: entry.value['selected'] as bool,
              updatedAt: entry.value['updatedAt'] as int,
            ),
      }),
    );
  }
}

/// Which projects the sidebar lists.
enum SidebarProjectsFilter {
  /// Projects explicitly added to the sidebar.
  added,

  /// Every project the viewer owns, added or not.
  owned,
}

/// Sidebar project ordering.
enum SidebarProjectsSort {
  /// Case-insensitive name order.
  name,

  /// Newest first, then by name.
  created,
}

/// Explicit (non-legacy) projects for the sidebar, filtered and sorted.
///
/// Mirrors Desktop's `listSidebarProjects` in
/// `desktop/src/features/sidebar/ui/listSidebarProjects.ts`.
List<Project> listSidebarProjects({
  required Iterable<Project> projects,
  required Set<String> addedProjectAddresses,
  required String? currentPubkey,
  SidebarProjectsFilter filter = SidebarProjectsFilter.added,
  SidebarProjectsSort sort = SidebarProjectsSort.name,
}) {
  final viewer = currentPubkey?.trim().toLowerCase();
  bool matches(Project project) => switch (filter) {
    SidebarProjectsFilter.owned =>
      viewer != null && viewer.isNotEmpty && project.owner == viewer,
    SidebarProjectsFilter.added => addedProjectAddresses.contains(
      project.projectAddress,
    ),
  };
  final listed = [
    for (final project in projects)
      if (project.isExplicit && matches(project)) project,
  ];
  listed.sort((left, right) {
    if (sort == SidebarProjectsSort.created) {
      final byTime = right.createdAt.compareTo(left.createdAt);
      if (byTime != 0) return byTime;
    }
    final byName = _compareNames(left.name, right.name);
    // List.sort is unstable; the address tiebreak keeps same-name rows fixed.
    return byName != 0
        ? byName
        : left.projectAddress.compareTo(right.projectAddress);
  });
  return List.unmodifiable(listed);
}

int _compareNames(String left, String right) {
  final folded = left.toLowerCase().compareTo(right.toLowerCase());
  return folded != 0 ? folded : left.compareTo(right);
}
