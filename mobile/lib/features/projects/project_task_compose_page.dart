import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../shared/projects/project_task_store.dart';
import '../../shared/relay/relay.dart';
import '../../shared/theme/theme.dart';

/// Durable task draft with retry of the original signed event after failure.
class ProjectTaskComposePage extends HookConsumerWidget {
  const ProjectTaskComposePage({
    super.key,
    required this.repoAddress,
    required this.scope,
    required this.viewer,
    this.channelId,
  });
  final String repoAddress;
  final String scope;
  final String? viewer;
  final String? channelId;

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
    return Scaffold(
      appBar: AppBar(title: const Text('Create task')),
      body: Padding(
        padding: const EdgeInsets.all(Grid.gutter),
        child: ListView(
          children: [
            if (!sameContext)
              const Text(
                'Community or account changed. Reopen Tasks to continue.',
              )
            else ...[
              TextField(
                controller: title,
                enabled:
                    !state.hasPendingCreate &&
                    !state.sending &&
                    !submitting.value,
                maxLength: 256,
                decoration: const InputDecoration(labelText: 'Title'),
                onChanged: (_) =>
                    unawaited(store.saveDraft(title.text, body.text)),
              ),
              const SizedBox(height: Grid.xs),
              TextField(
                controller: body,
                enabled:
                    !state.hasPendingCreate &&
                    !state.sending &&
                    !submitting.value,
                minLines: 5,
                maxLines: null,
                decoration: const InputDecoration(labelText: 'Description'),
                onChanged: (_) =>
                    unawaited(store.saveDraft(title.text, body.text)),
              ),
              const SizedBox(height: Grid.xs),
              if (state.hasPendingCreate)
                const Text(
                  'This task is saved and awaiting confirmation. Retry sends the same task.',
                ),
              if (error.value != null || state.error != null)
                Text(
                  error.value ?? state.error!,
                  style: TextStyle(color: context.colors.error),
                ),
              FilledButton(
                onPressed: state.sending || submitting.value
                    ? null
                    : () async {
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
                      },
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
      ),
    );
  }
}
