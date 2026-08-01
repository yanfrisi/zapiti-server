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
    FutureOr<void> Function(String connectionId, MultiplayerMessage message)
    onMessage,
    FutureOr<void> Function(String connectionId) onDisconnect,
  ) {
    _subscription = webSocket.stream.listen(
      (dynamic message) async {
        if (message is String) {
          late final MultiplayerMessage parsedMessage;
          try {
            parsedMessage = MultiplayerMessage.decode(message);
          } catch (e) {
            _log('message_parse_error', {'error': e.toString()});
            sendError('invalid_json', 'Invalid JSON: $e');
            return;
          }

          try {
            await onMessage(connectionId, parsedMessage);
          } catch (e) {
            _log('message_handler_error', {'error': e.toString()});
            sendError('internal_error', 'Internal server error: $e');
          }
        }
      },
      onDone: () async {
        _log('websocket_done', const {});
        try {
          await onDisconnect(connectionId);
        } catch (e) {
          _log('disconnect_handler_error', {'error': e.toString()});
        }
      },
      onError: (error) async {
        _log('websocket_error', {'error': error.toString()});
        try {
          await onDisconnect(connectionId);
        } catch (e) {
          _log('disconnect_handler_error', {'error': e.toString()});
        }
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
      send(
        MultiplayerMessage(
          type: MultiplayerMessageType.roomSnapshot,
          roomId: roomId,
          playerId: playerId,
          payload: snapshot.toJson(),
        ),
      );
    }
  }

  /// Enviar error
  void sendError(
    String code,
    String message, {
    String? roomId,
    String? playerId,
  }) {
    _log('error_sent', {
      'code': code,
      'message': message,
      'roomId': roomId ?? _currentRoomId,
      'playerId': playerId ?? _playerId,
    });
    send(
      MultiplayerMessage(
        type: MultiplayerMessageType.error,
        roomId: roomId,
        playerId: playerId,
        payload: {'code': code, 'message': message},
      ),
    );
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
    print(
      '[zapiti] ${jsonEncode({'ts': DateTime.now().toIso8601String(), 'event': event, 'connectionId': connectionId, 'currentRoomId': _currentRoomId, 'playerId': _playerId, ...fields})}',
    );
  }
}
