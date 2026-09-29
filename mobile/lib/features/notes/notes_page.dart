import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../shared/deeplink/pending_deep_link_provider.dart';
import '../../shared/profile/user_cache_provider.dart';
import '../../shared/profile/user_profile.dart';
import '../../shared/relay/relay.dart';
import '../../shared/theme/theme.dart';
import '../../shared/widgets/app_list.dart';
import '../../shared/widgets/avatar_image.dart';
import '../../shared/widgets/buzz_loading_indicator.dart';
import '../../shared/widgets/frosted_app_bar.dart';
import '../../shared/widgets/frosted_scaffold.dart';
import '../channels/date_formatters.dart';
import 'long_note.dart';

part 'notes_page/author_avatar.dart';
part 'notes_page/note_reader_page.dart';
part 'notes_page/notes_message.dart';

/// Long-form notes that people and agents publish with `buzz notes`, newest
/// first. Opening one shows it in [NoteReaderPage].
class NotesPage extends HookConsumerWidget {
  const NotesPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notes = ref.watch(longNotesProvider);
    final scope = ref.watch(relayConfigProvider);
    // Notes read under another community or account are never shown.
    final loaded = notes.value;
    final current = loaded != null && loaded.scope == scope
        ? loaded.notes
        : null;
    final authors = current?.map((n) => n.author).toSet().toList() ?? [];
    useEffect(() {
      unawaited(ref.read(userCacheProvider.notifier).preload(authors));
      return null;
    }, [authors.join(',')]);
    final label = _authorLabel(ref);
    final top = frostedAppBarHeight(context) + Grid.xs;

    Widget centered(Widget child) => ListView(
      padding: EdgeInsets.only(top: top),
      children: [child],
    );

    // A failed refresh keeps the notes already read, with a visible error.
    final refreshError = notes.hasError && !notes.isLoading
        ? notes.error
        : null;
    final retry = TextButton(
      onPressed: () => ref.invalidate(longNotesProvider),
      child: const Text('Retry'),
    );

    final body = switch (current) {
      final value? when value.isEmpty && refreshError == null => centered(
        const _NotesMessage(
          icon: LucideIcons.notebookText,
          message: 'No notes yet.',
          detail: 'Agents publish notes with buzz notes set.',
        ),
      ),
      final value? => ListView(
        key: const Key('notes-page-list'),
        padding: EdgeInsets.fromLTRB(0, top, 0, Grid.lg),
        children: [
          if (refreshError != null)
            _NotesMessage(
              icon: LucideIcons.circleAlert,
              isError: true,
              message: 'Notes could not refresh.',
              detail: '$refreshError',
              action: retry,
            ),
          for (final note in value)
            AppListRowRaw(
              key: ValueKey('note-row-${note.author}-${note.slug}'),
              leading: _AuthorAvatar(pubkey: note.author),
              title: Text(
                note.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: context.textTheme.bodyLarge?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              subtitle: Text(
                '${label(note.author)} · ${relativeTime(note.updatedAt)}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: context.textTheme.bodySmall?.copyWith(
                  color: context.colors.onSurfaceVariant,
                ),
              ),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => NoteReaderPage(note: note, scope: scope),
                ),
              ),
            ),
        ],
      ),
      null when refreshError != null => centered(
        _NotesMessage(
          icon: LucideIcons.circleAlert,
          isError: true,
          message: 'Notes could not load.',
          detail: '$refreshError',
          action: retry,
        ),
      ),
      _ => const Center(child: BuzzLoadingIndicator()),
    };

    return FrostedScaffold(
      useUtilitySurfaceTheme: true,
      appBar: const FrostedAppBar(centerTitle: true, title: Text('Notes')),
      body: RefreshIndicator(
        edgeOffset: top,
        onRefresh: () async {
          try {
            ref.invalidate(longNotesProvider);
            await ref.read(longNotesProvider.future);
          } on Object {
            // Rendered from the provider state.
          }
        },
        child: body,
      ),
    );
  }
}
