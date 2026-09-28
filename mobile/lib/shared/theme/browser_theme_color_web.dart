import 'dart:js_interop';

import 'package:flutter/painting.dart';

@JS('document')
external _Document get _document;

extension type _Document._(JSObject _) implements JSObject {
  external _Element? getElementById(String id);
}

extension type _Element._(JSObject _) implements JSObject {
  external void setAttribute(String name, String value);
}

/// Writes [color] to the `buzz-theme-color` meta tag in `web/index.html`.
///
/// That tag comes before the one Flutter adds, so the browser uses it. Flutter
/// writes the app bar's transparent status bar color into its own tag. With
/// that color, a Home Screen web app on iPad showed a white status bar.
void setBrowserThemeColor(Color color) {
  final hex = (color.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0');
  _document
      .getElementById('buzz-theme-color')
      ?.setAttribute('content', '#$hex');
}
