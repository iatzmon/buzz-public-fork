import 'package:buzz/features/channels/channel_detail_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../test/features/channels/channel_detail_page_test.dart'
    show buildAdaptiveWorkspaceTestApp;

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('resize and collapse preserve the real conversation on Android', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
      buildAdaptiveWorkspaceTestApp(await SharedPreferences.getInstance()),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('general'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Message #general'));
    await tester.pumpAndSettle();
    final editor = find.byType(EditableText).last;
    await tester.enterText(editor, 'Simulator draft survives sidebar changes');
    final controller = tester.widget<EditableText>(editor).controller;
    // Buzz collapses the composer when the native keyboard loses focus.
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    Future<void> verifyDraft() async {
      await tester.tap(find.text('Simulator draft survives sidebar changes'));
      await tester.pumpAndSettle();
      expect(tester.widget<EditableText>(editor).controller, same(controller));
      expect(controller.text, 'Simulator draft survives sidebar changes');
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
    }

    Future<void> changeDisplay(int width, int height) async {
      debugPrint('BUZZ_DISPLAY:${width}x$height');
      for (var attempt = 0; attempt < 100; attempt++) {
        await tester.pump(const Duration(milliseconds: 200));
        if (tester.view.physicalSize ==
            Size(width.toDouble(), height.toDouble())) {
          await tester.pumpAndSettle();
          return;
        }
      }
      fail(
        'Emulator did not resize to ${width}x$height: ${tester.view.physicalSize}',
      );
    }

    final detail = tester.element(find.byType(ChannelDetailPage));
    final list = find.byKey(const ValueKey('workspace-list'));
    final divider = find.byKey(const ValueKey('workspace-sidebar-divider'));
    final initialWidth = tester.getSize(list).width;
    await binding.convertFlutterSurfaceToImage();
    await tester.pumpAndSettle();
    await binding.takeScreenshot('01-expanded');

    await tester.drag(divider, const Offset(100, 0));
    await tester.pumpAndSettle();
    final resizedWidth = tester.getSize(list).width;
    expect(resizedWidth, greaterThan(initialWidth + 40));
    expect(tester.element(find.byType(ChannelDetailPage)), same(detail));
    await binding.takeScreenshot('02-resized');

    await tester.tap(find.byTooltip('Hide sidebar'));
    await tester.pumpAndSettle();
    expect(list, findsNothing);
    expect(find.byTooltip('Show sidebar'), findsOneWidget);
    expect(tester.element(find.byType(ChannelDetailPage)), same(detail));
    await verifyDraft();
    await binding.takeScreenshot('03-collapsed');

    await tester.tap(find.byTooltip('Show sidebar'));
    await tester.pumpAndSettle();
    expect(tester.getSize(list).width, closeTo(resizedWidth, .1));
    await binding.takeScreenshot('04-restored');

    // The host driver changes the actual emulator display on each marker.
    await changeDisplay(1248, 1972);
    await tester.pumpAndSettle(const Duration(milliseconds: 200));
    expect(list, findsNothing);
    expect(find.byTooltip('Show sidebar'), findsNothing);
    expect(tester.element(find.byType(ChannelDetailPage)), same(detail));
    await verifyDraft();
    await binding.takeScreenshot('06-cover');
    await changeDisplay(2448, 1848);
    await tester.pumpAndSettle(const Duration(milliseconds: 200));
    expect(tester.getSize(list).width, closeTo(resizedWidth, .1));
    expect(tester.element(find.byType(ChannelDetailPage)), same(detail));
    await binding.takeScreenshot('08-inner-restored');

    await tester.tap(find.byTooltip('Hide sidebar'));
    await tester.pumpAndSettle();
    await changeDisplay(1848, 2448);
    await tester.pumpAndSettle(const Duration(milliseconds: 200));
    expect(list, findsNothing);
    expect(find.byTooltip('Show sidebar'), findsOneWidget);
    await verifyDraft();
    await binding.takeScreenshot('10-portrait-conversation');
    await tester.tap(find.byTooltip('Show sidebar'));
    await tester.pumpAndSettle();
    expect(tester.getSize(list).width, 320);
    expect(tester.element(find.byType(ChannelDetailPage)), same(detail));
    await binding.takeScreenshot('10b-portrait-menu');
    await tester.tap(find.byTooltip('Hide sidebar'));
    await tester.pumpAndSettle();
    await verifyDraft();
    await changeDisplay(2448, 1848);
    await tester.pumpAndSettle(const Duration(milliseconds: 200));
    expect(find.byTooltip('Show sidebar'), findsOneWidget);
    await tester.tap(find.byTooltip('Show sidebar'));
    await tester.pumpAndSettle();
    expect(list, findsOneWidget);
    expect(tester.element(find.byType(ChannelDetailPage)), same(detail));
    await binding.takeScreenshot('11-rotated-expanded');
    expect(tester.takeException(), isNull);
  });
}
