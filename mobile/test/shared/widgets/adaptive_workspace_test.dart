import 'dart:ui' show DisplayFeature, DisplayFeatureState, DisplayFeatureType;

import 'package:buzz/shared/theme/theme.dart';
import 'package:buzz/shared/widgets/adaptive_workspace.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

const _list = ValueKey('workspace-list');
const _detail = ValueKey('workspace-detail');

void main() {
  Future<void> resize(WidgetTester tester, Size size) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }

  testWidgets('folding and rotation retain draft, selection and scroll state', (
    tester,
  ) async {
    addTearDown(tester.view.reset);
    await resize(tester, const Size(390, 844));
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();
    expect(find.byKey(_list), findsOneWidget);
    expect(find.byKey(_detail), findsNothing);
    await tester.tap(find.text('Open conversation'));
    await tester.pumpAndSettle();
    expect(find.byKey(_list), findsNothing);
    final editable = find.byType(EditableText);
    await tester.enterText(editable, 'Keep this draft');
    final controller = tester.widget<EditableText>(editable).controller;
    controller.selection = const TextSelection(baseOffset: 2, extentOffset: 7);
    final scrollable = find.byKey(const ValueKey('messages'));
    await tester.drag(scrollable, const Offset(0, -240));
    await tester.pumpAndSettle();
    final scrollController = tester.widget<ListView>(scrollable).controller!;
    final offset = scrollController.offset;
    for (final size in [
      const Size(800, 900),
      const Size(1100, 700),
      const Size(844, 390),
      const Size(390, 844),
      const Size(719, 900),
      const Size(720, 900),
    ]) {
      await resize(tester, size);
      expect(
        find.byKey(_list),
        size.width >= 720 ? findsOneWidget : findsNothing,
      );
      expect(
        tester.widget<EditableText>(editable).controller,
        same(controller),
      );
      expect(controller.text, 'Keep this draft');
      expect(
        controller.selection,
        const TextSelection(baseOffset: 2, extentOffset: 7),
      );
      expect(
        tester.widget<ListView>(scrollable).controller,
        same(scrollController),
      );
      expect(scrollController.offset, offset);
      final detailRect = tester.getRect(find.byKey(_detail));
      if (size.width >= 720) {
        expect(
          detailRect.left,
          greaterThan(tester.getRect(find.byKey(_list)).right),
        );
      }
    }
  });

  testWidgets(
    'system back pops thread, then conversation, then returns to list',
    (tester) async {
      addTearDown(tester.view.reset);
      await resize(tester, const Size(800, 900));
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();
      await tester.tap(find.text('Open conversation'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Open thread'));
      await tester.pumpAndSettle();
      await resize(tester, const Size(390, 844));
      expect(find.text('Thread'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('Conversation'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('Open conversation'), findsOneWidget);
      expect(find.byKey(_detail), findsNothing);
    },
  );

  testWidgets('system back respects a detail route dismissal guard', (
    tester,
  ) async {
    addTearDown(tester.view.reset);
    await resize(tester, const Size(390, 844));
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();
    final context = tester.element(find.text('Open conversation'));
    var blockedBacks = 0;
    AdaptiveWorkspace.open(
      context,
      MaterialPageRoute<void>(
        builder: (_) => PopScope<void>(
          canPop: false,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) blockedBacks++;
          },
          child: const Scaffold(body: Text('Guarded detail')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(blockedBacks, 1);
    expect(find.text('Guarded detail'), findsOneWidget);
    expect(find.byKey(_list), findsNothing);
  });

  testWidgets('selecting another conversation replaces the detail stack', (
    tester,
  ) async {
    addTearDown(tester.view.reset);
    await resize(tester, const Size(900, 900));
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open conversation'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open thread'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open conversation'));
    await tester.pumpAndSettle();
    expect(find.text('Thread'), findsNothing);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Select a conversation'), findsOneWidget);
  });

  testWidgets('pane MediaQuery gives local widths and keyboard insets', (
    tester,
  ) async {
    addTearDown(tester.view.reset);
    await resize(tester, const Size(1000, 800));
    await tester.pumpWidget(_app(bottomInset: 280));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open conversation'));
    await tester.pumpAndSettle();
    for (final key in [_list, _detail]) {
      final context = tester.element(find.byKey(key));
      expect(MediaQuery.sizeOf(context), tester.getSize(find.byKey(key)));
      expect(MediaQuery.viewInsetsOf(context).bottom, 280);
    }
    expect(
      tester.getRect(find.byType(TextField)).bottom,
      lessThanOrEqualTo(520),
    );
  });

  testWidgets('vertical hinge is a gap and RTL reverses pane order', (
    tester,
  ) async {
    addTearDown(tester.view.reset);
    await resize(tester, const Size(1000, 800));
    for (final rtl in [false, true]) {
      await tester.pumpWidget(
        _app(
          rtl: rtl,
          features: const [
            DisplayFeature(
              bounds: Rect.fromLTWH(490, 0, 20, 800),
              type: DisplayFeatureType.hinge,
              state: DisplayFeatureState.postureFlat,
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();
      final listRect = tester.getRect(find.byKey(_list));
      final detailRect = tester.getRect(find.byKey(_detail));
      expect(rtl ? detailRect.right : listRect.right, rtl ? 442 : 490);
      expect(rtl ? listRect.left : detailRect.left, rtl ? 510 : 558);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('tabletop and narrow hinged screens avoid the separating fold', (
    tester,
  ) async {
    addTearDown(tester.view.reset);
    await resize(tester, const Size(600, 900));
    await tester.pumpWidget(
      _app(
        features: const [
          DisplayFeature(
            bounds: Rect.fromLTWH(0, 400, 600, 0),
            type: DisplayFeatureType.fold,
            state: DisplayFeatureState.postureHalfOpened,
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester.getRect(find.byKey(_list)),
      const Rect.fromLTWH(0, 400, 600, 500),
    );
    await tester.pumpWidget(
      _app(
        features: const [
          DisplayFeature(
            bounds: Rect.fromLTWH(290, 0, 20, 900),
            type: DisplayFeatureType.hinge,
            state: DisplayFeatureState.postureFlat,
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.getRect(find.byKey(_list)).right, 290);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'drag clamps width, remembers it, and reset restores the default',
    (tester) async {
      addTearDown(tester.view.reset);
      await resize(tester, const Size(1100, 800));
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();
      final divider = find.byKey(const ValueKey('workspace-sidebar-divider'));
      final initial = tester.getSize(find.byKey(_list)).width;
      await tester.drag(divider, const Offset(100, 0));
      await tester.pumpAndSettle();
      final preferred = tester.getSize(find.byKey(_list)).width;
      expect(preferred, greaterThan(initial));
      await resize(tester, const Size(720, 800));
      expect(
        tester.getSize(find.byKey(_detail)).width,
        greaterThanOrEqualTo(320),
      );
      await resize(tester, const Size(1100, 800));
      expect(tester.getSize(find.byKey(_list)).width, preferred);
      await tester.drag(divider, const Offset(2000, 0));
      await tester.pumpAndSettle();
      expect(tester.getSize(find.byKey(_list)).width, 560);
      await tester.drag(divider, const Offset(-2000, 0));
      await tester.pumpAndSettle();
      expect(tester.getSize(find.byKey(_list)).width, 320);
      await tester.tap(divider);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(divider);
      await tester.pumpAndSettle();
      expect(tester.getSize(find.byKey(_list)).width, initial);
    },
  );

  testWidgets('drag accumulates pointer updates between frames', (
    tester,
  ) async {
    addTearDown(tester.view.reset);
    await resize(tester, const Size(1100, 800));
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();
    final divider = find.byKey(const ValueKey('workspace-sidebar-divider'));
    final gesture = await tester.startGesture(tester.getCenter(divider));
    await gesture.moveBy(const Offset(40, 0));
    await tester.pump();
    final before = tester.getSize(find.byKey(_list)).width;
    await gesture.moveBy(const Offset(20, 0));
    await gesture.moveBy(const Offset(20, 0));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byKey(_list)).width, before + 40);
  });

  testWidgets(
    'collapse preserves draft and scroll and reopens at the chosen width',
    (tester) async {
      addTearDown(tester.view.reset);
      await resize(tester, const Size(1000, 800));
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();
      await tester.tap(find.text('Open conversation'));
      await tester.pumpAndSettle();
      final editor = find.byType(EditableText);
      await tester.enterText(editor, 'Retained draft');
      final controller = tester.widget<EditableText>(editor).controller;
      controller.selection = const TextSelection.collapsed(offset: 3);
      final messages = find.byKey(const ValueKey('messages'));
      await tester.drag(messages, const Offset(0, -180));
      await tester.pumpAndSettle();
      final scroll = tester.widget<ListView>(messages).controller!;
      final offset = scroll.offset;
      await tester.drag(
        find.byKey(const ValueKey('workspace-sidebar-divider')),
        const Offset(75, 0),
      );
      await tester.pumpAndSettle();
      final width = tester.getSize(find.byKey(_list)).width;
      await tester.tap(find.byTooltip('Hide sidebar'));
      await tester.pumpAndSettle();
      expect(find.byKey(_list), findsNothing);
      expect(tester.getSize(find.byKey(_detail)).width, 952);
      expect(tester.widget<EditableText>(editor).controller, same(controller));
      expect(controller.selection, const TextSelection.collapsed(offset: 3));
      expect(scroll.offset, offset);
      await resize(tester, const Size(390, 844));
      expect(find.byTooltip('Show sidebar'), findsNothing);
      await resize(tester, const Size(1000, 800));
      expect(find.byKey(_list), findsNothing);
      await tester.tap(find.byTooltip('Show sidebar'));
      await tester.pumpAndSettle();
      expect(tester.getSize(find.byKey(_list)).width, width);
      expect(controller.text, 'Retained draft');
      expect(scroll.offset, offset);
    },
  );

  testWidgets('RTL drag and keyboard arrows use the physical direction', (
    tester,
  ) async {
    addTearDown(tester.view.reset);
    await resize(tester, const Size(1100, 800));
    await tester.pumpWidget(_app(rtl: true));
    await tester.pumpAndSettle();
    final divider = find.byKey(const ValueKey('workspace-sidebar-divider'));
    final initial = tester.getSize(find.byKey(_list)).width;
    await tester.drag(divider, const Offset(-80, 0));
    await tester.pumpAndSettle();
    final wider = tester.getSize(find.byKey(_list)).width;
    expect(wider, greaterThan(initial));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byKey(_list)).width, wider - 24);
    await tester.sendKeyEvent(LogicalKeyboardKey.home);
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byKey(_list)).width, initial);
  });

  testWidgets(
    'hinged displays allow collapse but never drag content across the hinge',
    (tester) async {
      addTearDown(tester.view.reset);
      await resize(tester, const Size(1000, 800));
      await tester.pumpWidget(
        _app(
          features: const [
            DisplayFeature(
              bounds: Rect.fromLTWH(490, 0, 20, 800),
              type: DisplayFeatureType.hinge,
              state: DisplayFeatureState.postureFlat,
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('workspace-sidebar-divider')),
        findsNothing,
      );
      await tester.tap(find.byTooltip('Hide sidebar'));
      await tester.pumpAndSettle();
      expect(find.byKey(_list), findsNothing);
      expect(tester.getRect(find.byKey(_detail)).left, 558);
      expect(
        tester.getRect(find.byTooltip('Show sidebar')).left,
        greaterThanOrEqualTo(510),
      );
      await tester.tap(find.byTooltip('Show sidebar'));
      await tester.pumpAndSettle();
      expect(tester.getRect(find.byKey(_list)).right, 490);
    },
  );

  for (final rtl in [false, true]) {
    testWidgets(
      'portrait tablet menu is bounded and dismisses before detail RTL=$rtl',
      (tester) async {
        addTearDown(tester.view.reset);
        await resize(tester, const Size(673, 841));
        await tester.pumpWidget(_app(rtl: rtl));
        await tester.pumpAndSettle();
        expect(tester.getSize(find.byKey(_list)).width, 320);
        expect(tester.getSize(find.byKey(_detail)).width, 625);
        final listRect = tester.getRect(find.byKey(_list));
        expect(rtl ? listRect.right : listRect.left, rtl ? 673 : 0);
        expect(
          find.byKey(const ValueKey('workspace-sidebar-divider')),
          findsNothing,
        );
        await tester.tap(find.text('Open conversation'));
        await tester.pumpAndSettle();
        expect(find.byKey(_list), findsNothing);
        await tester.enterText(find.byType(EditableText), 'Portrait draft');
        final controller = tester
            .widget<EditableText>(find.byType(EditableText))
            .controller;
        await tester.tap(find.text('Open thread'));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Show sidebar'));
        await tester.pumpAndSettle();
        expect(find.byKey(_list), findsOneWidget);
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(find.byKey(_list), findsNothing);
        expect(find.text('Thread'), findsOneWidget);
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(find.text('Conversation'), findsOneWidget);
        expect(
          tester.widget<EditableText>(find.byType(EditableText)).controller,
          same(controller),
        );
        expect(controller.text, 'Portrait draft');
        await tester.tap(find.byTooltip('Show sidebar'));
        await tester.pumpAndSettle();
        // A tap on the exposed conversation dismisses the menu without navigating.
        await tester.tapAt(Offset(rtl ? 100 : 573, 400));
        await tester.pumpAndSettle();
        expect(find.byKey(_list), findsNothing);
        expect(find.text('Conversation'), findsOneWidget);
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(find.byKey(_list), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'portrait overlay preserves landscape width and collapse preference',
    (tester) async {
      addTearDown(tester.view.reset);
      await resize(tester, const Size(1100, 800));
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();
      await tester.drag(
        find.byKey(const ValueKey('workspace-sidebar-divider')),
        const Offset(120, 0),
      );
      await tester.pumpAndSettle();
      final width = tester.getSize(find.byKey(_list)).width;
      await tester.tap(find.text('Open conversation'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Hide sidebar'));
      await tester.pumpAndSettle();
      for (final size in [
        const Size(600, 900),
        const Size(673, 841),
        const Size(719, 900),
      ]) {
        await resize(tester, size);
        expect(find.byKey(_list), findsNothing);
        await tester.tap(find.byTooltip('Show sidebar'));
        await tester.pumpAndSettle();
        expect(tester.getSize(find.byKey(_list)).width, 320);
        expect(tester.getSize(find.byKey(_detail)).width, size.width - 48);
        await tester.tap(find.byTooltip('Hide sidebar'));
        await tester.pumpAndSettle();
      }
      await resize(tester, const Size(599, 900));
      expect(find.byTooltip('Show sidebar'), findsNothing);
      await resize(tester, const Size(1100, 800));
      expect(find.byKey(_list), findsNothing);
      await tester.tap(find.byTooltip('Show sidebar'));
      await tester.pumpAndSettle();
      expect(tester.getSize(find.byKey(_list)).width, width);
    },
  );

  testWidgets('community key change clears the old conversation', (
    tester,
  ) async {
    addTearDown(tester.view.reset);
    await resize(tester, const Size(900, 900));
    await tester.pumpWidget(_app(community: 'first'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open conversation'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(_app(community: 'second'));
    await tester.pumpAndSettle();
    expect(find.text('Conversation'), findsNothing);
    expect(find.text('Select a conversation'), findsOneWidget);
  });
}

Widget _app({
  List<DisplayFeature> features = const [],
  bool rtl = false,
  double bottomInset = 0,
  String community = 'test',
}) => ProviderScope(
  child: MaterialApp(
    theme: AppTheme.light(),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(
        displayFeatures: features,
        viewInsets: EdgeInsets.only(bottom: bottomInset),
      ),
      child: Directionality(
        textDirection: rtl ? TextDirection.rtl : TextDirection.ltr,
        child: child!,
      ),
    ),
    home: AdaptiveWorkspace(
      key: ValueKey(community),
      child: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () => AdaptiveWorkspace.open(
                context,
                MaterialPageRoute<void>(builder: (_) => const _Conversation()),
              ),
              child: const Text('Open conversation'),
            ),
          ),
        ),
      ),
    ),
  ),
);

class _Conversation extends HookConsumerWidget {
  const _Conversation();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final draft = useTextEditingController();
    final scroll = useScrollController();
    return Scaffold(
      appBar: AppBar(title: const Text('Conversation')),
      body: Column(
        children: [
          TextButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) =>
                    Scaffold(appBar: AppBar(title: const Text('Thread'))),
              ),
            ),
            child: const Text('Open thread'),
          ),
          Expanded(
            child: ListView.builder(
              key: const ValueKey('messages'),
              controller: scroll,
              itemExtent: 48,
              itemCount: 100,
              itemBuilder: (_, i) => Text('Message $i'),
            ),
          ),
          TextField(controller: draft),
        ],
      ),
    );
  }
}
