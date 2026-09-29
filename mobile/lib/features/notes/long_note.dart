import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../shared/projects/project_event_verification.dart';
import '../../shared/relay/relay.dart';

/// Kind:30023 NIP-23 long-form note, published with `buzz notes set`.
const longNoteKind = 30023;

/// One long-form note: the newest version for its author and `d` slug.
class LongNote {
  const LongNote({
    required this.event,
    required this.slug,
    required this.title,
    this.summary,
    this.publishedAt,
  });

  final NostrEvent event;
  final String slug;
  final String title;
  final String? summary;

  /// First publication time; [updatedAt] is the time of this version.
  final int? publishedAt;

  String get author => event.pubkey.toLowerCase();
  String get content => event.content;
  int get updatedAt => event.createdAt;

  /// Null when [event] is not a long-form note or has no `d` slug.
  static LongNote? fromEvent(NostrEvent event) {
    if (event.kind != longNoteKind) return null;
    final slug = event.getTagValue('d');
    if (slug == null || slug.isEmpty) return null;
    final title = event.getTagValue('title')?.trim() ?? '';
    final summary = event.getTagValue('summary')?.trim() ?? '';
    return LongNote(
      event: event,
      slug: slug,
      title: title.isEmpty ? slug : title,
      summary: summary.isEmpty ? null : summary,
      publishedAt: int.tryParse(event.getTagValue('published_at') ?? ''),
    );
  }
}

/// The newest version of each note, most recently updated first.
List<LongNote> latestLongNotes(Iterable<NostrEvent> events) {
  final latest = <String, LongNote>{};
  for (final event in events) {
    final note = LongNote.fromEvent(event);
    if (note == null) continue;
    final key = '${note.author}:${note.slug}';
    final current = latest[key];
    if (current == null ||
        note.updatedAt > current.updatedAt ||
        (note.updatedAt == current.updatedAt &&
            note.event.id.compareTo(current.event.id) < 0)) {
      latest[key] = note;
    }
  }
  return latest.values.toList()..sort((a, b) {
    final time = b.updatedAt.compareTo(a.updatedAt);
    return time == 0 ? a.event.id.compareTo(b.event.id) : time;
  });
}

/// Notes and the community and account they were read for.
class LongNoteList {
  const LongNoteList({required this.scope, required this.notes});

  /// Show [notes] only while this is still the active relay config: a failed
  /// load after a switch keeps the old list as the provider's last value.
  final RelayConfig scope;
  final List<LongNote> notes;
}

/// Every author's long-form notes in the current community. Reloads when the
/// community or account changes. The relay is not trusted: a note whose id or
/// signature does not verify is dropped before it is shown under an author.
final longNotesProvider = FutureProvider.autoDispose<LongNoteList>((ref) async {
  final scope = ref.watch(relayConfigProvider);
  final session = ref.watch(relaySessionProvider.notifier);
  final events = await session.queryRelay([
    NostrFilter(kinds: const [longNoteKind], limit: 200),
  ]);
  final verified = await ref.read(longNoteVerifierProvider)(events);
  return LongNoteList(scope: scope, notes: latestLongNotes(verified));
});

/// Checks notes before they are shown. Tests replace the background isolate
/// with an inline check of the same signatures.
final longNoteVerifierProvider = Provider<ProjectEventVerifier>(
  (ref) => verifyProjectEvents,
);
