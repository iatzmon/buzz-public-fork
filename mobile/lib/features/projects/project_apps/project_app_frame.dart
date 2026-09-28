// Embeds a project app in an iframe in the web build; native builds have a
// placeholder and open apps in the browser.
export 'project_app_frame_io.dart'
    if (dart.library.js_interop) 'project_app_frame_web.dart';
export 'project_app_frame_types.dart';
