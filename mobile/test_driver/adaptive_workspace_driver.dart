import 'dart:async';
import 'dart:io';
import 'dart:convert';

import 'package:integration_test/integration_test_driver_extended.dart';

/// Runs display transitions only against an explicitly selected Android emulator.
Future<void> main() async {
  final serial = Platform.environment['BUZZ_TEST_DEVICE'];
  if (serial == null || !RegExp(r'^emulator-\d+$').hasMatch(serial)) {
    throw StateError('Set BUZZ_TEST_DEVICE to the dedicated emulator serial');
  }
  Future<void> adb(List<String> args) async {
    final result = await Process.run('adb', ['-s', serial, ...args]);
    if (result.exitCode != 0) throw StateError('adb failed: ${result.stderr}');
  }

  final device = await Process.run('adb', [
    '-s',
    serial,
    'shell',
    'getprop',
    'ro.kernel.qemu',
  ]);
  if (device.exitCode != 0 || device.stdout.toString().trim() != '1') {
    throw StateError('Refusing display changes on a non-emulator device');
  }
  final directory = Directory(
    Platform.environment['BUZZ_TEST_SCREENSHOTS'] ??
        'build/adaptive-workspace-screenshots',
  );
  await directory.create(recursive: true);
  Future<void> resetDisplay() async {
    await adb(['shell', 'wm', 'size', 'reset']);
    await adb(['shell', 'wm', 'density', 'reset']);
  }

  final logcat = await Process.start('adb', [
    '-s',
    serial,
    'logcat',
    '-T',
    '1',
    '-s',
    'flutter:I',
  ]);
  final transitions = logcat.stdout
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen((line) async {
        final match = RegExp(r'BUZZ_DISPLAY:(\d+x\d+)').firstMatch(line);
        if (match != null) await adb(['shell', 'wm', 'size', match.group(1)!]);
      });
  try {
    await adb(['shell', 'wm', 'size', '2448x1848']);
    await adb(['shell', 'wm', 'density', '420']);
    await runZoned(
      () => integrationDriver(
        // integrationDriver exits the process: cleanup must run in its callback.
        writeResponseOnFailure: true,
        responseDataCallback: (_) async {
          await transitions.cancel();
          logcat.kill();
          await resetDisplay();
        },
        onScreenshot: (name, bytes, [args]) async {
          await File('${directory.path}/$name.png').writeAsBytes(bytes);
          return true;
        },
      ),
      zoneSpecification: ZoneSpecification(
        print: (self, parent, zone, line) {
          // Screenshot payloads are saved as PNGs, not repeated as huge JSON logs.
          parent.print(
            zone,
            line.startsWith('result ') ? 'Driver response received.' : line,
          );
        },
      ),
    );
  } finally {
    await transitions.cancel();
    logcat.kill();
    await resetDisplay();
  }
}
