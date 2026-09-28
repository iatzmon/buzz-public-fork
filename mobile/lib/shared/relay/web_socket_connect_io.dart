import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

WebSocketChannel connectWebSocket(Uri uri, {Duration? pingInterval}) =>
    IOWebSocketChannel.connect(uri, pingInterval: pingInterval);
