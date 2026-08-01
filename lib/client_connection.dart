import 'dart:async';
import 'dart:convert';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'server_protocol.dart';
import 'room_manager.dart';

/// Maneja la conexión de un cliente individual
class ClientConnection {
  final String connectionId;
  final WebSocketChannel webSocket;
  final RoomManager roomManager;

  String? _currentRoomId;
  String? _playerId;
  late StreamSubscription<dynamic> _subscription;

  ClientConnection({
    required this.connectionId,
    required this.webSocket,
    required this.roomManager,
  });

  /// Obtener el ID del jugador actual
  String? get playerId => _playerId;

  /// Obtener la sala actual
  String? get currentRoomId => _currentRoomId;

  /// Iniciar a escuchar mensajes
  void startListening(
    Function(String connectionId, MultiplayerMessage message) onMessage,
    Function(String connectionId) onDisconnect,
  ) {
    _subscription = webSocket.stream.listen(
      (dynamic message) {
        if (message is String) {
          try {
            final parsedMessage = MultiplayerMessage.decode(message);
            onMessage(connectionId, parsedMessage);
          } catch (e) {
            _log('message_parse_error', {'error': e.toString()});
            sendError('invalid_json', 'Invalid JSON: $e');
          }
        }
      },
      onDone: () {
        _log('websocket_done', const {});
        onDisconnect(connectionId);
      },
      onError: (error) {
        _log('websocket_error', {'error': error.toString()});
        onDisconnect(connectionId);
      },
    );
  }

  /// Enviar un mensaje al cliente
  void send(MultiplayerMessage message) {
    try {
      webSocket.sink.add(message.encode());
    } catch (e) {
      _log('message_send_error', {
        'type': message.type.value,
        'roomId': message.roomId,
        'playerId': message.playerId,
        'error': e.toString(),
      });
    }
  }

  /// Enviar un room snapshot
  void sendRoomSnapshot(String roomId, String playerId) {
    final room = roomManager.getRoom(roomId);
    if (room != null) {
      final snapshot = room.toSnapshot();
      send(MultiplayerMessage(
        type: MultiplayerMessageType.roomSnapshot,
        roomId: roomId,
        playerId: playerId,
        payload: snapshot.toJson(),
      ));
    }
  }

  /// Enviar error
  void sendError(String code, String message,
      {String? roomId, String? playerId}) {
    _log('error_sent', {
      'code': code,
      'message': message,
      'roomId': roomId ?? _currentRoomId,
      'playerId': playerId ?? _playerId,
    });
    send(MultiplayerMessage(
      type: MultiplayerMessageType.error,
      roomId: roomId,
      playerId: playerId,
      payload: {
        'code': code,
        'message': message,
      },
    ));
  }

  /// Actualizar la sala y jugador actual
  void setCurrentRoom(String roomId, String playerId) {
    _currentRoomId = roomId;
    _playerId = playerId;
  }

  /// Cerrar la conexión
  void close() {
    _subscription.cancel();
    webSocket.sink.close();
  }

  void _log(String event, Map<String, Object?> fields) {
    print('[zapiti] ${jsonEncode({
          'ts': DateTime.now().toIso8601String(),
          'event': event,
          'connectionId': connectionId,
          'currentRoomId': _currentRoomId,
          'playerId': _playerId,
          ...fields,
        })}');
  }
}
