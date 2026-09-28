// Sets the page's theme color in the web build; does nothing on devices.
export 'browser_theme_color_io.dart'
    if (dart.library.js_interop) 'browser_theme_color_web.dart';
