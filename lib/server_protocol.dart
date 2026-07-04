import 'dart:convert';

const defaultCharacterIds = ['p1', 'p2', 'p3', 'p4'];

/// Tipos de mensajes en el protocolo multijugador de Zapiti
enum MultiplayerMessageType {
  createRoom('create_room'),
  joinRoom('join_room'),
  leaveRoom('leave_room'),
  roomSnapshot('room_snapshot'),
  playerReady('player_ready'),
  selectCharacter('select_character'),
  requestSignal('request_signal'),
  startGame('start_game'),
  newHand('new_hand'),
  restartGame('restart_game'),
  playCard('play_card'),
  callTruco('call_truco'),
  acceptTruco('accept_truco'),
  passTruco('pass_truco'),
  raiseTruco('raise_truco'),
  continueRound('continue_round'),
  signal('signal'),
  error('error');

  final String value;
  const MultiplayerMessageType(this.value);

  static MultiplayerMessageType? fromString(String value) {
    try {
      return MultiplayerMessageType.values.firstWhere((e) => e.value == value);
    } catch (_) {
      return null;
    }
  }
}

/// Mensaje base para la comunicación WebSocket
class MultiplayerMessage {
  final MultiplayerMessageType type;
  final String? roomId;
  final String? playerId;
  final Map<String, dynamic>? payload;

  MultiplayerMessage({
    required this.type,
    this.roomId,
    this.playerId,
    this.payload,
  });

  /// Serializar a JSON
  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{
      'type': type.value,
    };

    if (roomId != null) json['roomId'] = roomId;
    if (playerId != null) json['playerId'] = playerId;
    if (payload != null) json['payload'] = payload;

    return json;
  }

  /// Decodificar desde JSON
  factory MultiplayerMessage.fromJson(Map<String, dynamic> json) {
    final typeStr = json['type'] as String?;
    if (typeStr == null) {
      throw FormatException('Missing required field: type');
    }

    final messageType = MultiplayerMessageType.fromString(typeStr);
    if (messageType == null) {
      throw FormatException('Unknown message type: $typeStr');
    }

    return MultiplayerMessage(
      type: messageType,
      roomId: json['roomId'] as String?,
      playerId: json['playerId'] as String?,
      payload: json['payload'] as Map<String, dynamic>?,
    );
  }

  /// Codificar a string JSON
  String encode() => stringify(toJson());

  /// Decodificar desde string JSON
  factory MultiplayerMessage.decode(String source) {
    try {
      final json = parse(source) as Map<String, dynamic>?;
      if (json == null) {
        throw FormatException('Invalid JSON');
      }
      return MultiplayerMessage.fromJson(json);
    } catch (e) {
      throw FormatException('Failed to decode message: $e');
    }
  }

  @override
  String toString() => encode();
}

/// Representa un jugador en una sala
class MultiplayerSeat {
  final String playerId;
  final String name;
  final int seatIndex;
  final int teamId;
  final bool ready;
  final bool connected;
  final String? characterId;

  MultiplayerSeat({
    required this.playerId,
    required this.name,
    required this.seatIndex,
    required this.teamId,
    this.ready = false,
    this.connected = true,
    this.characterId,
  });

  /// Copiar con cambios
  MultiplayerSeat copyWith({
    String? playerId,
    String? name,
    int? seatIndex,
    int? teamId,
    bool? ready,
    bool? connected,
    String? characterId,
  }) {
    return MultiplayerSeat(
      playerId: playerId ?? this.playerId,
      name: name ?? this.name,
      seatIndex: seatIndex ?? this.seatIndex,
      teamId: teamId ?? this.teamId,
      ready: ready ?? this.ready,
      connected: connected ?? this.connected,
      characterId: characterId ?? this.characterId,
    );
  }

  /// Serializar a JSON
  Map<String, dynamic> toJson() => {
        'playerId': playerId,
        'name': name,
        'seatIndex': seatIndex,
        'teamId': teamId,
        'ready': ready,
        'connected': connected,
        if (characterId != null) 'characterId': characterId,
      };

  /// Decodificar desde JSON
  factory MultiplayerSeat.fromJson(Map<String, dynamic> json) {
    final seatIndex = json['seatIndex'] as int;
    return MultiplayerSeat(
      playerId: json['playerId'] as String,
      name: json['name'] as String,
      seatIndex: seatIndex,
      teamId: json['teamId'] as int? ?? (seatIndex.isEven ? 1 : 2),
      ready: json['ready'] as bool? ?? false,
      connected: json['connected'] as bool? ?? true,
      characterId: json['characterId'] as String?,
    );
  }
}

/// Snapshot (estado) de una sala
class MultiplayerRoomSnapshot {
  final String roomId;
  final List<MultiplayerSeat> seats;
  final String phase;
  final int createdAt;

  MultiplayerRoomSnapshot({
    required this.roomId,
    required this.seats,
    required this.phase,
    required this.createdAt,
  });

  /// Copiar con cambios
  MultiplayerRoomSnapshot copyWith({
    String? roomId,
    List<MultiplayerSeat>? seats,
    String? phase,
    int? createdAt,
  }) {
    return MultiplayerRoomSnapshot(
      roomId: roomId ?? this.roomId,
      seats: seats ?? this.seats,
      phase: phase ?? this.phase,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  /// Serializar a JSON
  Map<String, dynamic> toJson() => {
        'roomId': roomId,
        'seats': seats.map((s) => s.toJson()).toList(),
        'phase': phase,
        'createdAt': createdAt,
      };

  /// Decodificar desde JSON
  factory MultiplayerRoomSnapshot.fromJson(Map<String, dynamic> json) {
    final seatsJson = json['seats'] as List?;
    final seats = seatsJson != null
        ? (seatsJson
            .cast<Map<String, dynamic>>()
            .map(MultiplayerSeat.fromJson)
            .toList())
        : <MultiplayerSeat>[];

    return MultiplayerRoomSnapshot(
      roomId: json['roomId'] as String,
      seats: seats,
      phase: json['phase'] as String,
      createdAt: json['createdAt'] as int,
    );
  }
}

/// Helper para parsear JSON
dynamic parse(String source) {
  // Implementación simple de JSON parsing
  // En un proyecto real, usarías dart:convert
  try {
    return jsonDecode(source);
  } catch (e) {
    throw FormatException('Invalid JSON: $e');
  }
}

/// Helper para stringificar a JSON
String stringify(dynamic obj) {
  // Implementación simple de JSON stringification
  try {
    return jsonEncode(obj);
  } catch (e) {
    throw FormatException('Failed to stringify: $e');
  }
}
