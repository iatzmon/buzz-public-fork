import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:buzz/shared/theme/app_theme.dart';
import 'package:buzz/shared/theme/buzz_theme.dart';
import 'package:buzz/shared/theme/web_status_bar_color.dart';

void main() {
  Future<List<Color>> pump(
    WidgetTester tester, {
    required ThemeData theme,
    ThemeData? darkTheme,
    ThemeMode themeMode = ThemeMode.light,
  }) async {
    final colors = <Color>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        darkTheme: darkTheme,
        themeMode: themeMode,
        builder: (context, child) =>
            WebStatusBarColor(setThemeColor: colors.add, child: child!),
        home: const SizedBox(),
      ),
    );
    return colors;
  }

  testWidgets('uses the top of the Buzz gradient', (tester) async {
    final gradient = buzzTopSectionGradient(buzzThemeName, Brightness.light)!;
    final colors = await pump(
      tester,
      theme: AppTheme.light(topSectionGradient: gradient),
    );

    expect(colors.last, gradient.colors.first);
  });

  testWidgets('follows the applied dark theme', (tester) async {
    final light = buzzTopSectionGradient(buzzThemeName, Brightness.light)!;
    final dark = buzzTopSectionGradient(buzzThemeName, Brightness.dark)!;
    final colors = await pump(
      tester,
      theme: AppTheme.light(topSectionGradient: light),
      darkTheme: AppTheme.dark(topSectionGradient: dark),
      themeMode: ThemeMode.dark,
    );

    expect(colors.last, dark.colors.first);
  });

  testWidgets('uses the opaque surface color without a gradient', (
    tester,
  ) async {
    final theme = AppTheme.light();
    final colors = await pump(tester, theme: theme);

    expect(colors.last, theme.colorScheme.surface.withAlpha(0xFF));
    expect(colors.last.a, 1.0);
  });
}
