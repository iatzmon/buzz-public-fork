part of '../sessions_page.dart';

/// What the page can know about running turns, when that is less than
/// everything. Shows nothing while the activity subscription is listening.
class _SessionsStatusBanner extends StatelessWidget {
  const _SessionsStatusBanner({required this.status});

  final SessionsStatus status;

  @override
  Widget build(BuildContext context) {
    final error = status.errorMessage;
    final text = switch (status.discovery) {
      SessionsDiscovery.notConnected =>
        'Not connected. Running turns show here after the app reconnects.',
      SessionsDiscovery.connecting => 'Connecting to agent activity…',
      SessionsDiscovery.unavailable =>
        'Agent activity is unavailable${error == null ? '' : ' ($error)'}. '
            'This list may be out of date.',
      SessionsDiscovery.discovering =>
        'Looking for running turns. Agents report them about every '
            '10 seconds.',
      SessionsDiscovery.listening => null,
    };
    if (text == null) return const SizedBox.shrink();
    return Padding(
      key: const Key('sessions-status'),
      padding: const EdgeInsets.only(bottom: Grid.xs),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: context.colors.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(Radii.md),
        ),
        child: Padding(
          padding: const EdgeInsets.all(Grid.twelve),
          child: Text(text, style: context.textTheme.bodySmall),
        ),
      ),
    );
  }
}
