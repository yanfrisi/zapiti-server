import 'dart:math';
import 'room.dart';

/// Gestor central de salas
class RoomManager {
  final Map<String, Room> _rooms = {};
  final _random = Random();

  /// Crear una nueva sala
  Room createRoom(
    String playerName,
    String playerId,
    String connectionId, {
    String? username,
    String? pairId,
    String? teamName,
  }) {
    final roomId = _generateRoomCode();
    final createdAt = DateTime.now().millisecondsSinceEpoch;

    final room = Room(roomId: roomId, createdAt: createdAt);
    room.addPlayer(
      playerId: playerId,
      name: playerName,
      username: username,
      pairId: pairId,
      teamName: teamName,
      connectionId: connectionId,
    );

    _rooms[roomId] = room;

    return room;
  }

  /// Unirse a una sala existente
  Room? joinRoom(
    String roomId,
    String playerName,
    String playerId,
    String connectionId, {
    String? username,
    String? pairId,
    String? teamName,
  }) {
    final room = _rooms[roomId];
    if (room == null) return null;

    if (room.phase != 'lobby') {
      throw StateError('Room is in progress');
    }

    if (room.seats.length >= Room.maxSeats) {
      throw StateError('Room is full');
    }

    room.addPlayer(
      playerId: playerId,
      name: playerName,
      username: username,
      pairId: pairId,
      teamName: teamName,
      connectionId: connectionId,
    );

    return room;
  }

  /// Abandonar una sala
  void leaveRoom(String roomId, String playerId) {
    final room = _rooms[roomId];
    if (room != null) {
      room.removePlayer(playerId);

      // Eliminar sala vacía
      if (room.isEmpty()) {
        _rooms.remove(roomId);
      }
    }
  }

  /// Obtener una sala
  Room? getRoom(String roomId) {
    return _rooms[roomId];
  }

  /// Obtener todas las salas (para debugging)
  List<Room> getAllRooms() {
    return _rooms.values.toList();
  }

  /// Limpieza cuando un cliente se desconecta
  /// Retorna los roomIds que fueron afectados (con jugadores removidos o eliminados)
  List<String> handleDisconnection(String connectionId) {
    final affectedRooms = <String>{};
    final roomsToCheck = _rooms.keys.toList();

    for (final roomId in roomsToCheck) {
      final room = _rooms[roomId];
      if (room == null) continue;

      // Encontrar jugadores conectados a este connectionId
      final seatsToRemove = <String>[];
      for (final seat in room.seats) {
        if (room.getConnectionId(seat.playerId) == connectionId) {
          seatsToRemove.add(seat.playerId);
        }
      }

      // Remover los jugadores encontrados
      if (seatsToRemove.isNotEmpty) {
        for (final playerId in seatsToRemove) {
          room.removePlayer(playerId);
        }
        affectedRooms.add(roomId);

        // Eliminar sala vacía
        if (room.isEmpty()) {
          _rooms.remove(roomId);
        }
      }
    }

    return affectedRooms.toList();
  }

  /// Generar un código de sala corto y único
  String _generateRoomCode() {
    const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    final existing = _rooms.keys.toSet();

    String code;
    do {
      code = '';
      for (int i = 0; i < 4; i++) {
        code += chars[_random.nextInt(chars.length)];
      }
    } while (existing.contains(code));

    return code;
  }
}
