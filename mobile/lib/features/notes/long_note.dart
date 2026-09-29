import 'package:hooks_riverpod/hooks_riverpod.dart';

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

/// Every author's long-form notes in the current community. Reloads when the
/// community or account changes.
final longNotesProvider = FutureProvider.autoDispose<List<LongNote>>((
  ref,
) async {
  ref.watch(relayConfigProvider);
  final session = ref.watch(relaySessionProvider.notifier);
  final events = await session.queryRelay([
    NostrFilter(kinds: const [longNoteKind], limit: 200),
  ]);
  return latestLongNotes(events);
});
