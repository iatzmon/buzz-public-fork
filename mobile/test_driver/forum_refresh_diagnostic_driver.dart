import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:integration_test/integration_test_driver_extended.dart';

Future<void> main() async {
  const serial = 'emulator-5580';
  Future<void> adb(List<String> args) async {
    final result = await Process.run('adb', ['-s', serial, ...args]);
    if (result.exitCode != 0) {
      throw StateError('Emulator command failed: ${result.stderr}');
    }
  }

  final device = await Process.run('adb', [
    '-s',
    serial,
    'shell',
    'getprop',
    'ro.kernel.qemu',
  ]);
  if (device.stdout.toString().trim() != '1') {
    throw StateError('Expected dedicated emulator');
  }
  final log = await Process.start('adb', [
    '-s',
    serial,
    'logcat',
    '-T',
    '1',
    '-s',
    'flutter:I',
  ]);
  var triggered = false;
  final subscription = log.stdout
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen((line) async {
        if (!triggered && line.contains('FORUM_NATIVE_BACKGROUND_REQUEST')) {
          triggered = true;
          await adb([
            'shell',
            'am',
            'start',
            '-a',
            'android.intent.action.MAIN',
            '-c',
            'android.intent.category.HOME',
          ]);
          await Future<void>.delayed(const Duration(seconds: 7));
          await adb([
            'shell',
            'am',
            'start',
            '-n',
            'xyz.block.buzz.mobile/.MainActivity',
          ]);
        }
      });
  final dir = Directory(
    '/private/tmp/buzz-forum-emulator-native-screenshots-20260926',
  );
  await dir.create(recursive: true);
  await runZoned(
    () => integrationDriver(
      writeResponseOnFailure: true,
      responseDataCallback: (_) async {
        await subscription.cancel();
        log.kill();
      },
      onScreenshot: (name, bytes, [args]) async {
        await File('${dir.path}/$name.png').writeAsBytes(bytes);
        return true;
      },
    ),
    zoneSpecification: ZoneSpecification(
      print: (self, parent, zone, line) {
        parent.print(
          zone,
          line.startsWith('result ') ? 'Driver response received.' : line,
        );
      },
    ),
  );
}
