import 'package:web_socket_channel/web_socket_channel.dart';

/// Browsers answer server pings on their own and offer no client ping
/// setting, so [pingInterval] is ignored here.
WebSocketChannel connectWebSocket(Uri uri, {Duration? pingInterval}) =>
    WebSocketChannel.connect(uri);
