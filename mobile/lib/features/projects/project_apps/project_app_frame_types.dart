/// Handles one `message` event from a project app frame and returns the
/// reply to post back, or null for none. See `handleProjectAppMessage`.
typedef ProjectAppMessageHandler =
    Future<Map<String, Object?>?> Function({
      required String origin,
      required bool fromAppFrame,
      required Object? data,
    });
