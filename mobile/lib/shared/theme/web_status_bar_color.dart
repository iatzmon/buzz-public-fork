import 'package:flutter/material.dart';

import 'browser_theme_color.dart';
import 'theme_extensions.dart';

/// The color the browser should paint behind its status bar: the top of the
/// app's top section, so the bar continues the sidebar or header below it.
Color webStatusBarColor(BuildContext context) {
  final gradient = context.appColors.topSectionGradient;
  final color = gradient is LinearGradient && gradient.colors.isNotEmpty
      ? gradient.colors.first
      : context.colors.surface;
  return color.withAlpha(0xFF);
}

/// Keeps the page's theme color at [webStatusBarColor] in the browser.
///
/// A Home Screen web app on iPad draws its status bar in the theme color.
/// Place this below [MaterialApp] so it reads the applied theme and follows
/// theme and light/dark changes. On devices [setThemeColor] does nothing.
class WebStatusBarColor extends StatelessWidget {
  const WebStatusBarColor({
    super.key,
    required this.child,
    this.setThemeColor = setBrowserThemeColor,
  });

  final Widget child;
  @visibleForTesting
  final void Function(Color color) setThemeColor;

  @override
  Widget build(BuildContext context) {
    setThemeColor(webStatusBarColor(context));
    return child;
  }
}
