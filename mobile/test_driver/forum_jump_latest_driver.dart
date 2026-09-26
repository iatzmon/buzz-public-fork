import 'dart:io';
import 'package:integration_test/integration_test_driver_extended.dart';

Future<void> main() async {
  final dir = Directory(
    '/Users/itamux/.buzz/OUTBOX/BUZZ_FORUM_JUMP_LATEST_20260926/screenshots',
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
