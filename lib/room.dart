import 'server_protocol.dart';
import 'match_state.dart';

/// Representa una sala de juego
class Room {
  static const maxSeats = 4;
  static const maxPlayerNameLength = 18;

  final String roomId;
  final int createdAt;

  List<MultiplayerSeat> _seats = [];
  String _phase = 'lobby';
  MatchState? _match;

  // Map de playerId -> clientConnectionId para saber a quién enviar mensajes
  final Map<String, String> _playerToConnection = {};

  Room({
    required this.roomId,
    required this.createdAt,
  });

  String get phase => _phase;
  List<MultiplayerSeat> get seats => List.unmodifiable(_seats);
  MatchState? get match => _match;

  /// Obtener un asiento disponible
  int getAvailableSeat() {
    for (int i = 0; i < maxSeats; i++) {
      if (!_seats.any((s) => s.seatIndex == i)) {
        return i;
      }
    }
    return -1; // Sin asientos disponibles
  }

  /// Agregar un jugador a la sala
  MultiplayerSeat addPlayer({
    required String playerId,
    required String name,
    required String connectionId,
    String? characterId,
  }) {
    if (_seats.length >= maxSeats) {
      throw StateError('Room is full');
    }
    if (containsPlayer(playerId)) {
      throw StateError('Player already in room');
    }

    final seatIndex = getAvailableSeat();
    if (seatIndex < 0) {
      throw StateError('No available seats');
    }

    final assignedCharacterId = _resolveCharacterId(
      preferredCharacterId: characterId,
    );

    final cleanName = sanitizePlayerName(name);
    if (cleanName == null) {
      throw StateError('Invalid player name');
    }

    final seat = MultiplayerSeat(
      playerId: playerId,
      name: cleanName,
      seatIndex: seatIndex,
      teamId: seatIndex.isEven ? 1 : 2,
      ready: false,
      connected: true,
      characterId: assignedCharacterId,
    );

    _seats.add(seat);
    _playerToConnection[playerId] = connectionId;
    _seats.sort((a, b) => a.seatIndex.compareTo(b.seatIndex));

    return seat;
  }

  /// Eliminar un jugador de la sala
  void removePlayer(String playerId) {
    _seats.removeWhere((s) => s.playerId == playerId);
    _playerToConnection.remove(playerId);
  }

  /// Marcar un jugador como listo/no listo
  void setPlayerReady(String playerId, bool ready) {
    final index = _seats.indexWhere((s) => s.playerId == playerId);
    if (index < 0) {
      throw StateError('Player not found in room');
    }

    final seat = _seats[index];
    _seats[index] = seat.copyWith(ready: ready);
  }

  void setPlayerCharacter(String playerId, String characterId) {
    if (!defaultCharacterIds.contains(characterId)) {
      throw StateError('Invalid character');
    }

    final index = _seats.indexWhere((seat) => seat.playerId == playerId);
    if (index < 0) {
      throw StateError('Player not found in room');
    }

    final takenByOther = _seats.any(
      (seat) => seat.playerId != playerId && seat.characterId == characterId,
    );
    if (takenByOther) {
      throw StateError('Character already taken');
    }

    _seats[index] = _seats[index].copyWith(characterId: characterId);
  }

  /// Verificar si todos los jugadores (al menos 2) están listos
  bool areAllReady() {
    if (_seats.length < 2) return false;
    return _seats.every((s) => s.ready);
  }

  /// Cambiar la fase
  void setPhase(String newPhase) {
    _phase = newPhase;
  }

  void startMatch(MatchState match) {
    _match = match;
  }

  void clearMatch() {
    _match = null;
    _phase = 'lobby';
  }

  /// Obtener el connectionId de un jugador
  String? getConnectionId(String playerId) {
    return _playerToConnection[playerId];
  }

  /// Obtener todos los connectionIds (para broadcast)
  List<String> getAllConnectionIds() {
    return _playerToConnection.values.toList();
  }

  /// Crear snapshot de la sala
  MultiplayerRoomSnapshot toSnapshot() {
    return MultiplayerRoomSnapshot(
      roomId: roomId,
      seats: List.from(_seats),
      phase: _phase,
      createdAt: createdAt,
    );
  }

  /// La sala está vacía
  bool isEmpty() => _seats.isEmpty;

  /// Validar que un jugador pertenece a la sala
  bool containsPlayer(String playerId) {
    return _seats.any((s) => s.playerId == playerId);
  }

  String _resolveCharacterId({String? preferredCharacterId}) {
    if (preferredCharacterId != null &&
        defaultCharacterIds.contains(preferredCharacterId)) {
      final takenByOther = _seats.any(
        (seat) => seat.characterId == preferredCharacterId,
      );
      if (takenByOther) {
        throw StateError('Character already taken');
      }
      return preferredCharacterId;
    }

    for (final candidate in defaultCharacterIds) {
      final taken = _seats.any((seat) => seat.characterId == candidate);
      if (!taken) {
        return candidate;
      }
    }

    throw StateError('No available characters');
  }

  static String? sanitizePlayerName(Object? rawName) {
    if (rawName is! String) return null;
    final normalized = rawName.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (normalized.isEmpty) return null;
    if (normalized.length <= maxPlayerNameLength) return normalized;
    return normalized.substring(0, maxPlayerNameLength).trimRight();
  }
}
