import 'package:flutter/widgets.dart';

import 'project_app_frame_types.dart';

/// Whether this build can show a project app inside Buzz. Native builds open
/// apps in the browser instead.
const projectAppsCanEmbed = false;

/// Placeholder for native builds, which never embed a project app.
class ProjectAppFrame extends StatelessWidget {
  const ProjectAppFrame({
    super.key,
    required this.url,
    required this.title,
    required this.onMessage,
  });

  final String url;
  final String title;
  final ProjectAppMessageHandler onMessage;

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
