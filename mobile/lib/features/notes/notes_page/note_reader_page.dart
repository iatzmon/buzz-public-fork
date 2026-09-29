part of '../notes_page.dart';

/// One long-form note: title, author, dates, and its Markdown body.
class NoteReaderPage extends HookConsumerWidget {
  const NoteReaderPage({super.key, required this.note});

  final LongNote note;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    useEffect(() {
      unawaited(ref.read(userCacheProvider.notifier).preload([note.author]));
      return null;
    }, [note.author]);
    final label = _authorLabel(ref);
    final muted = context.textTheme.bodySmall?.copyWith(
      color: context.colors.onSurfaceVariant,
    );
    final published = note.publishedAt;
    final dates = published == null || published == note.updatedAt
        ? relativeTime(note.updatedAt)
        : 'updated ${relativeTime(note.updatedAt)} · '
              'first published ${relativeTime(published)}';

    return FrostedScaffold(
      useUtilitySurfaceTheme: true,
      appBar: const FrostedAppBar(centerTitle: true, title: Text('Note')),
      body: SelectionArea(
        child: ListView(
          key: const Key('note-reader'),
          padding: EdgeInsets.fromLTRB(
            Grid.gutter,
            frostedAppBarHeight(context) + Grid.xs,
            Grid.gutter,
            Grid.lg,
          ),
          children: [
            Text(note.title, style: context.textTheme.headlineSmall),
            const SizedBox(height: Grid.xs),
            Row(
              children: [
                _AuthorAvatar(pubkey: note.author, radius: 12),
                const SizedBox(width: Grid.xxs),
                Expanded(
                  child: Text('${label(note.author)} · $dates', style: muted),
                ),
              ],
            ),
            if (note.summary case final summary?) ...[
              const SizedBox(height: Grid.xs),
              Text(summary, style: context.textTheme.bodyMedium),
            ],
            const SizedBox(height: Grid.sm),
            GptMarkdown(note.content, style: context.textTheme.bodyMedium),
          ],
        ),
      ),
    );
  }
}
