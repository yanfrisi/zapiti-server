import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf/shelf_io.dart' as io;
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'client_connection.dart';
import 'match_state.dart';
import 'ranking_store.dart';
import 'room.dart';
import 'room_manager.dart';
import 'server_protocol.dart';

class ZapitiServer {
  late int port;
  late String host;
  final RoomManager roomManager = RoomManager();
  final RankingStore rankingStore;

  // Map de connectionId -> ClientConnection
  final Map<String, ClientConnection> _connections = {};
  final Set<String> _recordedMatchIds = {};

  int _connectionCounter = 0;

  ZapitiServer({
    String? customHost,
    int? customPort,
    RankingStore? customRankingStore,
  }) : rankingStore = customRankingStore ?? RankingStore() {
    // Leer puerto de variable de entorno o usar default
    port = customPort ??
        int.tryParse(Platform.environment['PORT'] ?? '8080') ??
        8080;
    host = customHost ?? '0.0.0.0';
  }

  /// Obtener un ID único para conexión
  String _getConnectionId() {
    return 'conn_${DateTime.now().millisecondsSinceEpoch}_${_connectionCounter++}';
  }

  String? _sanitizePlayerId(String? rawPlayerId) {
    if (rawPlayerId == null) return null;
    final trimmed = rawPlayerId.trim();
    if (trimmed.isEmpty || trimmed.length > 80) return null;
    if (!RegExp(r'^[A-Za-z0-9_\-]+$').hasMatch(trimmed)) return null;
    return trimmed;
  }

  String? _sanitizePin(String? rawPin) {
    if (rawPin == null) return null;
    final trimmed = rawPin.trim();
    if (!RegExp(r'^\d{4,8}$').hasMatch(trimmed)) return null;
    return trimmed;
  }

  String? _sanitizeSessionToken(String? rawToken) {
    if (rawToken == null) return null;
    final trimmed = rawToken.trim();
    if (trimmed.length < 24 || trimmed.length > 128) return null;
    if (!RegExp(r'^[A-Za-z0-9_\-=]+$').hasMatch(trimmed)) return null;
    return trimmed;
  }

  String _sanitizeTeamName(String? rawTeamName) {
    final normalized = rawTeamName?.trim().replaceAll(RegExp(r'\s+'), ' ') ?? '';
    if (normalized.length <= 22) return normalized;
    return normalized.substring(0, 22).trimRight();
  }

  /// Crear handler de WebSocket
  shelf.Handler _createWebSocketHandler() {
    return webSocketHandler(_handleWebSocketConnection);
  }

  void _handleWebSocketConnection(
      WebSocketChannel webSocket, String? protocol) {
    final connectionId = _getConnectionId();
    print('New client connected: $connectionId');

    final connection = ClientConnection(
      connectionId: connectionId,
      webSocket: webSocket,
      roomManager: roomManager,
    );

    _connections[connectionId] = connection;

    connection.startListening(
      (connId, message) => _handleMessage(connId, message),
      (connId) => _handleDisconnect(connId),
    );
  }

  /// Manejar mensaje de cliente
  void _handleMessage(String connectionId, MultiplayerMessage message) {
    final connection = _connections[connectionId];
    if (connection == null) return;

    try {
      switch (message.type) {
        case MultiplayerMessageType.createRoom:
          _handleCreateRoom(connection, message);
          break;
        case MultiplayerMessageType.joinRoom:
          _handleJoinRoom(connection, message);
          break;
        case MultiplayerMessageType.leaveRoom:
          _handleLeaveRoom(connection, message);
          break;
        case MultiplayerMessageType.playerReady:
          _handlePlayerReady(connection, message);
          break;
        case MultiplayerMessageType.requestSignal:
          _handleRequestSignal(connection, message);
          break;
        case MultiplayerMessageType.selectCharacter:
          _handleSelectCharacter(connection, message);
          break;
        case MultiplayerMessageType.updateProfile:
          _handleUpdateProfile(connection, message);
          break;
        case MultiplayerMessageType.recoverProfile:
          _handleRecoverProfile(connection, message);
          break;
        case MultiplayerMessageType.getRanking:
          _handleGetRanking(connection);
          break;
        case MultiplayerMessageType.newHand:
          _handleNewHand(connection, message);
          break;
        case MultiplayerMessageType.restartGame:
          _handleRestartGame(connection, message);
          break;
        case MultiplayerMessageType.chooseAlVerDecision:
          _handleGameMessage(connection, message);
          break;
        case MultiplayerMessageType.playCard:
        case MultiplayerMessageType.callTruco:
        case MultiplayerMessageType.acceptTruco:
        case MultiplayerMessageType.passTruco:
        case MultiplayerMessageType.raiseTruco:
        case MultiplayerMessageType.continueRound:
        case MultiplayerMessageType.signal:
          _handleGameMessage(connection, message);
          break;
        default:
          connection.sendError('unknown_message_type', 'Unknown message type');
      }
    } catch (e) {
      print('Error handling message: $e');
      connection.sendError('internal_error', 'Internal server error: $e');
    }
  }

  /// Crear sala
  void _handleCreateRoom(
      ClientConnection connection, MultiplayerMessage message) {
    final payload = message.payload;
    if (payload == null) {
      connection.sendError('invalid_payload', 'Missing payload');
      return;
    }

    final playerName = Room.sanitizePlayerName(payload['name']);
    if (playerName == null) {
      connection.sendError('invalid_payload', 'Missing player name');
      return;
    }

    final preferredCharacterId = payload['characterId'] as String?;
    final pin = _sanitizePin(payload['pin']?.toString());
    final sessionToken =
        _sanitizeSessionToken(payload['sessionToken']?.toString());
    final teamName = _sanitizeTeamName(payload['teamName']?.toString());

    final playerId = _sanitizePlayerId(message.playerId) ??
        'player_${DateTime.now().millisecondsSinceEpoch}_${_connections.length}';

    Room? room;
    try {
      if (!_syncProfileForRoom(
        connection,
        playerId: playerId,
        playerName: playerName,
        teamName: teamName,
        pin: pin,
        sessionToken: sessionToken,
      )) {
        return;
      }
      room =
          roomManager.createRoom(playerName, playerId, connection.connectionId);
      if (preferredCharacterId != null) {
        room.setPlayerCharacter(playerId, preferredCharacterId);
      }
      connection.setCurrentRoom(room.roomId, playerId);

      print('Room created: ${room.roomId} by $playerName');

      connection.sendRoomSnapshot(room.roomId, playerId);
    } catch (e) {
      if (room != null) {
        roomManager.leaveRoom(room.roomId, playerId);
      }
      if (e is StateError && e.message.contains('Character already taken')) {
        connection.sendError('character_taken', 'Character already taken');
      } else if (e is StateError && e.message.contains('Invalid character')) {
        connection.sendError('invalid_payload', 'Invalid character');
      } else {
        connection.sendError('internal_error', 'Failed to create room: $e');
      }
    }
  }

  /// Unirse a sala
  void _handleJoinRoom(
      ClientConnection connection, MultiplayerMessage message) {
    final roomId = message.roomId;
    final payload = message.payload;

    if (roomId == null || roomId.isEmpty) {
      connection.sendError('invalid_payload', 'Missing roomId');
      return;
    }

    if (payload == null) {
      connection.sendError('invalid_payload', 'Missing payload');
      return;
    }

    final playerName = Room.sanitizePlayerName(payload['name']);
    if (playerName == null) {
      connection.sendError('invalid_payload', 'Missing player name');
      return;
    }

    final preferredCharacterId = payload['characterId'] as String?;
    final pin = _sanitizePin(payload['pin']?.toString());
    final sessionToken =
        _sanitizeSessionToken(payload['sessionToken']?.toString());
    final teamName = _sanitizeTeamName(payload['teamName']?.toString());
    final requestedPlayerId = _sanitizePlayerId(message.playerId) ??
        'player_${DateTime.now().millisecondsSinceEpoch}_${_connections.length}';

    Room? room;
    try {
      if (!_syncProfileForRoom(
        connection,
        playerId: requestedPlayerId,
        playerName: playerName,
        teamName: teamName,
        pin: pin,
        sessionToken: sessionToken,
      )) {
        return;
      }
      room = roomManager.joinRoom(
        roomId,
        playerName,
        requestedPlayerId,
        connection.connectionId,
      );

      if (room == null) {
        connection.sendError('room_not_found', 'Room not found');
        return;
      }

      final playerId = room.seats.last.playerId;
      if (preferredCharacterId != null) {
        room.setPlayerCharacter(playerId, preferredCharacterId);
      }
      connection.setCurrentRoom(roomId, playerId);

      print('Player $playerName joined room $roomId');

      // Enviar snapshot a todos en la sala
      _broadcastRoomSnapshot(roomId);
    } catch (e) {
      if (room != null) {
        roomManager.leaveRoom(roomId, requestedPlayerId);
      }
      if (e is StateError && e.message.contains('full')) {
        connection.sendError('room_full', 'Room is full');
      } else if (e is StateError && e.message.contains('progress')) {
        connection.sendError('room_in_progress', 'Match already in progress');
      } else if (e is StateError &&
          e.message.contains('Character already taken')) {
        connection.sendError('character_taken', 'Character already taken');
      } else if (e is StateError && e.message.contains('Invalid character')) {
        connection.sendError('invalid_payload', 'Invalid character');
      } else {
        connection.sendError('internal_error', 'Failed to join room: $e');
      }
    }
  }

  void _handleGetRanking(ClientConnection connection) {
    connection.send(MultiplayerMessage(
      type: MultiplayerMessageType.ranking,
      payload: rankingStore.snapshot(),
    ));
  }

  void _handleUpdateProfile(
    ClientConnection connection,
    MultiplayerMessage message,
  ) {
    final payload = message.payload;
    final playerId = _sanitizePlayerId(message.playerId);
    if (payload == null || playerId == null) {
      connection.sendError('invalid_payload', 'Missing profile payload');
      return;
    }

    final name = Room.sanitizePlayerName(payload['name']);
    final pin = _sanitizePin(payload['pin']?.toString());
    final sessionToken =
        _sanitizeSessionToken(payload['sessionToken']?.toString());
    final teamName = _sanitizeTeamName(payload['teamName']?.toString());
    if (name == null) {
      connection.sendError('invalid_payload', 'Invalid profile name');
      return;
    }

    final profile = pin != null
        ? rankingStore.upsertPlayerProfile(
            playerId: playerId,
            name: name,
            pin: pin,
            teamName: teamName,
          )
        : sessionToken == null
            ? null
            : rankingStore.updatePlayerProfileWithSession(
                playerId: playerId,
                name: name,
                teamName: teamName,
                sessionToken: sessionToken,
              );
    if (profile == null) {
      connection.sendError('auth_failed', 'Invalid profile session');
      return;
    }
    connection.send(MultiplayerMessage(
      type: MultiplayerMessageType.profile,
      playerId: playerId,
      payload: profile,
    ));
  }

  bool _syncProfileForRoom(
    ClientConnection connection, {
    required String playerId,
    required String playerName,
    required String teamName,
    required String? pin,
    required String? sessionToken,
  }) {
    if (sessionToken != null) {
      final profile = rankingStore.updatePlayerProfileWithSession(
        playerId: playerId,
        name: playerName,
        teamName: teamName,
        sessionToken: sessionToken,
      );
      if (profile == null) {
        connection.sendError('auth_failed', 'Invalid profile session');
        return false;
      }
      return true;
    }

    if (pin != null) {
      rankingStore.upsertPlayerProfile(
        playerId: playerId,
        name: playerName,
        pin: pin,
        teamName: teamName,
      );
    }
    return true;
  }

  void _handleRecoverProfile(
    ClientConnection connection,
    MultiplayerMessage message,
  ) {
    final payload = message.payload;
    final pin = _sanitizePin(payload?['pin']?.toString());
    if (pin == null) {
      connection.sendError('invalid_payload', 'Invalid recovery pin');
      return;
    }

    final profile = rankingStore.recoverPlayerProfile(pin: pin);
    if (profile == null) {
      connection.sendError('profile_not_found', 'Profile not found');
      return;
    }

    connection.send(MultiplayerMessage(
      type: MultiplayerMessageType.profile,
      playerId: profile['playerId']?.toString(),
      payload: profile,
    ));
  }

  /// Abandonar sala
  void _handleLeaveRoom(
      ClientConnection connection, MultiplayerMessage message) {
    final roomId = message.roomId;
    final playerId = message.playerId;

    if (roomId == null || playerId == null) {
      connection.sendError('invalid_payload', 'Missing roomId or playerId');
      return;
    }

    final room = roomManager.getRoom(roomId);
    if (room == null) {
      connection.sendError('room_not_found', 'Room not found');
      return;
    }

    if (!room.containsPlayer(playerId)) {
      connection.sendError('player_not_found', 'Player not in room');
      return;
    }

    print('Player $playerId left room $roomId');

    roomManager.leaveRoom(roomId, playerId);
    final updatedRoom = roomManager.getRoom(roomId);
    if (updatedRoom != null) {
      updatedRoom.clearMatch();
      updatedRoom.setPhase('lobby');
    }

    // Enviar snapshot a los que quedan
    _broadcastRoomSnapshot(roomId);
  }

  /// Marcar jugador como listo
  void _handlePlayerReady(
      ClientConnection connection, MultiplayerMessage message) {
    final roomId = message.roomId;
    final playerId = message.playerId;
    final payload = message.payload;

    if (roomId == null || playerId == null) {
      connection.sendError('invalid_payload', 'Missing roomId or playerId');
      return;
    }

    if (payload == null) {
      connection.sendError('invalid_payload', 'Missing payload');
      return;
    }

    final room = roomManager.getRoom(roomId);
    if (room == null) {
      connection.sendError('room_not_found', 'Room not found');
      return;
    }

    if (!room.containsPlayer(playerId)) {
      connection.sendError('player_not_found', 'Player not in room');
      return;
    }

    final ready = payload['ready'] as bool?;
    if (ready == null) {
      connection.sendError('invalid_payload', 'Missing ready status');
      return;
    }

    room.setPlayerReady(playerId, ready);
    print('Player $playerId ready: $ready');

    // Enviar snapshot
    _broadcastRoomSnapshot(roomId);

    // Si todos están listos y hay al menos 2 jugadores, iniciar juego
    if (room.match == null && room.areAllReady() && room.seats.length >= 2) {
      _startMatch(room);
    }
  }

  void _handleSelectCharacter(
    ClientConnection connection,
    MultiplayerMessage message,
  ) {
    final roomId = message.roomId;
    final playerId = message.playerId;
    final payload = message.payload;

    if (roomId == null || playerId == null) {
      connection.sendError('invalid_payload', 'Missing roomId or playerId');
      return;
    }

    if (payload == null) {
      connection.sendError('invalid_payload', 'Missing payload');
      return;
    }

    final characterId = payload['characterId'] as String?;
    if (characterId == null || characterId.isEmpty) {
      connection.sendError('invalid_payload', 'Missing characterId');
      return;
    }

    final room = roomManager.getRoom(roomId);
    if (room == null) {
      connection.sendError('room_not_found', 'Room not found');
      return;
    }

    if (room.phase != 'lobby') {
      connection.sendError('room_in_progress', 'Character selection is locked');
      return;
    }

    if (!room.containsPlayer(playerId)) {
      connection.sendError('player_not_found', 'Player not in room');
      return;
    }

    try {
      room.setPlayerCharacter(playerId, characterId);
    } catch (e) {
      final errorText = e is StateError ? e.message : e.toString();
      if (errorText.contains('taken')) {
        connection.sendError('character_taken', 'Character already taken');
      } else {
        connection.sendError('invalid_payload', 'Invalid character');
      }
      return;
    }

    _broadcastRoomSnapshot(roomId);
  }

  void _handleRequestSignal(
    ClientConnection connection,
    MultiplayerMessage message,
  ) {
    final roomId = message.roomId;
    final playerId = message.playerId;
    if (roomId == null || playerId == null) {
      connection.sendError('invalid_payload', 'Missing roomId or playerId');
      return;
    }

    final room = roomManager.getRoom(roomId);
    if (room == null) {
      connection.sendError('room_not_found', 'Room not found');
      return;
    }

    final match = room.match;
    if (match == null) {
      connection.sendError('match_not_started', 'Match not started yet');
      return;
    }

    final requester = match.playerById(playerId);
    for (final teammate in match.players.where(
      (player) =>
          player.teamId == requester.teamId &&
          player.playerId != requester.playerId &&
          player.connectionId != null,
    )) {
      final teammateConn = _connections[teammate.connectionId!];
      if (teammateConn == null) continue;
      teammateConn.send(
        MultiplayerMessage(
          type: MultiplayerMessageType.requestSignal,
          roomId: roomId,
          playerId: requester.playerId,
          payload: {'requesterName': requester.name},
        ),
      );
    }
  }

  void _handleNewHand(ClientConnection connection, MultiplayerMessage message) {
    final roomId = message.roomId;
    final playerId = message.playerId;
    if (roomId == null || playerId == null) {
      connection.sendError('invalid_payload', 'Missing roomId or playerId');
      return;
    }

    final room = roomManager.getRoom(roomId);
    if (room == null) {
      connection.sendError('room_not_found', 'Room not found');
      return;
    }

    final match = room.match;
    if (match == null) {
      connection.sendError('match_not_started', 'Match not started yet');
      return;
    }

    if (!match.handFinished) {
      connection.sendError('hand_not_finished', 'Hand not finished yet');
      return;
    }

    final seatConnection = room.getConnectionId(playerId);
    if (seatConnection != connection.connectionId) {
      connection.sendError('forbidden', 'Player does not own this seat');
      return;
    }

    match.startNewHand();
    room.setPhase('playing');
    _broadcastToRoom(
      roomId,
      MultiplayerMessage(
        type: MultiplayerMessageType.newHand,
        roomId: roomId,
        playerId: playerId,
      ),
    );
    _broadcastRoomSnapshot(roomId);
    _advanceMatchIfNeeded(room);
    _broadcastRoomSnapshot(roomId);
  }

  void _handleRestartGame(
    ClientConnection connection,
    MultiplayerMessage message,
  ) {
    final roomId = message.roomId;
    final playerId = message.playerId;
    if (roomId == null || playerId == null) {
      connection.sendError('invalid_payload', 'Missing roomId or playerId');
      return;
    }

    final room = roomManager.getRoom(roomId);
    if (room == null) {
      connection.sendError('room_not_found', 'Room not found');
      return;
    }

    final match = room.match;
    if (match == null) {
      connection.sendError('match_not_started', 'Match not started yet');
      return;
    }

    if (!match.isGameFinished) {
      connection.sendError('game_not_finished', 'Game not finished yet');
      return;
    }

    final seatConnection = room.getConnectionId(playerId);
    if (seatConnection != connection.connectionId) {
      connection.sendError('forbidden', 'Player does not own this seat');
      return;
    }

    match.restartGame();
    room.setPhase('playing');
    _broadcastToRoom(
      roomId,
      MultiplayerMessage(
        type: MultiplayerMessageType.restartGame,
        roomId: roomId,
        playerId: playerId,
      ),
    );
    _broadcastRoomSnapshot(roomId);
    _advanceMatchIfNeeded(room);
    _broadcastRoomSnapshot(roomId);
  }

  /// Manejar mensajes de juego de forma autoritativa
  void _handleGameMessage(
      ClientConnection connection, MultiplayerMessage message) {
    final roomId = message.roomId;
    final playerId = message.playerId;

    if (roomId == null || playerId == null) {
      connection.sendError('invalid_payload', 'Missing roomId or playerId');
      return;
    }

    final room = roomManager.getRoom(roomId);
    if (room == null) {
      connection.sendError('room_not_found', 'Room not found');
      return;
    }

    if (!room.containsPlayer(playerId)) {
      connection.sendError('player_not_found', 'Player not in room');
      return;
    }

    final match = room.match;
    if (match == null) {
      connection.sendError('match_not_started', 'Match not started yet');
      return;
    }

    final seatConnection = room.getConnectionId(playerId);
    if (seatConnection != connection.connectionId) {
      connection.sendError('forbidden', 'Player does not own this seat');
      return;
    }

    print('Game message received: ${message.type.value} from $playerId');

    switch (message.type) {
      case MultiplayerMessageType.playCard:
        _handlePlayCard(connection, room, match, message);
        break;
      case MultiplayerMessageType.chooseAlVerDecision:
        _handleChooseAlVerDecision(connection, room, match, message);
        break;
      case MultiplayerMessageType.callTruco:
        _handleCallTruco(connection, room, match, message);
        break;
      case MultiplayerMessageType.acceptTruco:
        _handleAcceptTruco(connection, room, match, message);
        break;
      case MultiplayerMessageType.passTruco:
        _handlePassTruco(connection, room, match, message);
        break;
      case MultiplayerMessageType.raiseTruco:
        _handleRaiseTruco(connection, room, match, message);
        break;
      case MultiplayerMessageType.continueRound:
        _handleContinueRound(connection, room, match, message);
        break;
      case MultiplayerMessageType.signal:
        _broadcastToRoom(roomId, message,
            excludeConnection: connection.connectionId);
        break;
      default:
        connection.sendError('unknown_message_type', 'Unknown game message');
    }

    _broadcastRoomSnapshot(roomId);
    _advanceMatchIfNeeded(room, excludeConnection: connection.connectionId);
    _recordMatchIfFinished(room);
    _broadcastRoomSnapshot(roomId);
  }

  void _startMatch(Room room) {
    room.setPhase('starting');
    final match = MatchState.start(
      roomId: room.roomId,
      createdAt: room.createdAt,
      seed: DateTime.now().millisecondsSinceEpoch,
      players: _buildPlayersForRoom(room),
    );
    room.startMatch(match);

    _broadcastRoomSnapshot(room.roomId);
    _broadcastStartGame(room.roomId);

    room.setPhase('playing');
    _broadcastRoomSnapshot(room.roomId);
    _advanceMatchIfNeeded(room);
    _recordMatchIfFinished(room);
    _broadcastRoomSnapshot(room.roomId);
  }

  List<MatchPlayer> _buildPlayersForRoom(Room room) {
    final seats = [...room.seats]
      ..sort((a, b) => a.seatIndex.compareTo(b.seatIndex));

    if (seats.length == 2) {
      final firstHuman = seats[0];
      final secondHuman = seats[1];
      return [
        _humanMatchPlayer(room, firstHuman, teamId: 1),
        _botMatchPlayer(room, 1, teamId: 2),
        _humanMatchPlayer(room, secondHuman, teamId: 1),
        _botMatchPlayer(room, 3, teamId: 2),
      ];
    }

    final seatsByIndex = {for (final seat in room.seats) seat.seatIndex: seat};
    return [
      for (var seatIndex = 0; seatIndex < Room.maxSeats; seatIndex++)
        if (seatsByIndex[seatIndex] != null)
          _humanMatchPlayer(
            room,
            seatsByIndex[seatIndex]!,
            teamId: seatIndex.isEven ? 1 : 2,
          )
        else
          _botMatchPlayer(
            room,
            seatIndex,
            teamId: seatIndex.isEven ? 1 : 2,
          ),
    ];
  }

  MatchPlayer _humanMatchPlayer(
    Room room,
    MultiplayerSeat seat, {
    required int teamId,
  }) {
    return MatchPlayer(
      playerId: seat.playerId,
      name: seat.name,
      teamId: teamId,
      connectionId: room.getConnectionId(seat.playerId),
      characterId: seat.characterId ??
          defaultCharacterIds[seat.seatIndex % defaultCharacterIds.length],
    );
  }

  MatchPlayer _botMatchPlayer(
    Room room,
    int seatIndex, {
    required int teamId,
  }) {
    return MatchPlayer(
      playerId: 'bot_${room.roomId}_$seatIndex',
      name: 'Bot ${seatIndex + 1}',
      teamId: teamId,
      characterId: defaultCharacterIds[seatIndex % defaultCharacterIds.length],
      aiDifficulty: _botDifficultyForSeat(seatIndex),
    );
  }

  int _botDifficultyForSeat(int seatIndex) {
    const difficultiesBySeat = [2, 3, 4, 5];
    return difficultiesBySeat[seatIndex.clamp(0, difficultiesBySeat.length - 1)];
  }

  void _handlePlayCard(
    ClientConnection connection,
    Room room,
    MatchState match,
    MultiplayerMessage message,
  ) {
    final playerId = message.playerId;
    final payload = message.payload;
    if (payload == null) {
      connection.sendError('invalid_payload', 'Missing payload');
      return;
    }

    final cardJson = payload['card'];
    if (cardJson is! Map<String, dynamic>) {
      connection.sendError('invalid_payload', 'Missing card');
      return;
    }

    final card = SpanishCard.fromJson(cardJson);
    try {
      match.playCard(playerId!, card);
    } catch (e) {
      connection.sendError('invalid_move', 'Cannot play card: $e');
      return;
    }

    _broadcastToRoom(
      room.roomId,
      MultiplayerMessage(
        type: MultiplayerMessageType.playCard,
        roomId: room.roomId,
        playerId: playerId,
        payload: {'card': card.toJson()},
      ),
      excludeConnection: connection.connectionId,
    );
  }

  void _handleCallTruco(
    ClientConnection connection,
    Room room,
    MatchState match,
    MultiplayerMessage message,
  ) {
    final playerId = message.playerId;
    final value = message.payload?['value'];
    if (value is! int) {
      connection.sendError('invalid_payload', 'Missing truco value');
      return;
    }
    try {
      match.callTruco(playerId!, value: value);
    } catch (e) {
      connection.sendError('invalid_move', 'Cannot call truco: $e');
      return;
    }

    _broadcastToRoom(
      room.roomId,
      MultiplayerMessage(
        type: MultiplayerMessageType.callTruco,
        roomId: room.roomId,
        playerId: playerId,
        payload: {'value': value},
      ),
      excludeConnection: connection.connectionId,
    );
  }

  void _handleAcceptTruco(
    ClientConnection connection,
    Room room,
    MatchState match,
    MultiplayerMessage message,
  ) {
    final playerId = message.playerId;
    final player = match.playerById(playerId!);
    try {
      match.acceptTruco(teamId: player.teamId);
    } catch (e) {
      connection.sendError('invalid_move', 'Cannot accept truco: $e');
      return;
    }

    _broadcastToRoom(
      room.roomId,
      MultiplayerMessage(
        type: MultiplayerMessageType.acceptTruco,
        roomId: room.roomId,
        playerId: playerId,
      ),
      excludeConnection: connection.connectionId,
    );
  }

  void _handlePassTruco(
    ClientConnection connection,
    Room room,
    MatchState match,
    MultiplayerMessage message,
  ) {
    final playerId = message.playerId;
    final player = match.playerById(playerId!);
    try {
      match.passTruco(passingTeamId: player.teamId);
    } catch (e) {
      connection.sendError('invalid_move', 'Cannot pass truco: $e');
      return;
    }

    _broadcastToRoom(
      room.roomId,
      MultiplayerMessage(
        type: MultiplayerMessageType.passTruco,
        roomId: room.roomId,
        playerId: playerId,
      ),
      excludeConnection: connection.connectionId,
    );
  }

  void _handleRaiseTruco(
    ClientConnection connection,
    Room room,
    MatchState match,
    MultiplayerMessage message,
  ) {
    final playerId = message.playerId;
    final value = message.payload?['value'];
    if (value is! int) {
      connection.sendError('invalid_payload', 'Missing truco raise value');
      return;
    }
    try {
      match.raiseTruco(playerId!, value: value);
    } catch (e) {
      connection.sendError('invalid_move', 'Cannot raise truco: $e');
      return;
    }

    _broadcastToRoom(
      room.roomId,
      MultiplayerMessage(
        type: MultiplayerMessageType.raiseTruco,
        roomId: room.roomId,
        playerId: playerId,
        payload: {'value': value},
      ),
      excludeConnection: connection.connectionId,
    );
  }

  void _handleContinueRound(
    ClientConnection connection,
    Room room,
    MatchState match,
    MultiplayerMessage message,
  ) {
    try {
      match.continueRound();
    } catch (e) {
      connection.sendError('invalid_move', 'Cannot continue round: $e');
      return;
    }

    _broadcastToRoom(
      room.roomId,
      MultiplayerMessage(
        type: MultiplayerMessageType.continueRound,
        roomId: room.roomId,
        playerId: message.playerId,
      ),
      excludeConnection: connection.connectionId,
    );
  }

  void _handleChooseAlVerDecision(
    ClientConnection connection,
    Room room,
    MatchState match,
    MultiplayerMessage message,
  ) {
    final playerId = message.playerId;
    final play = message.payload?['play'];
    if (play is! bool) {
      connection.sendError('invalid_payload', 'Missing al ver decision');
      return;
    }

    final player = match.playerById(playerId!);
    try {
      match.chooseAlVerDecision(teamId: player.teamId, play: play);
    } catch (e) {
      connection.sendError('invalid_move', 'Cannot choose al ver: $e');
      return;
    }

    _broadcastToRoom(
      room.roomId,
      MultiplayerMessage(
        type: MultiplayerMessageType.chooseAlVerDecision,
        roomId: room.roomId,
        playerId: playerId,
        payload: {'play': play},
      ),
      excludeConnection: connection.connectionId,
    );
  }

  void _advanceMatchIfNeeded(Room room, {String? excludeConnection}) {
    final match = room.match;
    if (match == null) return;

    var guard = 0;
    while (!match.isGameFinished && guard < 32) {
      guard += 1;

      if (match.handFinished) {
        break;
      }

      if (match.alVerState == AlVerState.awaitingDecision) {
        final alVerTeamId = match.alVerTeamId;
        if (alVerTeamId != null && match.teamHasOnlyBots(alVerTeamId)) {
          final responder = match.botResponderForTeam(alVerTeamId);
          final play = match.shouldBotPlayAlVer(alVerTeamId);
          match.chooseAlVerDecision(teamId: alVerTeamId, play: play);
          _broadcastToRoom(
            room.roomId,
            MultiplayerMessage(
              type: MultiplayerMessageType.chooseAlVerDecision,
              roomId: room.roomId,
              playerId: responder.playerId,
              payload: {'play': play},
            ),
          );
          continue;
        }
        break;
      }

      if (match.hasPendingTruco) {
        final responseTeamId = match.trucoResponseTeamId;
        if (match.teamHasOnlyBots(responseTeamId)) {
          final decision = match.chooseBotTrucoDecision(responseTeamId);
          switch (decision.action) {
            case BotTrucoAction.accept:
              match.acceptTruco(teamId: responseTeamId);
              _broadcastToRoom(
                room.roomId,
                MultiplayerMessage(
                  type: MultiplayerMessageType.acceptTruco,
                  roomId: room.roomId,
                  playerId: decision.player.playerId,
                ),
              );
              break;
            case BotTrucoAction.pass:
              match.passTruco(passingTeamId: responseTeamId);
              _broadcastToRoom(
                room.roomId,
                MultiplayerMessage(
                  type: MultiplayerMessageType.passTruco,
                  roomId: room.roomId,
                  playerId: decision.player.playerId,
                ),
              );
              break;
            case BotTrucoAction.raise:
              final value = decision.value;
              if (value == null) break;
              match.raiseTruco(decision.player.playerId, value: value);
              _broadcastToRoom(
                room.roomId,
                MultiplayerMessage(
                  type: MultiplayerMessageType.raiseTruco,
                  roomId: room.roomId,
                  playerId: decision.player.playerId,
                  payload: {'value': value},
                ),
              );
              break;
          }
          continue;
        }
        break;
      }

      if (match.isRoundAwaitingContinue) {
        break;
      }

      if (!match.isBotTurn) {
        break;
      }

      final bot = match.currentPlayer;
      if (match.shouldBotCallTruco(bot)) {
        match.callTruco(
          bot.playerId,
          value: TrucoRules.firstTrucoValue,
        );
        _broadcastToRoom(
          room.roomId,
          MultiplayerMessage(
            type: MultiplayerMessageType.callTruco,
            roomId: room.roomId,
            playerId: bot.playerId,
            payload: {'value': TrucoRules.firstTrucoValue},
          ),
        );
        continue;
      }

      final card = match.chooseBotCard(bot);
      try {
        match.playCard(bot.playerId, card);
      } catch (e) {
        print('Bot move failed: $e');
        break;
      }

      _broadcastToRoom(
        room.roomId,
        MultiplayerMessage(
          type: MultiplayerMessageType.playCard,
          roomId: room.roomId,
          playerId: bot.playerId,
          payload: {'card': card.toJson()},
        ),
      );

      if (match.isRoundAwaitingContinue) {
        break;
      }
    }
  }

  void _recordMatchIfFinished(Room room) {
    final match = room.match;
    if (match == null || match.winningTeamId == null) return;

    final matchId = '${match.roomId}_${match.seed}';
    if (_recordedMatchIds.contains(matchId)) return;

    rankingStore.recordFinishedMatch(match);
    _recordedMatchIds.add(matchId);
  }

  /// Manejar desconexión
  void _handleDisconnect(String connectionId) {
    final affectedRooms = roomManager.handleDisconnection(connectionId);
    _connections.remove(connectionId);

    for (final roomId in affectedRooms) {
      final room = roomManager.getRoom(roomId);
      if (room != null) {
        room.clearMatch();
        room.setPhase('lobby');
        // Resetear estado listo para todos los jugadores que quedan
        for (final seat in room.seats) {
          room.setPlayerReady(seat.playerId, false);
        }
        _broadcastRoomSnapshot(roomId);
      }
    }
  }

  /// Enviar snapshot a todos en una sala
  void _broadcastRoomSnapshot(String roomId) {
    final room = roomManager.getRoom(roomId);
    if (room == null) return;

    final snapshot = room.toSnapshot();
    final payload = snapshot.toJson();
    final match = room.match;
    if (match != null) {
      payload['match'] = match.toPublicJson();
    }

    for (final seat in room.seats) {
      final connId = room.getConnectionId(seat.playerId);
      if (connId != null) {
        final connection = _connections[connId];
        if (connection != null) {
          connection.send(MultiplayerMessage(
            type: MultiplayerMessageType.roomSnapshot,
            roomId: roomId,
            playerId: seat.playerId,
            payload: payload,
          ));
        }
      }
    }
  }

  /// Iniciar juego
  void _broadcastStartGame(String roomId) {
    final room = roomManager.getRoom(roomId);
    if (room == null) return;
    if (room.match == null) return;

    final payload = _buildStartGamePayload(room);
    for (final seat in room.seats) {
      final connId = room.getConnectionId(seat.playerId);
      if (connId == null) continue;
      final connection = _connections[connId];
      if (connection == null) continue;
      final localPlayerIndex = room.match!.players.indexWhere(
        (player) => player.playerId == seat.playerId,
      );

      final localPayload = Map<String, dynamic>.from(payload)
        ..['players'] = _localPlayersForPlayer(room.match!, seat.playerId)
        ..['controlledPlayerIds'] = [seat.playerId]
        ..['localSeatIndex'] = localPlayerIndex < 0 ? 0 : localPlayerIndex;

      connection.send(MultiplayerMessage(
        type: MultiplayerMessageType.startGame,
        roomId: roomId,
        playerId: seat.playerId,
        payload: localPayload,
      ));
    }
  }

  Map<String, dynamic> _buildStartGamePayload(Room room) {
    final match = room.match!;
    return {
      'seed': match.seed,
      'controlledPlayerIds': const <String>[],
      'players': [for (final player in match.players) player.toJson()],
      'fixedHands': {
        for (final entry in match.hands.entries)
          entry.key: [for (final card in entry.value) card.toJson()],
      },
    };
  }

  List<Map<String, dynamic>> _localPlayersForPlayer(
    MatchState match,
    String playerId,
  ) {
    final playerIndex = match.players.indexWhere(
      (player) => player.playerId == playerId,
    );
    final safePlayerIndex = playerIndex < 0 ? 0 : playerIndex;
    final ordered = <MatchPlayer>[
      for (var offset = 0; offset < match.players.length; offset++)
        match.players[(safePlayerIndex + offset) % match.players.length],
    ];
    return [for (final player in ordered) player.toJson()];
  }

  /// Enviar mensaje a todos en una sala
  void _broadcastToRoom(
    String roomId,
    MultiplayerMessage message, {
    String? excludeConnection,
  }) {
    final room = roomManager.getRoom(roomId);
    if (room == null) return;

    for (final connId in room.getAllConnectionIds()) {
      if (connId != excludeConnection) {
        final connection = _connections[connId];
        if (connection != null) {
          connection.send(message);
        }
      }
    }
  }

  /// Crear servidor HTTP con WebSocket
  Future<void> start() async {
    final webSocketHandler = _createWebSocketHandler();

    // Combinar handlers - WebSocket tiene prioridad
    shelf.Handler handler = (shelf.Request request) {
      if (request.url.path == 'health') {
        return shelf.Response.ok(
          jsonEncode({'status': 'ok'}),
          headers: const {
            'content-type': 'application/json; charset=utf-8',
          },
        );
      }
      // Delegar a WebSocket handler
      return webSocketHandler(request);
    };

    await io.serve(handler, InternetAddress.anyIPv4, port);

    print('Zapiti server listening on ws://$host:$port/');
    print('Health check: http://$host:$port/health');
  }
}
