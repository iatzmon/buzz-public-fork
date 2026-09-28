// Opens a WebSocket with the platform's transport: dart:io on devices,
// the browser's WebSocket on the web build.
export 'web_socket_connect_io.dart'
    if (dart.library.js_interop) 'web_socket_connect_web.dart';
