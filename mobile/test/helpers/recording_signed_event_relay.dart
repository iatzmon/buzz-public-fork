import 'package:buzz/features/channels/channel_management_provider.dart';
import 'package:buzz/shared/relay/relay.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// One event handed to [RecordingSignedEventRelay.submit].
typedef RecordedSubmission = ({
  int kind,
  String content,
  List<List<String>> tags,
});

/// A [SignedEventRelay] that records every submission instead of signing and
/// sending it, so tests can assert the exact kind and tags production code
/// publishes.
class RecordingSignedEventRelay implements SignedEventRelay {
  RecordingSignedEventRelay({this.onSubmit, this.error});

  /// Runs after a submission is recorded (e.g. to mutate a fake relay store).
  final void Function(RecordedSubmission submission)? onSubmit;

  /// When non-null, [submit] records the attempt and then throws this.
  final Object? error;

  final submissions = <RecordedSubmission>[];

  @override
  String? get pubkey => 'self';

  @override
  Future<NostrEvent> submit({
    required int kind,
    required String content,
    required List<List<String>> tags,
    int? createdAt,
    void Function(NostrEvent event)? onSigned,
  }) async {
    final submission = (kind: kind, content: content, tags: tags);
    submissions.add(submission);
    final failure = error;
    if (failure != null) throw failure;
    onSubmit?.call(submission);
    return NostrEvent(
      id: 'recorded-${submissions.length}',
      pubkey: 'self',
      createdAt: createdAt ?? 0,
      kind: kind,
      tags: tags,
      content: content,
      sig: '',
    );
  }
}

/// Builds a real [ChannelActions] that publishes through [relay], for use with
/// `channelActionsProvider.overrideWith(...)`.
ChannelActions Function(Ref ref) recordingChannelActions(
  RecordingSignedEventRelay relay,
) {
  return (ref) => ChannelActions(
    ref: ref,
    session: ref.read(relaySessionProvider.notifier),
    signedEventRelay: relay,
    currentPubkey: 'self',
  );
}
