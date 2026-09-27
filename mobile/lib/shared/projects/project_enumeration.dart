import 'dart:math';

import '../relay/nostr_models.dart';
import 'project_event_set.dart';
import 'project_event_verification.dart';
import 'project_read_models.dart' show eventCoordinate;

/// Fetches one relay page for [filter].
typedef ProjectEventPageFetcher =
    Future<List<NostrEvent>> Function(NostrFilter filter);

/// Page size for exhaustive project enumeration (Desktop parity).
const projectEnumerationPageSize = 500;

/// Upper bound on pages per enumeration. Exceeding it fails the load rather
/// than presenting a silently truncated collection.
const projectEnumerationMaxPages = 40;

/// Authors per tombstone query; keeps the SQL `authors` IN-list bounded.
const _tombstoneAuthorChunkSize = 100;

final _hexPubkey = RegExp(r'^[0-9a-fA-F]{64}$');

/// A project collection could not be loaded completely.
///
/// Thrown instead of returning a partial collection: a missing tombstone set
/// would resurrect deleted projects, and a truncated page would hide some.
class ProjectsLoadException implements Exception {
  final String message;
  final Object? cause;
  const ProjectsLoadException(this.message, [this.cause]);

  @override
  String toString() =>
      cause == null ? 'ProjectsLoadException: $message' : '$message ($cause)';
}

/// A load was abandoned because its community or identity is no longer
/// active. Never surfaced as a user-visible error.
class ProjectsCancelledException implements Exception {
  const ProjectsCancelledException();
}

/// Enumerates every event matching the filter with the NIP-MP boundary-bucket
/// drain: a bare `until` cursor only advances past a second once every event
/// in that second has been retrieved.
///
/// Only SQL-pushable constraints (kinds, authors, since) belong here. The
/// relay applies other tag filters such as `#a` *after* its SQL limit, so a
/// short page would be mistaken for the end of the collection.
///
/// [isCancelled] is checked before each page so an abandoned load stops
/// queuing requests.
Future<List<NostrEvent>> enumerateProjectEvents(
  ProjectEventPageFetcher fetchPage,
  List<int> kinds, {
  List<String>? authors,
  int? since,
  int pageSize = projectEnumerationPageSize,
  int maxPages = projectEnumerationMaxPages,
  bool Function()? isCancelled,
}) async {
  if (pageSize <= 0) {
    throw ArgumentError.value(pageSize, 'pageSize', 'must be positive');
  }
  final eventsById = <String, NostrEvent>{};
  int? until;
  for (var pages = 0; ; pages++) {
    if (pages >= maxPages) {
      throw ProjectsLoadException(
        'Too many project events to enumerate (more than $maxPages pages).',
      );
    }
    _throwIfCancelled(isCancelled);
    final page = await fetchPage(
      NostrFilter(
        kinds: kinds,
        authors: authors,
        limit: pageSize,
        since: since,
        until: until,
      ),
    );
    for (final event in page) {
      eventsById[event.id] = event;
    }
    if (page.length < pageSize) return eventsById.values.toList();

    final oldest = page.map((event) => event.createdAt).reduce(min);
    _throwIfCancelled(isCancelled);
    final boundary = await fetchPage(
      NostrFilter(
        kinds: kinds,
        authors: authors,
        limit: pageSize,
        since: oldest,
        until: oldest,
      ),
    );
    for (final event in boundary) {
      eventsById[event.id] = event;
    }
    if (boundary.length >= pageSize) {
      throw const ProjectsLoadException(
        'The relay cannot exhaustively enumerate projects because too many '
        'events share one timestamp.',
      );
    }
    if (oldest <= (since ?? 0)) return eventsById.values.toList();
    until = oldest - 1;
  }
}

/// Fetches projects (kind:30621), repositories (kind:30617), and the kind:5
/// tombstones that address them.
///
/// Every event passes [verifyEvents] after enumeration and before it is used:
/// announcements before they choose the tombstone authors, and tombstones
/// before they are returned. Verification runs on the complete enumeration,
/// never per page, so a dropped event cannot shorten a page and end the
/// enumeration early. Production passes [verifyProjectEvents].
///
/// Tombstones are fetched after the announcements, fail closed (a failure
/// fails the whole load), and are scoped with SQL-pushable constraints only:
/// the authors who may delete an announced coordinate (its signer, or the
/// NIP-OA owner named in its `auth` tag) since the oldest such announcement.
/// This query only narrows the fetch: the fold authorizes each tombstone
/// against the exact coordinate it names (`buildDeletionThresholds`).
/// Desktop scopes with `#a` instead, which the relay applies after its limit
/// and can therefore miss tombstones.
Future<ProjectEventSet> fetchProjectEvents(
  ProjectEventPageFetcher fetchPage, {
  required ProjectEventVerifier verifyEvents,
  bool Function()? isCancelled,
}) async {
  final enumerated = await Future.wait([
    enumerateProjectEvents(fetchPage, [
      EventKind.projectAnnouncement,
    ], isCancelled: isCancelled),
    enumerateProjectEvents(fetchPage, [
      EventKind.repoAnnouncement,
    ], isCancelled: isCancelled),
  ]);
  _throwIfCancelled(isCancelled);
  final projectEvents = await verifyEvents(enumerated[0]);
  final repositoryEvents = await verifyEvents(enumerated[1]);
  _throwIfCancelled(isCancelled);

  final List<NostrEvent> deletionEvents;
  try {
    deletionEvents = await verifyEvents(
      await _fetchTombstones(fetchPage, [
        ...projectEvents,
        ...repositoryEvents,
      ], isCancelled),
    );
  } on ProjectsCancelledException {
    rethrow;
  } catch (error) {
    throw ProjectsLoadException(
      'Could not fetch project deletion records — refresh to retry.',
      error,
    );
  }
  _throwIfCancelled(isCancelled);
  return ProjectEventSet(
    projectEvents: projectEvents,
    repositoryEvents: repositoryEvents,
    deletionEvents: deletionEvents,
  );
}

Future<List<NostrEvent>> _fetchTombstones(
  ProjectEventPageFetcher fetchPage,
  List<NostrEvent> announcements,
  bool Function()? isCancelled,
) async {
  final coordinates = <String>{};
  // Earliest announcement each potential deleter could have tombstoned.
  final sinceByAuthor = <String, int>{};
  void admit(String author, int createdAt) {
    final existing = sinceByAuthor[author];
    if (existing == null || createdAt < existing) {
      sinceByAuthor[author] = createdAt;
    }
  }

  for (final event in announcements) {
    final coordinate = eventCoordinate(event);
    if (coordinate == null || !_hexPubkey.hasMatch(event.pubkey)) continue;
    coordinates.add(coordinate);
    admit(event.pubkey.toLowerCase(), event.createdAt);
    for (final tag in event.tags) {
      if (tag.length > 1 && tag[0] == 'auth' && _hexPubkey.hasMatch(tag[1])) {
        admit(tag[1].toLowerCase(), event.createdAt);
      }
    }
  }
  if (coordinates.isEmpty) return const [];

  final authors = sinceByAuthor.keys.toList()..sort();
  final pages = await Future.wait([
    for (var i = 0; i < authors.length; i += _tombstoneAuthorChunkSize)
      () {
        final chunk = authors.sublist(
          i,
          min(i + _tombstoneAuthorChunkSize, authors.length),
        );
        return enumerateProjectEvents(
          fetchPage,
          [EventKind.deletion],
          authors: chunk,
          since: chunk.map((author) => sinceByAuthor[author]!).reduce(min),
          isCancelled: isCancelled,
        );
      }(),
  ]);
  return [
    for (final page in pages)
      for (final event in page)
        if (event.tags.any(
          (tag) =>
              tag.length > 1 && tag[0] == 'a' && coordinates.contains(tag[1]),
        ))
          event,
  ];
}

void _throwIfCancelled(bool Function()? isCancelled) {
  if (isCancelled?.call() ?? false) throw const ProjectsCancelledException();
}
