import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../shared/deeplink/pending_deep_link_provider.dart';
import '../../../shared/projects/projects.dart';
import '../../../shared/widgets/adaptive_workspace.dart';
import '../../activity/compose_drafts_provider.dart';
import '../../channels/channel.dart';
import '../../channels/channel_detail_page.dart';
import '../../channels/channels_provider.dart';
import 'project_app_bridge.dart';

/// What an embedded app may do in Buzz: draft a message in the project's
/// home channel, and open links.
class BuzzProjectAppHost implements ProjectAppHost {
  BuzzProjectAppHost({
    required this.context,
    required this.ref,
    required this.project,
  });

  final BuildContext context;
  final WidgetRef ref;
  final Project project;

  @override
  Future<void> draftMessage(String text) async {
    final channelId = project.projectChannelId;
    if (channelId == null) {
      throw const ProjectAppHostException('This project has no home channel.');
    }
    final channel = (ref.read(channelsProvider).value ?? const <Channel>[])
        .where((candidate) => candidate.id == channelId)
        .firstOrNull;
    if (channel == null) {
      throw const ProjectAppHostException(
        'The project home channel is not available to you.',
      );
    }
    if (channel.isArchived) {
      throw const ProjectAppHostException(
        'The project home channel is archived.',
      );
    }
    if (!context.mounted) {
      throw const ProjectAppHostException('The app is no longer open.');
    }
    // The composer reads this draft when the channel opens. An unsent draft
    // the user already had is kept above the new text.
    final drafts = ref.read(composeDraftsProvider.notifier);
    final key = composeDraftKey(channel.id);
    final existing = drafts.draftFor(key);
    final previous = existing?.text.trimRight() ?? '';
    drafts.save(
      key: key,
      channelId: channel.id,
      text: previous.isEmpty ? text : '$previous\n\n$text',
      mentionKeys: existing?.mentionKeys ?? const {},
    );
    unawaited(
      AdaptiveWorkspace.open(
        context,
        MaterialPageRoute<void>(
          builder: (_) =>
              ChannelDetailPage(channel: channel, startForumPost: true),
        ),
      ),
    );
  }

  @override
  Future<void> openBuzzLink(Uri uri) async =>
      ref.read(pendingDeepLinkProvider.notifier).open(uri);

  @override
  Future<void> openWebLink(Uri uri) async {
    final opened = await launchUrl(uri, webOnlyWindowName: '_blank');
    if (!opened) {
      throw const ProjectAppHostException('The link could not be opened.');
    }
  }
}
