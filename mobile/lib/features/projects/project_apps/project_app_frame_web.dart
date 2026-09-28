import 'dart:async';
import 'dart:js_interop';
import 'dart:ui_web' as ui_web;

import 'package:flutter/widgets.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:web/web.dart' as web;

import 'project_app_frame_types.dart';

/// Whether this build can show a project app inside Buzz.
const projectAppsCanEmbed = true;

const _viewType = 'buzz-project-app';

/// iframe `sandbox` tokens: the app runs scripts at its own origin, submits
/// forms, and opens links in new tabs. Nothing else.
const projectAppSandbox =
    'allow-scripts allow-same-origin allow-forms allow-popups';

var _factoryRegistered = false;

/// iframes the factory created, until their widget claims them.
final _createdFrames = <int, web.HTMLIFrameElement>{};

void _registerFactory() {
  if (_factoryRegistered) return;
  _factoryRegistered = true;
  ui_web.platformViewRegistry.registerViewFactory(_viewType, (
    int viewId, {
    Object? params,
  }) {
    final args = params is Map ? params : const {};
    final iframe = web.HTMLIFrameElement()
      ..src = '${args['src'] ?? 'about:blank'}'
      ..title = '${args['title'] ?? ''}'
      ..allow = ''
      ..referrerPolicy = 'strict-origin-when-cross-origin';
    iframe.setAttribute('sandbox', projectAppSandbox);
    iframe.style
      ..border = 'none'
      ..width = '100%'
      ..height = '100%';
    _createdFrames[viewId] = iframe;
    return iframe;
  });
}

/// A project app in a sandboxed iframe, with its `postMessage` bridge.
///
/// `message` events from this iframe reach [onMessage]; events from any other
/// window are dropped. A non-null reply is posted back to the iframe,
/// addressed to the event's origin.
class ProjectAppFrame extends HookWidget {
  const ProjectAppFrame({
    super.key,
    required this.url,
    required this.title,
    required this.onMessage,
  });

  final String url;
  final String title;
  final ProjectAppMessageHandler onMessage;

  @override
  Widget build(BuildContext context) {
    final iframe = useRef<web.HTMLIFrameElement?>(null);
    final handler = useRef(onMessage)..value = onMessage;

    useEffect(() {
      void listener(web.MessageEvent event) {
        final window = iframe.value?.contentWindow;
        final source = event.source;
        // Other frames (and the page itself) post messages too; they never
        // reach the app bridge.
        if (window == null || source == null) return;
        final fromAppFrame = source.strictEquals(window).toDart;
        if (!fromAppFrame) return;
        final origin = event.origin;
        Object? data;
        try {
          data = event.data.dartify();
        } catch (_) {
          return;
        }
        unawaited(
          handler
              .value(origin: origin, fromAppFrame: fromAppFrame, data: data)
              .then((reply) {
                if (reply == null) return;
                // The frame may have navigated away; only its own origin
                // receives the reply.
                window.postMessage(reply.jsify(), origin.toJS);
              })
              .catchError((Object error) {
                debugPrint('project-app: reply failed: $error');
              }),
        );
      }

      final jsListener = listener.toJS;
      web.window.addEventListener('message', jsListener);
      return () => web.window.removeEventListener('message', jsListener);
    }, const []);

    _registerFactory();
    return HtmlElementView(
      key: ValueKey(url),
      viewType: _viewType,
      creationParams: {'src': url, 'title': title},
      onPlatformViewCreated: (id) => iframe.value = _createdFrames.remove(id),
    );
  }
}
