import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf/shelf_io.dart' as io;
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'client_connection.dart';
import 'match_state.dart';
import 'ranking_repository.dart';
import 'ranking_store.dart';
import 'room.dart';
import 'room_manager.dart';
import 'server_protocol.dart';

class ZapitiServer {
  late int port;
  late String host;
  final RoomManager roomManager = RoomManager();
  final RankingRepository rankingStore;
  static const int _multiplayerBotDifficulty = 4;
  HttpServer? _httpServer;

  // Map de connectionId -> ClientConnection
  final Map<String, ClientConnection> _connections = {};
  final Set<String> _recordedMatchIds = {};
  final Map<String, Timer> _turnTimeoutTimers = {};

  int _connectionCounter = 0;

  ZapitiServer({
    String? customHost,
    int? customPort,
    RankingRepository? customRankingStore,
  }) : rankingStore = customRankingStore ?? RankingStore() {
    // Leer puerto de variable de entorno o usar default
    port =
        customPort ??
        int.tryParse(Platform.environment['PORT'] ?? '8080') ??
        8080;
    host = customHost ?? '0.0.0.0';
  }

  /// Obtener un ID Ãºnico para conexiÃ³n
  String _getConnectionId() {
    return 'conn_${DateTime.now().millisecondsSinceEpoch}_${_connectionCounter++}';
  }

  void _log(String event, [Map<String, Object?> fields = const {}]) {
    final entry = <String, Object?>{
      'ts': DateTime.now().toIso8601String(),
      'event': event,
      ...fields,
    };
    print('[zapiti] ${jsonEncode(_redactLogValue(entry))}');
  }

  Object? _redactLogValue(Object? value, [String key = '']) {
    final lowerKey = key.toLowerCase();
    if (lowerKey.contains('password') ||
        lowerKey.contains('sessiontoken') ||
        lowerKey == 'token' ||
        lowerKey == 'pin') {
      return '<redacted>';
    }
    if (value is Map) {
      return {
        for (final entry in value.entries)
          entry.key.toString(): _redactLogValue(
            entry.value,
            entry.key.toString(),
          ),
      };
    }
    if (value is Iterable) {
      return [for (final entry in value) _redactLogValue(entry, key)];
    }
    if (value is String && value.length > 180) {
      return '${value.substring(0, 180)}...';
    }
    return value;
  }

  Map<String, Object?> _messageLogFields(
    ClientConnection connection,
    MultiplayerMessage message,
  ) {
    return {
      'connectionId': connection.connectionId,
      'connectionRoomId': connection.currentRoomId,
      'connectionPlayerId': connection.playerId,
      'type': message.type.value,
      'roomId': message.roomId,
      'playerId': message.playerId,
      'payload': message.payload,
    };
  }

  Map<String, Object?> _roomLogFields(Room? room) {
    if (room == null) return {'room': null};
    return {
      'room': {
        'roomId': room.roomId,
        'phase': room.phase,
        'seatCount': room.seats.length,
        'hasMatch': room.match != null,
        'seats': [
          for (final seat in room.seats)
            {
              'seatIndex': seat.seatIndex,
              'playerId': seat.playerId,
              'name': seat.name,
              'username': seat.username,
              'teamId': seat.teamId,
              'pairId': seat.pairId,
              'teamName': seat.teamName,
              'characterId': seat.characterId,
              'ready': seat.ready,
              'connected': seat.connected,
              'connectionId': room.getConnectionId(seat.playerId),
              'connectionKnown': _connections.containsKey(
                room.getConnectionId(seat.playerId),
              ),
            },
        ],
      },
    };
  }

  void _closeSupersededConnection(
    String connectionId, {
    required String replacementConnectionId,
    required String roomId,
    required String playerId,
  }) {
    final oldConnection = _connections.remove(connectionId);
    _log('connection_superseded', {
      'connectionId': connectionId,
      'replacementConnectionId': replacementConnectionId,
      'roomId': roomId,
      'playerId': playerId,
      'oldConnectionRoomId': oldConnection?.currentRoomId,
      'oldConnectionPlayerId': oldConnection?.playerId,
      'activeConnectionsAfterRemove': _connections.length,
    });
    try {
      oldConnection?.close();
    } catch (error) {
      _log('connection_superseded_close_error', {
        'connectionId': connectionId,
        'replacementConnectionId': replacementConnectionId,
        'roomId': roomId,
        'playerId': playerId,
        'error': error.toString(),
      });
    }
  }

  String? _sanitizePlayerId(String? rawPlayerId) {
    if (rawPlayerId == null) return null;
    final trimmed = rawPlayerId.trim();
    if (trimmed.isEmpty || trimmed.length > 80) return null;
    if (!RegExp(r'^[A-Za-z0-9_\-]+$').hasMatch(trimmed)) return null;
    return trimmed;
  }

  String? _sanitizeSessionToken(String? rawToken) {
    if (rawToken == null) return null;
    final trimmed = rawToken.trim();
    if (trimmed.length < 24 || trimmed.length > 128) return null;
    if (!RegExp(r'^[A-Za-z0-9_\-=]+$').hasMatch(trimmed)) return null;
    return trimmed;
  }

  String? _sanitizeUsername(String? rawUsername) {
    if (rawUsername == null) return null;
    final trimmed = rawUsername.trim().toLowerCase();
    if (trimmed.length < 3 || trimmed.length > 24) return null;
    if (!RegExp(r'^[a-z0-9_.-]+$').hasMatch(trimmed)) return null;
    return trimmed;
  }

  String? _sanitizePassword(String? rawPassword) {
    if (rawPassword == null) return null;
    final trimmed = rawPassword.trim();
    if (trimmed.length < 6 || trimmed.length > 72) return null;
    return trimmed;
  }

  String _sanitizeTeamName(String? rawTeamName) {
    final normalized =
        rawTeamName?.trim().replaceAll(RegExp(r'\s+'), ' ') ?? '';
    if (normalized.length <= 22) return normalized;
    return normalized.substring(0, 22).trimRight();
  }

  String? _sanitizePairId(String? rawPairId) {
    if (rawPairId == null) return null;
    final trimmed = rawPairId.trim();
    if (trimmed.isEmpty || trimmed.length > 180) return null;
    if (!RegExp(r'^[A-Za-z0-9_\-+]+$').hasMatch(trimmed)) return null;
    return trimmed;
  }

  /// Crear handler de WebSocket
  shelf.Handler _createWebSocketHandler() {
    return webSocketHandler(_handleWebSocketConnection);
  }

  void _handleWebSocketConnection(
    WebSocketChannel webSocket,
    String? protocol,
  ) {
    final connectionId = _getConnectionId();
    _log('connection_open', {
      'connectionId': connectionId,
      'protocol': protocol,
      'activeConnections': _connections.length + 1,
    });

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
  Future<void> _handleMessage(
    String connectionId,
    MultiplayerMessage message,
  ) async {
    final connection = _connections[connectionId];
    if (connection == null) return;

    try {
      _log('message_in', _messageLogFields(connection, message));
      switch (message.type) {
        case MultiplayerMessageType.createRoom:
          await _handleCreateRoom(connection, message);
          break;
        case MultiplayerMessageType.joinRoom:
          await _handleJoinRoom(connection, message);
          break;
        case MultiplayerMessageType.leaveRoom:
          _handleLeaveRoom(connection, message);
          break;
        case MultiplayerMessageType.playerReady:
          await _handlePlayerReady(connection, message);
          break;
        case MultiplayerMessageType.requestSignal:
          _handleRequestSignal(connection, message);
          break;
        case MultiplayerMessageType.selectCharacter:
          _handleSelectCharacter(connection, message);
          break;
        case MultiplayerMessageType.updateProfile:
          await _handleUpdateProfile(connection, message);
          break;
        case MultiplayerMessageType.recoverProfile:
          await _handleRecoverProfile(connection, message);
          break;
        case MultiplayerMessageType.listTeams:
          await _handleListTeams(connection, message);
          break;
        case MultiplayerMessageType.createTeam:
          await _handleCreateTeam(connection, message);
          break;
        case MultiplayerMessageType.updateTeam:
          await _handleUpdateTeam(connection, message);
          break;
        case MultiplayerMessageType.archiveTeam:
          await _handleArchiveTeam(connection, message);
          break;
        case MultiplayerMessageType.selectTeam:
          await _handleSelectTeam(connection, message);
          break;
        case MultiplayerMessageType.getRanking:
          await _handleGetRanking(connection);
          break;
        case MultiplayerMessageType.newHand:
          _handleNewHand(connection, message);
          break;
        case MultiplayerMessageType.restartGame:
          _handleRestartGame(connection, message);
          break;
        case MultiplayerMessageType.chooseAlVerDecision:
          await _handleGameMessage(connection, message);
          break;
        case MultiplayerMessageType.playCard:
        case MultiplayerMessageType.passHand:
        case MultiplayerMessageType.callTruco:
        case MultiplayerMessageType.acceptTruco:
        case MultiplayerMessageType.passTruco:
        case MultiplayerMessageType.raiseTruco:
        case MultiplayerMessageType.continueRound:
        case MultiplayerMessageType.signal:
          await _handleGameMessage(connection, message);
          break;
        default:
          connection.sendError('unknown_message_type', 'Unknown message type');
      }
    } catch (e) {
      _log('message_handler_error', {
        ..._messageLogFields(connection, message),
        'error': e.toString(),
      });
      connection.sendError('internal_error', 'Internal server error: $e');
    }
  }

  /// Crear sala
  Future<void> _handleCreateRoom(
    ClientConnection connection,
    MultiplayerMessage message,
  ) async {
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
    final username = _sanitizeUsername(payload['username']?.toString());
    final password = _sanitizePassword(
      (payload['password'] ?? payload['pin'])?.toString(),
    );
    final sessionToken = _sanitizeSessionToken(
      payload['sessionToken']?.toString(),
    );
    final teamName = _sanitizeTeamName(payload['teamName']?.toString());
    final pairId = _sanitizePairId(payload['pairId']?.toString());

    final playerId =
        _sanitizePlayerId(message.playerId) ??
        'player_${DateTime.now().millisecondsSinceEpoch}_${_connections.length}';

    Room? room;
    try {
      if (!await _syncProfileForRoom(
        connection,
        playerId: playerId,
        username: username,
        playerName: playerName,
        teamName: teamName,
        password: password,
        sessionToken: sessionToken,
      )) {
        return;
      }
      final selectedTeam = pairId == null
          ? null
          : await _authenticatedTeamForPlayer(
              connection,
              playerId: playerId,
              sessionToken: sessionToken,
              pairId: pairId,
            );
      if (pairId != null && selectedTeam == null) return;

      _log('room_create_attempt', {
        'connectionId': connection.connectionId,
        'playerId': playerId,
        'username': username,
        'playerName': playerName,
        'preferredCharacterId': preferredCharacterId,
        'pairId': pairId,
        'selectedPairId': selectedTeam?['pairId'],
      });
      room = roomManager.createRoom(
        playerName,
        playerId,
        connection.connectionId,
        username: username,
        pairId: selectedTeam?['pairId']?.toString(),
        teamName: selectedTeam?['teamName']?.toString() ?? teamName,
        allowPassHand: payload['allowPassHand'] == true,
      );
      if (preferredCharacterId != null) {
        try {
          room.setPlayerCharacter(playerId, preferredCharacterId);
        } catch (e) {
          final errorText = e is StateError ? e.message : e.toString();
          if (!errorText.contains('taken')) {
            rethrow;
          }
        }
      }
      connection.setCurrentRoom(room.roomId, playerId);

      _log('room_created', {
        'connectionId': connection.connectionId,
        'playerId': playerId,
        ..._roomLogFields(room),
      });

      connection.sendRoomSnapshot(room.roomId, playerId);
    } catch (e) {
      if (room != null) {
        _log('room_create_rollback', {
          'connectionId': connection.connectionId,
          'playerId': playerId,
          'error': e.toString(),
          ..._roomLogFields(room),
        });
        roomManager.leaveRoom(room.roomId, playerId);
      }
      _log('room_create_error', {
        'connectionId': connection.connectionId,
        'playerId': playerId,
        'error': e.toString(),
      });
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
  Future<void> _handleJoinRoom(
    ClientConnection connection,
    MultiplayerMessage message,
  ) async {
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
    final username = _sanitizeUsername(payload['username']?.toString());
    final password = _sanitizePassword(
      (payload['password'] ?? payload['pin'])?.toString(),
    );
    final sessionToken = _sanitizeSessionToken(
      payload['sessionToken']?.toString(),
    );
    final teamName = _sanitizeTeamName(payload['teamName']?.toString());
    final pairId = _sanitizePairId(payload['pairId']?.toString());
    final requestedPlayerId =
        _sanitizePlayerId(message.playerId) ??
        'player_${DateTime.now().millisecondsSinceEpoch}_${_connections.length}';

    Room? room;
    var joinedNewSeat = false;
    String? supersededConnectionId;
    try {
      if (!await _syncProfileForRoom(
        connection,
        playerId: requestedPlayerId,
        username: username,
        playerName: playerName,
        teamName: teamName,
        password: password,
        sessionToken: sessionToken,
      )) {
        return;
      }
      final selectedTeam = pairId == null
          ? null
          : await _authenticatedTeamForPlayer(
              connection,
              playerId: requestedPlayerId,
              sessionToken: sessionToken,
              pairId: pairId,
            );
      if (pairId != null && selectedTeam == null) return;

      room = roomManager.getRoom(roomId);

      if (room == null) {
        _log('room_join_missing_room', {
          'connectionId': connection.connectionId,
          'roomId': roomId,
          'requestedPlayerId': requestedPlayerId,
          'username': username,
        });
        connection.sendError('room_not_found', 'Room not found');
        return;
      }

      final playerId = requestedPlayerId;
      final existingSeatConnection = room.getConnectionId(playerId);
      final isReconnectingSeat = room.containsPlayer(playerId);
      _log('room_join_attempt', {
        'connectionId': connection.connectionId,
        'roomId': roomId,
        'requestedPlayerId': requestedPlayerId,
        'username': username,
        'playerName': playerName,
        'preferredCharacterId': preferredCharacterId,
        'pairId': pairId,
        'selectedPairId': selectedTeam?['pairId'],
        'isReconnectingSeat': isReconnectingSeat,
        'existingSeatConnection': existingSeatConnection,
        'existingConnectionKnown': _connections.containsKey(
          existingSeatConnection,
        ),
        ..._roomLogFields(room),
      });
      if (isReconnectingSeat) {
        if (existingSeatConnection != null &&
            existingSeatConnection != connection.connectionId &&
            _connections.containsKey(existingSeatConnection)) {
          _log('room_join_taking_over_existing_connection', {
            'connectionId': connection.connectionId,
            'roomId': roomId,
            'requestedPlayerId': requestedPlayerId,
            'existingSeatConnection': existingSeatConnection,
            ..._roomLogFields(room),
          });
          supersededConnectionId = existingSeatConnection;
        }

        roomManager.reconnectPlayer(
          roomId,
          playerName,
          playerId,
          connection.connectionId,
          username: username,
          pairId: selectedTeam?['pairId']?.toString(),
          teamName: selectedTeam?['teamName']?.toString() ?? teamName,
          characterId: preferredCharacterId,
        );
        if (supersededConnectionId != null) {
          _closeSupersededConnection(
            supersededConnectionId,
            replacementConnectionId: connection.connectionId,
            roomId: roomId,
            playerId: playerId,
          );
        }
        room = roomManager.getRoom(roomId);
        _log('room_player_reconnected', {
          'connectionId': connection.connectionId,
          'roomId': roomId,
          'playerId': playerId,
          ..._roomLogFields(room),
        });
      } else {
        room = roomManager.joinRoom(
          roomId,
          playerName,
          playerId,
          connection.connectionId,
          username: username,
          pairId: selectedTeam?['pairId']?.toString(),
          teamName: selectedTeam?['teamName']?.toString() ?? teamName,
          allowPassHand: payload['allowPassHand'] == true,
        );
        if (room == null) {
          connection.sendError('room_not_found', 'Room not found');
          return;
        }
        joinedNewSeat = true;
        if (preferredCharacterId != null) {
          try {
            room.setPlayerCharacter(playerId, preferredCharacterId);
          } catch (e) {
            final errorText = e is StateError ? e.message : e.toString();
            if (!errorText.contains('taken')) {
              rethrow;
            }
          }
        }
      }
      connection.setCurrentRoom(roomId, playerId);

      _log(isReconnectingSeat ? 'room_join_reconnected' : 'room_joined', {
        'connectionId': connection.connectionId,
        'roomId': roomId,
        'playerId': playerId,
        'playerName': playerName,
        ..._roomLogFields(room),
      });

      // Enviar snapshot a todos en la sala
      _broadcastRoomSnapshot(roomId);
    } catch (e) {
      if (room != null && joinedNewSeat) {
        _log('room_join_rollback', {
          'connectionId': connection.connectionId,
          'roomId': roomId,
          'requestedPlayerId': requestedPlayerId,
          'error': e.toString(),
          ..._roomLogFields(room),
        });
        roomManager.leaveRoom(roomId, requestedPlayerId);
      }
      _log('room_join_error', {
        'connectionId': connection.connectionId,
        'roomId': roomId,
        'requestedPlayerId': requestedPlayerId,
        'joinedNewSeat': joinedNewSeat,
        'error': e.toString(),
        ..._roomLogFields(room),
      });
      if (e is StateError && e.message.contains('full')) {
        connection.sendError('room_full', 'Room is full');
      } else if (e is StateError &&
          e.message.contains('Player already in room')) {
        connection.sendError(
          'player_already_in_room',
          'Player is already connected to this room',
        );
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

  Future<void> _handleGetRanking(ClientConnection connection) async {
    connection.send(
      MultiplayerMessage(
        type: MultiplayerMessageType.ranking,
        payload: await rankingStore.snapshot(),
      ),
    );
  }

  Future<void> _handleUpdateProfile(
    ClientConnection connection,
    MultiplayerMessage message,
  ) async {
    final payload = message.payload;
    final playerId = _sanitizePlayerId(message.playerId);
    if (payload == null || playerId == null) {
      connection.sendError('invalid_payload', 'Missing profile payload');
      return;
    }

    final name = Room.sanitizePlayerName(payload['name']);
    final username = _sanitizeUsername(payload['username']?.toString());
    final password = _sanitizePassword(
      (payload['password'] ?? payload['pin'])?.toString(),
    );
    final sessionToken = _sanitizeSessionToken(
      payload['sessionToken']?.toString(),
    );
    final teamName = _sanitizeTeamName(payload['teamName']?.toString());
    if (name == null) {
      connection.sendError('invalid_payload', 'Invalid profile name');
      return;
    }

    final profile = password != null && username != null
        ? await rankingStore.upsertPlayerProfile(
            playerId: playerId,
            username: username,
            name: name,
            password: password,
            teamName: teamName,
          )
        : sessionToken == null
        ? null
        : await rankingStore.updatePlayerProfileWithSession(
            playerId: playerId,
            name: name,
            teamName: teamName,
            sessionToken: sessionToken,
          );
    if (profile == null) {
      connection.sendError('auth_failed', 'Invalid profile session');
      return;
    }
    connection.send(
      MultiplayerMessage(
        type: MultiplayerMessageType.profile,
        playerId: playerId,
        payload: profile,
      ),
    );
  }

  Future<bool> _syncProfileForRoom(
    ClientConnection connection, {
    required String playerId,
    required String? username,
    required String playerName,
    required String teamName,
    required String? password,
    required String? sessionToken,
  }) async {
    if (sessionToken != null) {
      final profile = await rankingStore.updatePlayerProfileWithSession(
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

    if (username != null && password != null) {
      final profile = await rankingStore.upsertPlayerProfile(
        playerId: playerId,
        username: username,
        name: playerName,
        password: password,
        teamName: teamName,
      );
      if (profile == null) {
        connection.sendError('auth_failed', 'Invalid username or password');
        return false;
      }
    }
    return true;
  }

  Future<void> _handleRecoverProfile(
    ClientConnection connection,
    MultiplayerMessage message,
  ) async {
    final payload = message.payload;
    final username = _sanitizeUsername(payload?['username']?.toString());
    final password = _sanitizePassword(
      (payload?['password'] ?? payload?['pin'])?.toString(),
    );
    if (username == null || password == null) {
      connection.sendError('invalid_payload', 'Invalid login payload');
      return;
    }

    final profile = await rankingStore.recoverPlayerProfile(
      username: username,
      password: password,
    );
    if (profile == null) {
      connection.sendError('profile_not_found', 'Profile not found');
      return;
    }

    connection.send(
      MultiplayerMessage(
        type: MultiplayerMessageType.profile,
        playerId: profile['playerId']?.toString(),
        payload: profile,
      ),
    );
  }

  Future<void> _handleListTeams(
    ClientConnection connection,
    MultiplayerMessage message,
  ) async {
    final playerId = _sanitizePlayerId(message.playerId);
    final sessionToken = _sanitizeSessionToken(
      message.payload?['sessionToken']?.toString(),
    );
    if (playerId == null || sessionToken == null) {
      connection.sendError('auth_failed', 'Invalid profile session');
      return;
    }

    final teams = await rankingStore.teamsForPlayer(
      playerId: playerId,
      sessionToken: sessionToken,
    );
    connection.send(
      MultiplayerMessage(
        type: MultiplayerMessageType.teams,
        playerId: playerId,
        payload: {'teams': teams},
      ),
    );
  }

  Future<void> _handleCreateTeam(
    ClientConnection connection,
    MultiplayerMessage message,
  ) async {
    final payload = message.payload;
    final playerId = _sanitizePlayerId(message.playerId);
    final sessionToken = _sanitizeSessionToken(
      payload?['sessionToken']?.toString(),
    );
    final teammateUsername = _sanitizeUsername(
      payload?['teammateUsername']?.toString(),
    );
    final teamName = _sanitizeTeamName(payload?['teamName']?.toString());
    if (playerId == null || sessionToken == null || teammateUsername == null) {
      connection.sendError('invalid_payload', 'Invalid team payload');
      return;
    }

    final team = await rankingStore.createTeamForPlayer(
      playerId: playerId,
      sessionToken: sessionToken,
      teammateUsername: teammateUsername,
      teamName: teamName,
    );
    if (team == null) {
      connection.sendError('team_not_found', 'Could not create team');
      return;
    }
    await _sendTeamsForPlayer(connection, playerId, sessionToken);
  }

  Future<void> _handleUpdateTeam(
    ClientConnection connection,
    MultiplayerMessage message,
  ) async {
    final payload = message.payload;
    final playerId = _sanitizePlayerId(message.playerId);
    final sessionToken = _sanitizeSessionToken(
      payload?['sessionToken']?.toString(),
    );
    final pairId = _sanitizePairId(payload?['pairId']?.toString());
    final teamName = _sanitizeTeamName(payload?['teamName']?.toString());
    if (playerId == null ||
        sessionToken == null ||
        pairId == null ||
        teamName.isEmpty) {
      connection.sendError('invalid_payload', 'Invalid team payload');
      return;
    }

    final team = await rankingStore.updateTeamName(
      playerId: playerId,
      sessionToken: sessionToken,
      pairId: pairId,
      teamName: teamName,
    );
    if (team == null) {
      connection.sendError('team_not_found', 'Team not found');
      return;
    }
    await _sendTeamsForPlayer(connection, playerId, sessionToken);
  }

  Future<void> _handleArchiveTeam(
    ClientConnection connection,
    MultiplayerMessage message,
  ) async {
    final payload = message.payload;
    final playerId = _sanitizePlayerId(message.playerId);
    final sessionToken = _sanitizeSessionToken(
      payload?['sessionToken']?.toString(),
    );
    final pairId = _sanitizePairId(payload?['pairId']?.toString());
    if (playerId == null || sessionToken == null || pairId == null) {
      connection.sendError('invalid_payload', 'Invalid team payload');
      return;
    }

    final team = await rankingStore.archiveTeam(
      playerId: playerId,
      sessionToken: sessionToken,
      pairId: pairId,
    );
    if (team == null) {
      connection.sendError('team_not_found', 'Team not found');
      return;
    }
    await _sendTeamsForPlayer(connection, playerId, sessionToken);
  }

  Future<void> _handleSelectTeam(
    ClientConnection connection,
    MultiplayerMessage message,
  ) async {
    final roomId = message.roomId;
    final payload = message.payload;
    final playerId = _sanitizePlayerId(message.playerId);
    final sessionToken = _sanitizeSessionToken(
      payload?['sessionToken']?.toString(),
    );
    final pairId = _sanitizePairId(payload?['pairId']?.toString());
    if (roomId == null ||
        playerId == null ||
        sessionToken == null ||
        pairId == null) {
      connection.sendError('invalid_payload', 'Invalid team selection');
      return;
    }

    final room = roomManager.getRoom(roomId);
    if (room == null) {
      connection.sendError('room_not_found', 'Room not found');
      return;
    }
    if (room.phase != 'lobby') {
      connection.sendError('room_in_progress', 'Team selection is locked');
      return;
    }
    if (!room.containsPlayer(playerId)) {
      connection.sendError('player_not_found', 'Player not in room');
      return;
    }

    final team = await _authenticatedTeamForPlayer(
      connection,
      playerId: playerId,
      sessionToken: sessionToken,
      pairId: pairId,
    );
    if (team == null) return;
    if (!_teamMatchesRoomTeammate(room, playerId, team)) {
      _log('team_select_rejected_for_room', {
        'connectionId': connection.connectionId,
        'roomId': roomId,
        'playerId': playerId,
        'pairId': pairId,
        'team': team,
        ..._roomLogFields(room),
      });
      connection.sendError(
        'invalid_team_for_room',
        'Team does not match the player position in this room',
      );
      return;
    }

    room.setPlayerTeam(
      playerId,
      pairId: team['pairId']?.toString() ?? pairId,
      teamName: team['teamName']?.toString() ?? '',
    );
    _log('team_selected', {
      'connectionId': connection.connectionId,
      'roomId': roomId,
      'playerId': playerId,
      'pairId': team['pairId']?.toString() ?? pairId,
      'teamName': team['teamName']?.toString() ?? '',
      ..._roomLogFields(room),
    });
    _broadcastRoomSnapshot(roomId);
  }

  Future<Map<String, dynamic>?> _authenticatedTeamForPlayer(
    ClientConnection connection, {
    required String playerId,
    required String? sessionToken,
    required String pairId,
  }) async {
    if (sessionToken == null) {
      connection.sendError('auth_failed', 'Invalid profile session');
      return null;
    }
    final team = await rankingStore.teamForPlayer(
      playerId: playerId,
      sessionToken: sessionToken,
      pairId: pairId,
    );
    if (team == null) {
      connection.sendError('team_not_found', 'Team not found');
      return null;
    }
    return team;
  }

  bool _teamMatchesRoomTeammate(
    Room room,
    String playerId,
    Map<String, dynamic> team,
  ) {
    final localSeat = room.seats.cast<MultiplayerSeat?>().firstWhere(
      (seat) => seat?.playerId == playerId,
      orElse: () => null,
    );
    if (localSeat == null) return false;

    final teammateSeat = room.seats.cast<MultiplayerSeat?>().firstWhere((seat) {
      if (seat == null || seat.playerId == playerId) return false;
      if (room.seats.length == 2) return true;
      return seat.teamId == localSeat.teamId;
    }, orElse: () => null);
    if (teammateSeat == null) return false;

    final teammateIds = team['teammateIds'];
    if (teammateIds is! List) return false;
    return teammateIds
        .map((entry) => entry.toString())
        .contains(teammateSeat.playerId);
  }

  Future<void> _sendTeamsForPlayer(
    ClientConnection connection,
    String playerId,
    String sessionToken,
  ) async {
    connection.send(
      MultiplayerMessage(
        type: MultiplayerMessageType.teams,
        playerId: playerId,
        payload: {
          'teams': await rankingStore.teamsForPlayer(
            playerId: playerId,
            sessionToken: sessionToken,
          ),
        },
      ),
    );
  }

  /// Abandonar sala
  void _handleLeaveRoom(
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
  Future<void> _handlePlayerReady(
    ClientConnection connection,
    MultiplayerMessage message,
  ) async {
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
    if (ready && _requiresTeamSelection(room, playerId)) {
      _log('ready_rejected_team_required', {
        'connectionId': connection.connectionId,
        'roomId': roomId,
        'playerId': playerId,
        ..._roomLogFields(room),
      });
      connection.sendError(
        'team_required',
        'Select or create a team before getting ready',
      );
      return;
    }

    room.setPlayerReady(playerId, ready);
    _log('player_ready_changed', {
      'connectionId': connection.connectionId,
      'roomId': roomId,
      'playerId': playerId,
      'ready': ready,
      'allReady': room.areAllReady(),
      ..._roomLogFields(room),
    });

    // Enviar snapshot
    _broadcastRoomSnapshot(roomId);

    // Si todos estÃ¡n listos y hay al menos 2 jugadores, iniciar juego
    if (room.match == null && room.areAllReady() && room.seats.length >= 2) {
      _log('match_start_conditions_met', {
        'roomId': roomId,
        ..._roomLogFields(room),
      });
      await _startMatch(room);
    }
  }

  bool _requiresTeamSelection(Room room, String playerId) {
    final localSeat = room.seats.cast<MultiplayerSeat?>().firstWhere(
      (seat) => seat?.playerId == playerId,
      orElse: () => null,
    );
    if (localSeat == null) return false;
    if (room.seats.length < Room.maxSeats) return false;
    final hasHumanTeammate = room.seats.any((seat) {
      if (seat.playerId == playerId) return false;
      if ((seat.username ?? '').trim().isEmpty) return false;
      return seat.teamId == localSeat.teamId;
    });
    return hasHumanTeammate && (localSeat.pairId ?? '').trim().isEmpty;
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

    final rawCharacterId = payload['characterId'];
    final characterId = rawCharacterId as String?;
    if (rawCharacterId != null && characterId != null && characterId.isEmpty) {
      connection.sendError('invalid_payload', 'Invalid characterId');
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
      if (characterId == null) {
        room.clearPlayerCharacter(playerId);
      } else {
        room.setPlayerCharacter(playerId, characterId);
      }
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
  Future<void> _handleGameMessage(
    ClientConnection connection,
    MultiplayerMessage message,
  ) async {
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
      case MultiplayerMessageType.passHand:
        _handlePassHand(connection, room, match, message);
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
        _broadcastToRoom(
          roomId,
          message,
          excludeConnection: connection.connectionId,
        );
        break;
      default:
        connection.sendError('unknown_message_type', 'Unknown game message');
    }

    _broadcastRoomSnapshot(roomId);
    _advanceMatchIfNeeded(room, excludeConnection: connection.connectionId);
    await _recordMatchIfFinished(room);
    _broadcastRoomSnapshot(roomId);
  }

  Future<void> _startMatch(Room room) async {
    _log('match_starting', {'roomId': room.roomId, ..._roomLogFields(room)});
    room.setPhase('starting');
    final match = MatchState.start(
      roomId: room.roomId,
      createdAt: room.createdAt,
      seed: DateTime.now().millisecondsSinceEpoch,
      players: _buildPlayersForRoom(room),
      allowPassHand: room.allowPassHand,
    );
    room.startMatch(match);
    _log('match_started', {
      'roomId': room.roomId,
      'seed': match.seed,
      'players': [for (final player in match.players) player.toJson()],
      ..._roomLogFields(room),
    });

    _broadcastRoomSnapshot(room.roomId);
    _broadcastStartGame(room.roomId);

    room.setPhase('playing');
    _broadcastRoomSnapshot(room.roomId);
    _advanceMatchIfNeeded(room);
    await _recordMatchIfFinished(room);
    _broadcastRoomSnapshot(room.roomId);
  }

  List<MatchPlayer> _buildPlayersForRoom(Room room) {
    final seats = [...room.seats]
      ..sort((a, b) => a.seatIndex.compareTo(b.seatIndex));
    final assignedCharacterIds = <String>{};

    if (seats.length == 2) {
      final firstHuman = seats[0];
      final secondHuman = seats[1];
      return [
        _humanMatchPlayer(
          room,
          firstHuman,
          teamId: 1,
          characterId: _assignMatchCharacter(
            assignedCharacterIds,
            preferredCharacterId: firstHuman.characterId,
            fallbackSeatIndex: firstHuman.seatIndex,
          ),
        ),
        _botMatchPlayer(
          room,
          1,
          teamId: 2,
          characterId: _assignMatchCharacter(
            assignedCharacterIds,
            fallbackSeatIndex: 1,
          ),
        ),
        _humanMatchPlayer(
          room,
          secondHuman,
          teamId: 1,
          characterId: _assignMatchCharacter(
            assignedCharacterIds,
            preferredCharacterId: secondHuman.characterId,
            fallbackSeatIndex: secondHuman.seatIndex,
          ),
        ),
        _botMatchPlayer(
          room,
          3,
          teamId: 2,
          characterId: _assignMatchCharacter(
            assignedCharacterIds,
            fallbackSeatIndex: 3,
          ),
        ),
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
            characterId: _assignMatchCharacter(
              assignedCharacterIds,
              preferredCharacterId: seatsByIndex[seatIndex]!.characterId,
              fallbackSeatIndex: seatIndex,
            ),
          )
        else
          _botMatchPlayer(
            room,
            seatIndex,
            teamId: seatIndex.isEven ? 1 : 2,
            characterId: _assignMatchCharacter(
              assignedCharacterIds,
              fallbackSeatIndex: seatIndex,
            ),
          ),
    ];
  }

  MatchPlayer _humanMatchPlayer(
    Room room,
    MultiplayerSeat seat, {
    required int teamId,
    required String characterId,
  }) {
    return MatchPlayer(
      playerId: seat.playerId,
      name: seat.name,
      teamId: teamId,
      connectionId: room.getConnectionId(seat.playerId),
      pairId: seat.pairId,
      teamName: seat.teamName,
      characterId: characterId,
    );
  }

  MatchPlayer _botMatchPlayer(
    Room room,
    int seatIndex, {
    required int teamId,
    required String characterId,
  }) {
    return MatchPlayer(
      playerId: 'bot_${room.roomId}_$seatIndex',
      name: 'Bot ${seatIndex + 1}',
      teamId: teamId,
      characterId: characterId,
      aiDifficulty: _multiplayerBotDifficulty,
    );
  }

  String _assignMatchCharacter(
    Set<String> assignedCharacterIds, {
    String? preferredCharacterId,
    required int fallbackSeatIndex,
  }) {
    if (preferredCharacterId != null &&
        defaultCharacterIds.contains(preferredCharacterId) &&
        assignedCharacterIds.add(preferredCharacterId)) {
      return preferredCharacterId;
    }

    final fallbackCharacterId =
        defaultCharacterIds[fallbackSeatIndex % defaultCharacterIds.length];
    if (assignedCharacterIds.add(fallbackCharacterId)) {
      return fallbackCharacterId;
    }

    for (final characterId in defaultCharacterIds) {
      if (assignedCharacterIds.add(characterId)) return characterId;
    }

    return fallbackCharacterId;
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

  void _handlePassHand(
    ClientConnection connection,
    Room room,
    MatchState match,
    MultiplayerMessage message,
  ) {
    final playerId = message.playerId;
    final toPlayerId = message.payload?['toPlayerId']?.toString();
    if (playerId == null || toPlayerId == null) {
      connection.sendError('invalid_payload', 'Missing pass hand target');
      return;
    }

    try {
      match.passHand(fromPlayerId: playerId, toPlayerId: toPlayerId);
    } catch (e) {
      connection.sendError('invalid_move', 'Cannot pass hand: $e');
      return;
    }

    _broadcastToRoom(
      room.roomId,
      MultiplayerMessage(
        type: MultiplayerMessageType.passHand,
        roomId: room.roomId,
        playerId: playerId,
        payload: {'toPlayerId': toPlayerId},
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
        match.callTruco(bot.playerId, value: TrucoRules.firstTrucoValue);
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

    _scheduleTurnTimeout(room);
  }

  void _scheduleTurnTimeout(Room room) {
    _turnTimeoutTimers.remove(room.roomId)?.cancel();
    final match = room.match;
    final deadline = match?.turnDeadlineAt;
    if (match == null || deadline == null || !match.isAwaitingCardPlay) {
      return;
    }

    final delayMillis = max(
      0,
      deadline - DateTime.now().millisecondsSinceEpoch,
    );
    _turnTimeoutTimers[room.roomId] = Timer(
      Duration(milliseconds: delayMillis),
      () {
        _handleTurnTimeout(room.roomId, deadline).catchError((
          Object error,
          StackTrace stackTrace,
        ) {
          _log('turn_timeout_handler_error', {
            'roomId': room.roomId,
            'error': error.toString(),
          });
        });
      },
    );
  }

  Future<void> _handleTurnTimeout(String roomId, int expectedDeadline) async {
    _turnTimeoutTimers.remove(roomId)?.cancel();
    final room = roomManager.getRoom(roomId);
    final match = room?.match;
    if (room == null || match == null) return;
    if (match.turnDeadlineAt != expectedDeadline || !match.isAwaitingCardPlay) {
      _scheduleTurnTimeout(room);
      return;
    }

    final now = DateTime.now().millisecondsSinceEpoch;
    if (now < expectedDeadline) {
      _scheduleTurnTimeout(room);
      return;
    }

    PlayedCard playedCard;
    try {
      playedCard = match.playTimeoutCard(now: now);
    } catch (e) {
      print('Turn timeout failed: $e');
      _scheduleTurnTimeout(room);
      return;
    }

    _broadcastToRoom(
      room.roomId,
      MultiplayerMessage(
        type: MultiplayerMessageType.playCard,
        roomId: room.roomId,
        playerId: playedCard.player.playerId,
        payload: {
          'card': playedCard.card.toJson(),
          'autoPlayed': true,
          'reason': 'turn_timeout',
        },
      ),
    );
    _broadcastRoomSnapshot(room.roomId);
    _advanceMatchIfNeeded(room);
    await _recordMatchIfFinished(room);
    _broadcastRoomSnapshot(room.roomId);
  }

  Future<void> _recordMatchIfFinished(Room room) async {
    final match = room.match;
    if (match == null || match.winningTeamId == null) return;

    final matchId = '${match.roomId}_${match.seed}';
    if (_recordedMatchIds.contains(matchId)) return;

    await rankingStore.recordFinishedMatch(match);
    _recordedMatchIds.add(matchId);
  }

  /// Manejar desconexiÃ³n
  void _handleDisconnect(String connectionId) {
    final connection = _connections[connectionId];
    _log('connection_close', {
      'connectionId': connectionId,
      'connectionRoomId': connection?.currentRoomId,
      'connectionPlayerId': connection?.playerId,
      'activeConnectionsBefore': _connections.length,
    });
    final affectedRooms = roomManager.handleDisconnection(connectionId);
    _connections.remove(connectionId);
    _log('connection_removed', {
      'connectionId': connectionId,
      'affectedRooms': affectedRooms,
      'activeConnectionsAfter': _connections.length,
    });

    for (final roomId in affectedRooms) {
      final room = roomManager.getRoom(roomId);
      if (room != null) {
        _log('room_after_disconnect_before_reset', {
          'roomId': roomId,
          ..._roomLogFields(room),
        });
        room.clearMatch();
        room.setPhase('lobby');
        // Resetear estado listo para todos los jugadores que quedan
        for (final seat in room.seats) {
          room.setPlayerReady(seat.playerId, false);
        }
        _log('room_after_disconnect_reset', {
          'roomId': roomId,
          ..._roomLogFields(room),
        });
        _broadcastRoomSnapshot(roomId);
      } else {
        _log('room_removed_after_disconnect', {
          'roomId': roomId,
          'connectionId': connectionId,
        });
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
          connection.send(
            MultiplayerMessage(
              type: MultiplayerMessageType.roomSnapshot,
              roomId: roomId,
              playerId: seat.playerId,
              payload: payload,
            ),
          );
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

      connection.send(
        MultiplayerMessage(
          type: MultiplayerMessageType.startGame,
          roomId: roomId,
          playerId: seat.playerId,
          payload: localPayload,
        ),
      );
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
          headers: const {'content-type': 'application/json; charset=utf-8'},
        );
      }
      // Delegar a WebSocket handler
      return webSocketHandler(request);
    };

    _httpServer = await io.serve(handler, InternetAddress.anyIPv4, port);
    port = _httpServer!.port;

    print('Zapiti server listening on ws://$host:$port/');
    print('Health check: http://$host:$port/health');
  }

  Future<void> stop({bool closeRankingStore = true}) async {
    for (final timer in _turnTimeoutTimers.values) {
      timer.cancel();
    }
    _turnTimeoutTimers.clear();
    await _httpServer?.close(force: true);
    _httpServer = null;
    if (closeRankingStore) {
      await rankingStore.close();
    }
  }
}
