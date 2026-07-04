import 'dart:async';
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
            print('Error parsing message: $e');
            sendError('invalid_json', 'Invalid JSON: $e');
          }
        }
      },
      onDone: () {
        print('Client disconnected: $connectionId');
        onDisconnect(connectionId);
      },
      onError: (error) {
        print('WebSocket error: $error');
        onDisconnect(connectionId);
      },
    );
  }

  /// Enviar un mensaje al cliente
  void send(MultiplayerMessage message) {
    try {
      webSocket.sink.add(message.encode());
    } catch (e) {
      print('Error sending message: $e');
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
  void sendError(String code, String message, {String? roomId, String? playerId}) {
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
}
