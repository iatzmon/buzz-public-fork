import 'dart:io';
import 'package:integration_test/integration_test_driver_extended.dart';

Future<void> main() async {
  final dir = Directory(
    Platform.environment['BUZZ_SCREENSHOT_DIR'] ??
        'build/integration_screenshots/forum_jump_latest',
  );
  await dir.create(recursive: true);
  await integrationDriver(
    writeResponseOnFailure: true,
    onScreenshot: (name, bytes, [args]) async {
      await File('${dir.path}/$name.png').writeAsBytes(bytes);
      return true;
    },
  );
}
