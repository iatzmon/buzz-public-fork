import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../shared/projects/project_task_store.dart';
import '../../shared/relay/relay.dart';
import '../../shared/theme/theme.dart';
import '../../shared/widgets/frosted_app_bar.dart';
import '../../shared/widgets/frosted_scaffold.dart';
import 'project_task_visuals.dart';

/// Durable task draft with retry of the original signed event after failure.
class ProjectTaskComposePage extends HookConsumerWidget {
  const ProjectTaskComposePage({
    super.key,
    required this.repoAddress,
    required this.scope,
    required this.viewer,
    this.channelId,
    this.repositoryName,
  });
  final String repoAddress;
  final String scope;
  final String? viewer;
  final String? channelId;

  /// Display name of the repository, shown above the form.
  final String? repositoryName;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final config = ref.watch(relayConfigProvider);
    final current = ref.watch(myPubkeyProvider);
    final sameContext = config.baseUrl == scope && current == viewer;
    final state = ref.watch(projectTaskStoreProvider(repoAddress));
    final store = ref.read(projectTaskStoreProvider(repoAddress).notifier);
    final title = useTextEditingController(
      text: sameContext ? state.title : '',
    );
    final body = useTextEditingController(text: sameContext ? state.body : '');
    final error = useState<String?>(null);
    final submitting = useState(false);
    final editable =
        !state.hasPendingCreate && !state.sending && !submitting.value;

    Future<void> submit() async {
      submitting.value = true;
      error.value = null;
      try {
        await store.saveDraft(title.text, body.text);
        if (!context.mounted ||
            ref.read(relayConfigProvider).baseUrl != scope ||
            ref.read(myPubkeyProvider) != viewer) {
          return;
        }
        await store.createTask(channelId: channelId);
        if (context.mounted) Navigator.of(context).pop();
      } catch (e) {
        if (context.mounted) error.value = '$e';
      } finally {
        if (context.mounted) submitting.value = false;
      }
    }

    InputDecoration field(String label, String hint) => InputDecoration(
      labelText: label,
      hintText: hint,
      floatingLabelBehavior: FloatingLabelBehavior.always,
      filled: true,
      fillColor: context.colors.surfaceContainerHighest,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(Radii.lg),
        borderSide: BorderSide.none,
      ),
      contentPadding: const EdgeInsets.fromLTRB(
        Grid.xs,
        Grid.twelve,
        Grid.xs,
        Grid.twelve,
      ),
    );

    return FrostedScaffold(
      useUtilitySurfaceTheme: true,
      appBar: const FrostedAppBar(title: Text('New task')),
      body: ListView(
        padding: EdgeInsets.fromLTRB(
          Grid.gutter,
          frostedAppBarHeight(context) + Grid.xs,
          Grid.gutter,
          MediaQuery.viewPaddingOf(context).bottom + Grid.lg,
        ),
        children: [
          if (!sameContext)
            const ProjectEmptyState(
              icon: LucideIcons.userRoundX,
              message:
                  'Community or account changed. Reopen Tasks to continue.',
            )
          else ...[
            if (repositoryName case final name?)
              Padding(
                padding: const EdgeInsets.only(
                  left: Grid.half,
                  bottom: Grid.twelve,
                ),
                child: Row(
                  children: [
                    Icon(
                      LucideIcons.folderGit2,
                      size: 14,
                      color: context.colors.onSurfaceVariant,
                    ),
                    const SizedBox(width: Grid.half),
                    Flexible(
                      child: Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: context.textTheme.labelMedium?.copyWith(
                          color: context.colors.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            TextField(
              controller: title,
              enabled: editable,
              autofocus: title.text.isEmpty,
              maxLength: 256,
              textCapitalization: TextCapitalization.sentences,
              style: context.textTheme.titleMedium,
              decoration: field('Title', 'What needs to be done?'),
              onChanged: (_) =>
                  unawaited(store.saveDraft(title.text, body.text)),
            ),
            const SizedBox(height: Grid.xxs),
            TextField(
              controller: body,
              enabled: editable,
              minLines: 6,
              maxLines: null,
              textCapitalization: TextCapitalization.sentences,
              decoration: field('Description', 'Add details (Markdown works)'),
              onChanged: (_) =>
                  unawaited(store.saveDraft(title.text, body.text)),
            ),
            const SizedBox(height: Grid.xs),
            if (state.hasPendingCreate)
              const ProjectNotice(
                margin: EdgeInsets.symmetric(vertical: Grid.half),
                icon: LucideIcons.cloudUpload,
                text:
                    'This task is saved and awaiting confirmation. Retry sends '
                    'the same task.',
              ),
            if (error.value ?? state.error case final message?)
              ProjectNotice(
                margin: const EdgeInsets.symmetric(vertical: Grid.half),
                icon: LucideIcons.circleAlert,
                isError: true,
                text: message,
              ),
            const SizedBox(height: Grid.xxs),
            FilledButton(
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(Grid.xl),
              ),
              onPressed: state.sending || submitting.value ? null : submit,
              child: Text(
                state.sending
                    ? 'Sending…'
                    : state.hasPendingCreate
                    ? 'Retry send'
                    : 'Create task',
              ),
            ),
          ],
        ],
      ),
    );
  }
}
