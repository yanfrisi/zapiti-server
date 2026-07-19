import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:zapiti_server/ranking_store.dart';
import 'package:zapiti_server/server.dart';
import 'package:zapiti_server/server_protocol.dart';

void main() {
  test('four players can create teams, ready up, and start a match', () async {
    final tempDir = Directory.systemTemp.createTempSync('zapiti_flow_test');
    addTearDown(() => tempDir.deleteSync(recursive: true));

    final rankingStore = RankingStore(path: '${tempDir.path}/ranking.sqlite');
    final server = ZapitiServer(
      customHost: '127.0.0.1',
      customPort: 0,
      customRankingStore: rankingStore,
    );
    await server.start();
    addTearDown(server.stop);

    final clients = [
      await _TestClient.connect(server.port),
      await _TestClient.connect(server.port),
      await _TestClient.connect(server.port),
      await _TestClient.connect(server.port),
    ];
    for (final client in clients) {
      addTearDown(client.close);
    }

    final profiles = <Map<String, dynamic>>[];
    for (var index = 0; index < clients.length; index++) {
      clients[index].send(MultiplayerMessage(
        type: MultiplayerMessageType.updateProfile,
        playerId: 'p$index',
        payload: {
          'username': 'player$index',
          'name': 'Player $index',
          'password': 'secret$index',
          'teamName': '',
        },
      ));
      profiles.add(
        await clients[index].expectType(MultiplayerMessageType.profile),
      );
    }

    clients[0].send(MultiplayerMessage(
      type: MultiplayerMessageType.createRoom,
      playerId: 'p0',
      payload: {
        'username': 'player0',
        'name': 'Player 0',
        'sessionToken': profiles[0]['sessionToken'],
        'characterId': 'p1',
      },
    ));
    final createdRoom = await clients[0].expectType(
      MultiplayerMessageType.roomSnapshot,
    );
    final roomId = createdRoom['roomId'] as String;

    for (var index = 1; index < clients.length; index++) {
      clients[index].send(MultiplayerMessage(
        type: MultiplayerMessageType.joinRoom,
        roomId: roomId,
        playerId: 'p$index',
        payload: {
          'username': 'player$index',
          'name': 'Player $index',
          'sessionToken': profiles[index]['sessionToken'],
          'characterId': 'p1',
        },
      ));
    }

    await Future.wait([
      for (final client in clients) client.expectRoomWithSeats(4),
    ]);

    final team02 = await _createTeam(
      clients[0],
      playerId: 'p0',
      sessionToken: profiles[0]['sessionToken'] as String,
      teammateUsername: 'player2',
      teamName: 'Equipo 0-2',
    );
    final team13 = await _createTeam(
      clients[1],
      playerId: 'p1',
      sessionToken: profiles[1]['sessionToken'] as String,
      teammateUsername: 'player3',
      teamName: 'Equipo 1-3',
    );

    await _selectTeam(
      clients[0],
      roomId: roomId,
      playerId: 'p0',
      sessionToken: profiles[0]['sessionToken'] as String,
      pairId: team02,
    );
    await _selectTeam(
      clients[2],
      roomId: roomId,
      playerId: 'p2',
      sessionToken: profiles[2]['sessionToken'] as String,
      pairId: team02,
    );
    await _selectTeam(
      clients[1],
      roomId: roomId,
      playerId: 'p1',
      sessionToken: profiles[1]['sessionToken'] as String,
      pairId: team13,
    );
    await _selectTeam(
      clients[3],
      roomId: roomId,
      playerId: 'p3',
      sessionToken: profiles[3]['sessionToken'] as String,
      pairId: team13,
    );

    for (var index = 0; index < clients.length; index++) {
      clients[index].send(MultiplayerMessage(
        type: MultiplayerMessageType.playerReady,
        roomId: roomId,
        playerId: 'p$index',
        payload: {'ready': true},
      ));
    }

    final startGame = await clients[0].expectType(
      MultiplayerMessageType.startGame,
      timeout: const Duration(seconds: 5),
    );
    final players = startGame['players'] as List<dynamic>;
    expect(players, hasLength(4));
    expect(
      players
          .where((player) => player is Map && player['aiDifficulty'] != null),
      isEmpty,
    );
  });

  test('four player room rejects teams that do not match seat partners',
      () async {
    final tempDir = Directory.systemTemp.createTempSync('zapiti_flow_test');
    addTearDown(() => tempDir.deleteSync(recursive: true));

    final rankingStore = RankingStore(path: '${tempDir.path}/ranking.sqlite');
    final server = ZapitiServer(
      customHost: '127.0.0.1',
      customPort: 0,
      customRankingStore: rankingStore,
    );
    await server.start();
    addTearDown(server.stop);

    final clients = [
      await _TestClient.connect(server.port),
      await _TestClient.connect(server.port),
      await _TestClient.connect(server.port),
      await _TestClient.connect(server.port),
    ];
    for (final client in clients) {
      addTearDown(client.close);
    }

    final profiles = <Map<String, dynamic>>[];
    for (var index = 0; index < clients.length; index++) {
      clients[index].send(MultiplayerMessage(
        type: MultiplayerMessageType.updateProfile,
        playerId: 'p$index',
        payload: {
          'username': 'seat$index',
          'name': 'Seat $index',
          'password': 'secret$index',
          'teamName': '',
        },
      ));
      profiles.add(
        await clients[index].expectType(MultiplayerMessageType.profile),
      );
    }

    clients[0].send(MultiplayerMessage(
      type: MultiplayerMessageType.createRoom,
      playerId: 'p0',
      payload: {
        'username': 'seat0',
        'name': 'Seat 0',
        'sessionToken': profiles[0]['sessionToken'],
        'characterId': 'p1',
      },
    ));
    final createdRoom = await clients[0].expectType(
      MultiplayerMessageType.roomSnapshot,
    );
    final roomId = createdRoom['roomId'] as String;

    for (var index = 1; index < clients.length; index++) {
      clients[index].send(MultiplayerMessage(
        type: MultiplayerMessageType.joinRoom,
        roomId: roomId,
        playerId: 'p$index',
        payload: {
          'username': 'seat$index',
          'name': 'Seat $index',
          'sessionToken': profiles[index]['sessionToken'],
          'characterId': 'p1',
        },
      ));
    }

    await Future.wait([
      for (final client in clients) client.expectRoomWithSeats(4),
    ]);

    final invalidPair = await _createTeam(
      clients[0],
      playerId: 'p0',
      sessionToken: profiles[0]['sessionToken'] as String,
      teammateUsername: 'seat1',
      teamName: 'Invalid 0-1',
    );
    await _selectTeamExpectError(
      clients[0],
      roomId: roomId,
      playerId: 'p0',
      sessionToken: profiles[0]['sessionToken'] as String,
      pairId: invalidPair,
      code: 'invalid_team_for_room',
    );

    final validPair = await _createTeam(
      clients[0],
      playerId: 'p0',
      sessionToken: profiles[0]['sessionToken'] as String,
      teammateUsername: 'seat2',
      teamName: 'Valid 0-2',
    );
    await _selectTeam(
      clients[0],
      roomId: roomId,
      playerId: 'p0',
      sessionToken: profiles[0]['sessionToken'] as String,
      pairId: validPair,
    );
  });

  test('four simulated human players can play a multiplayer match', () async {
    final setup = await _createFourPlayerStartedMatch();
    addTearDown(setup.close);

    final match = await _playAutomatedHumanMatch(
      clients: setup.clients,
      roomId: setup.roomId,
      playerIds: const ['p0', 'p1', 'p2', 'p3'],
      initialSnapshot: setup.initialSnapshot,
      maxActions: 160,
      requireFinish: false,
    );

    expect(match['score'], isA<Map>());
    expect(match['currentPlayerId'], isA<String>());
  }, timeout: const Timeout(Duration(seconds: 20)));

  test('two players start with server-controlled hard bots', () async {
    final tempDir = Directory.systemTemp.createTempSync('zapiti_flow_test');
    addTearDown(() => tempDir.deleteSync(recursive: true));

    final rankingStore = RankingStore(path: '${tempDir.path}/ranking.sqlite');
    final server = ZapitiServer(
      customHost: '127.0.0.1',
      customPort: 0,
      customRankingStore: rankingStore,
    );
    await server.start();
    addTearDown(server.stop);

    final clients = [
      await _TestClient.connect(server.port),
      await _TestClient.connect(server.port),
    ];
    for (final client in clients) {
      addTearDown(client.close);
    }

    final profiles = <Map<String, dynamic>>[];
    for (var index = 0; index < clients.length; index++) {
      clients[index].send(MultiplayerMessage(
        type: MultiplayerMessageType.updateProfile,
        playerId: 'p$index',
        payload: {
          'username': 'duo$index',
          'name': 'Duo $index',
          'password': 'secret$index',
          'teamName': '',
        },
      ));
      profiles.add(
        await clients[index].expectType(MultiplayerMessageType.profile),
      );
    }

    clients[0].send(MultiplayerMessage(
      type: MultiplayerMessageType.createRoom,
      playerId: 'p0',
      payload: {
        'username': 'duo0',
        'name': 'Duo 0',
        'sessionToken': profiles[0]['sessionToken'],
        'characterId': 'p1',
      },
    ));
    final createdRoom = await clients[0].expectType(
      MultiplayerMessageType.roomSnapshot,
    );
    final roomId = createdRoom['roomId'] as String;

    clients[1].send(MultiplayerMessage(
      type: MultiplayerMessageType.joinRoom,
      roomId: roomId,
      playerId: 'p1',
      payload: {
        'username': 'duo1',
        'name': 'Duo 1',
        'sessionToken': profiles[1]['sessionToken'],
        'characterId': 'p1',
      },
    ));
    await Future.wait([
      for (final client in clients) client.expectRoomWithSeats(2),
    ]);

    final pairId = await _createTeam(
      clients[0],
      playerId: 'p0',
      sessionToken: profiles[0]['sessionToken'] as String,
      teammateUsername: 'duo1',
      teamName: 'Duo Bravo',
    );
    await _selectTeam(
      clients[0],
      roomId: roomId,
      playerId: 'p0',
      sessionToken: profiles[0]['sessionToken'] as String,
      pairId: pairId,
    );
    await _selectTeam(
      clients[1],
      roomId: roomId,
      playerId: 'p1',
      sessionToken: profiles[1]['sessionToken'] as String,
      pairId: pairId,
    );

    for (var index = 0; index < clients.length; index++) {
      clients[index].send(MultiplayerMessage(
        type: MultiplayerMessageType.playerReady,
        roomId: roomId,
        playerId: 'p$index',
        payload: {'ready': true},
      ));
    }

    final startGame = await clients[0].expectType(
      MultiplayerMessageType.startGame,
      timeout: const Duration(seconds: 5),
    );
    final players = startGame['players'] as List<dynamic>;
    final bots = [
      for (final player in players)
        if (player is Map && player['aiDifficulty'] != null) player,
    ];
    expect(bots, hasLength(2));
    expect(bots.map((bot) => bot['aiDifficulty']).toSet(), {4});
  });

  test('two players can ready up without creating a manual team', () async {
    final tempDir = Directory.systemTemp.createTempSync('zapiti_flow_test');
    addTearDown(() => tempDir.deleteSync(recursive: true));

    final rankingStore = RankingStore(path: '${tempDir.path}/ranking.sqlite');
    final server = ZapitiServer(
      customHost: '127.0.0.1',
      customPort: 0,
      customRankingStore: rankingStore,
    );
    await server.start();
    addTearDown(server.stop);

    final clients = [
      await _TestClient.connect(server.port),
      await _TestClient.connect(server.port),
    ];
    for (final client in clients) {
      addTearDown(client.close);
    }

    final profiles = <Map<String, dynamic>>[];
    for (var index = 0; index < clients.length; index++) {
      clients[index].send(MultiplayerMessage(
        type: MultiplayerMessageType.updateProfile,
        playerId: 'quick$index',
        payload: {
          'username': 'quick$index',
          'name': 'Quick $index',
          'password': 'secret$index',
          'teamName': '',
        },
      ));
      profiles.add(
        await clients[index].expectType(MultiplayerMessageType.profile),
      );
    }

    clients[0].send(MultiplayerMessage(
      type: MultiplayerMessageType.createRoom,
      playerId: 'quick0',
      payload: {
        'username': 'quick0',
        'name': 'Quick 0',
        'sessionToken': profiles[0]['sessionToken'],
      },
    ));
    final createdRoom = await clients[0].expectType(
      MultiplayerMessageType.roomSnapshot,
    );
    final roomId = createdRoom['roomId'] as String;

    clients[1].send(MultiplayerMessage(
      type: MultiplayerMessageType.joinRoom,
      roomId: roomId,
      playerId: 'quick1',
      payload: {
        'username': 'quick1',
        'name': 'Quick 1',
        'sessionToken': profiles[1]['sessionToken'],
      },
    ));
    await Future.wait([
      for (final client in clients) client.expectRoomWithSeats(2),
    ]);

    for (var index = 0; index < clients.length; index++) {
      clients[index].send(MultiplayerMessage(
        type: MultiplayerMessageType.playerReady,
        roomId: roomId,
        playerId: 'quick$index',
        payload: {'ready': true},
      ));
    }

    final startGame = await clients[0].expectType(
      MultiplayerMessageType.startGame,
      timeout: const Duration(seconds: 5),
    );
    final players = startGame['players'] as List<dynamic>;
    expect(players, hasLength(4));
  });
}

Future<_StartedMatchSetup> _createFourPlayerStartedMatch() async {
  final tempDir = Directory.systemTemp.createTempSync('zapiti_flow_test');
  final rankingStore = RankingStore(path: '${tempDir.path}/ranking.sqlite');
  final server = ZapitiServer(
    customHost: '127.0.0.1',
    customPort: 0,
    customRankingStore: rankingStore,
  );
  await server.start();

  final clients = [
    await _TestClient.connect(server.port),
    await _TestClient.connect(server.port),
    await _TestClient.connect(server.port),
    await _TestClient.connect(server.port),
  ];

  final profiles = <Map<String, dynamic>>[];
  for (var index = 0; index < clients.length; index++) {
    clients[index].send(MultiplayerMessage(
      type: MultiplayerMessageType.updateProfile,
      playerId: 'p$index',
      payload: {
        'username': 'sim$index',
        'name': 'Sim $index',
        'password': 'secret$index',
        'teamName': '',
      },
    ));
    profiles.add(
      await clients[index].expectType(MultiplayerMessageType.profile),
    );
  }

  clients[0].send(MultiplayerMessage(
    type: MultiplayerMessageType.createRoom,
    playerId: 'p0',
    payload: {
      'username': 'sim0',
      'name': 'Sim 0',
      'sessionToken': profiles[0]['sessionToken'],
      'characterId': 'p1',
    },
  ));
  final createdRoom = await clients[0].expectType(
    MultiplayerMessageType.roomSnapshot,
  );
  final roomId = createdRoom['roomId'] as String;

  for (var index = 1; index < clients.length; index++) {
    clients[index].send(MultiplayerMessage(
      type: MultiplayerMessageType.joinRoom,
      roomId: roomId,
      playerId: 'p$index',
      payload: {
        'username': 'sim$index',
        'name': 'Sim $index',
        'sessionToken': profiles[index]['sessionToken'],
        'characterId': 'p1',
      },
    ));
  }
  await Future.wait([
    for (final client in clients) client.expectRoomWithSeats(4),
  ]);

  final team02 = await _createTeam(
    clients[0],
    playerId: 'p0',
    sessionToken: profiles[0]['sessionToken'] as String,
    teammateUsername: 'sim2',
    teamName: 'Sim 0-2',
  );
  final team13 = await _createTeam(
    clients[1],
    playerId: 'p1',
    sessionToken: profiles[1]['sessionToken'] as String,
    teammateUsername: 'sim3',
    teamName: 'Sim 1-3',
  );

  await _selectTeam(
    clients[0],
    roomId: roomId,
    playerId: 'p0',
    sessionToken: profiles[0]['sessionToken'] as String,
    pairId: team02,
  );
  await _selectTeam(
    clients[2],
    roomId: roomId,
    playerId: 'p2',
    sessionToken: profiles[2]['sessionToken'] as String,
    pairId: team02,
  );
  await _selectTeam(
    clients[1],
    roomId: roomId,
    playerId: 'p1',
    sessionToken: profiles[1]['sessionToken'] as String,
    pairId: team13,
  );
  await _selectTeam(
    clients[3],
    roomId: roomId,
    playerId: 'p3',
    sessionToken: profiles[3]['sessionToken'] as String,
    pairId: team13,
  );

  for (var index = 0; index < clients.length; index++) {
    clients[index].send(MultiplayerMessage(
      type: MultiplayerMessageType.playerReady,
      roomId: roomId,
      playerId: 'p$index',
      payload: {'ready': true},
    ));
  }

  await clients[0].expectType(
    MultiplayerMessageType.startGame,
    timeout: const Duration(seconds: 5),
  );
  final initialSnapshot = await clients[0].expectMatchSnapshot();
  return _StartedMatchSetup(
    tempDir: tempDir,
    server: server,
    clients: clients,
    roomId: roomId,
    initialSnapshot: initialSnapshot,
  );
}

Future<Map<String, dynamic>> _playAutomatedHumanMatch({
  required List<_TestClient> clients,
  required String roomId,
  required List<String> playerIds,
  required Map<String, dynamic> initialSnapshot,
  int maxActions = 700,
  bool requireFinish = true,
}) async {
  final clientsByPlayerId = {
    for (var index = 0; index < playerIds.length; index++)
      playerIds[index]: clients[index],
  };

  var snapshot = initialSnapshot;
  for (var step = 0; step < maxActions; step++) {
    final match = snapshot['match'] as Map<String, dynamic>;
    final previousSignature = _matchSignature(match);
    final winner = match['winningTeamId'];
    if (winner != null) return match;

    final alVerState = match['alVerState']?.toString();
    if (alVerState == 'awaitingDecision') {
      final teamId = match['alVerTeamId'] as int?;
      final playerId = _firstHumanPlayerForTeam(match, teamId);
      clientsByPlayerId[playerId]!.send(MultiplayerMessage(
        type: MultiplayerMessageType.chooseAlVerDecision,
        roomId: roomId,
        playerId: playerId,
        payload: {'play': true},
      ));
      snapshot = await clients[0].expectChangedMatchSnapshot(previousSignature);
      continue;
    }

    if (match['pendingTrucoValue'] != null) {
      final responseTeamId = (match['trucoCallerTeamId'] as int?) == 1 ? 2 : 1;
      final playerId = _firstHumanPlayerForTeam(match, responseTeamId);
      clientsByPlayerId[playerId]!.send(MultiplayerMessage(
        type: MultiplayerMessageType.acceptTruco,
        roomId: roomId,
        playerId: playerId,
      ));
      snapshot = await clients[0].expectChangedMatchSnapshot(previousSignature);
      continue;
    }

    if (match['handFinished'] == true) {
      clients[0].send(MultiplayerMessage(
        type: MultiplayerMessageType.newHand,
        roomId: roomId,
        playerId: playerIds.first,
      ));
      snapshot = await clients[0].expectChangedMatchSnapshot(previousSignature);
      continue;
    }

    if (match['isRoundAwaitingContinue'] == true) {
      clients[0].send(MultiplayerMessage(
        type: MultiplayerMessageType.continueRound,
        roomId: roomId,
        playerId: playerIds.first,
      ));
      snapshot = await clients[0].expectChangedMatchSnapshot(previousSignature);
      continue;
    }

    final currentPlayerId = match['currentPlayerId'] as String;
    final hands = match['hands'] as Map;
    final hand = hands[currentPlayerId] as List<dynamic>;
    expect(hand, isNotEmpty, reason: 'Current player must have a card.');
    final card = Map<String, dynamic>.from(hand.first as Map);
    clientsByPlayerId[currentPlayerId]!.send(MultiplayerMessage(
      type: MultiplayerMessageType.playCard,
      roomId: roomId,
      playerId: currentPlayerId,
      payload: {'card': card},
    ));
    snapshot = await clients[0].expectChangedMatchSnapshot(previousSignature);
  }

  final match = snapshot['match'] as Map<String, dynamic>;
  if (requireFinish) {
    fail('Simulated match did not finish before the safety limit.');
  }
  return match;
}

String _matchSignature(Map<String, dynamic> match) {
  final hands = match['hands'] as Map? ?? const {};
  final handSizes = [
    for (final entry in hands.entries)
      '${entry.key}:${(entry.value as List).length}',
  ]..sort();
  final score = match['score'] as Map? ?? const {};
  return [
    match['handSequence'],
    match['currentPlayerId'],
    match['handFinished'],
    match['isRoundAwaitingContinue'],
    match['winningTeamId'],
    match['alVerState'],
    match['alVerTeamId'],
    match['pendingTrucoValue'],
    match['trucoCallerTeamId'],
    match['playedCards'] is List ? (match['playedCards'] as List).length : 0,
    score['1'],
    score['2'],
    ...handSizes,
  ].join('|');
}

String _firstHumanPlayerForTeam(Map<String, dynamic> match, int? teamId) {
  final players = match['players'] as List<dynamic>;
  final player = players.cast<Map>().firstWhere(
        (player) =>
            player['teamId'] == teamId && player['aiDifficulty'] == null,
      );
  return player['playerId'] as String;
}

Future<String> _createTeam(
  _TestClient client, {
  required String playerId,
  required String sessionToken,
  required String teammateUsername,
  required String teamName,
}) async {
  client.send(MultiplayerMessage(
    type: MultiplayerMessageType.createTeam,
    playerId: playerId,
    payload: {
      'sessionToken': sessionToken,
      'teammateUsername': teammateUsername,
      'teamName': teamName,
    },
  ));
  final payload = await client.expectType(MultiplayerMessageType.teams);
  final teams = payload['teams'] as List<dynamic>;
  final team = teams.cast<Map>().firstWhere(
        (entry) => entry['teamName'] == teamName,
      );
  return team['pairId'] as String;
}

Future<void> _selectTeam(
  _TestClient client, {
  required String roomId,
  required String playerId,
  required String sessionToken,
  required String pairId,
}) async {
  client.send(MultiplayerMessage(
    type: MultiplayerMessageType.selectTeam,
    roomId: roomId,
    playerId: playerId,
    payload: {
      'sessionToken': sessionToken,
      'pairId': pairId,
    },
  ));
  await client.expectRoomSeat(playerId, pairId);
}

Future<void> _selectTeamExpectError(
  _TestClient client, {
  required String roomId,
  required String playerId,
  required String sessionToken,
  required String pairId,
  required String code,
}) async {
  client.send(MultiplayerMessage(
    type: MultiplayerMessageType.selectTeam,
    roomId: roomId,
    playerId: playerId,
    payload: {
      'sessionToken': sessionToken,
      'pairId': pairId,
    },
  ));
  final error = await client.expectType(MultiplayerMessageType.error);
  expect(error['code'], code);
}

class _TestClient {
  final WebSocket _socket;
  final StreamController<MultiplayerMessage> _messages =
      StreamController<MultiplayerMessage>.broadcast();
  bool _closed = false;

  _TestClient._(this._socket) {
    _socket.listen((event) {
      if (_closed) return;
      _messages.add(
        MultiplayerMessage.decode(event is String ? event : utf8.decode(event)),
      );
    });
  }

  static Future<_TestClient> connect(int port) async {
    final socket = await WebSocket.connect('ws://127.0.0.1:$port/');
    return _TestClient._(socket);
  }

  void send(MultiplayerMessage message) {
    _socket.add(message.encode());
  }

  Future<Map<String, dynamic>> expectType(
    MultiplayerMessageType type, {
    Duration timeout = const Duration(seconds: 3),
  }) async {
    final message = await _messages.stream
        .firstWhere((message) => message.type == type)
        .timeout(timeout);
    return message.payload ?? const {};
  }

  Future<Map<String, dynamic>> expectRoomWithSeats(int seats) async {
    final message = await _messages.stream.firstWhere((message) {
      if (message.type != MultiplayerMessageType.roomSnapshot) return false;
      final payload = message.payload;
      return (payload?['seats'] as List<dynamic>? ?? const []).length == seats;
    }).timeout(const Duration(seconds: 3));
    return message.payload ?? const {};
  }

  Future<void> expectRoomSeat(String playerId, String pairId) async {
    await _messages.stream.firstWhere((message) {
      if (message.type != MultiplayerMessageType.roomSnapshot) return false;
      final seats = message.payload?['seats'] as List<dynamic>? ?? const [];
      return seats.any(
        (seat) =>
            seat is Map &&
            seat['playerId'] == playerId &&
            seat['pairId'] == pairId,
      );
    }).timeout(const Duration(seconds: 3));
  }

  Future<Map<String, dynamic>> expectMatchSnapshot() async {
    final message = await _messages.stream.firstWhere((message) {
      if (message.type != MultiplayerMessageType.roomSnapshot) return false;
      return message.payload?['match'] is Map;
    }).timeout(const Duration(seconds: 3));
    return message.payload ?? const {};
  }

  Future<Map<String, dynamic>> expectChangedMatchSnapshot(
    String previousSignature,
  ) async {
    final message = await _messages.stream.firstWhere((message) {
      if (message.type != MultiplayerMessageType.roomSnapshot) return false;
      final payload = message.payload;
      final match = payload?['match'];
      if (match is! Map) return false;
      return _matchSignature(Map<String, dynamic>.from(match)) !=
          previousSignature;
    }).timeout(const Duration(seconds: 3));
    return message.payload ?? const {};
  }

  Future<void> close() async {
    _closed = true;
    await _socket.close();
    await _messages.close();
  }
}

class _StartedMatchSetup {
  final Directory tempDir;
  final ZapitiServer server;
  final List<_TestClient> clients;
  final String roomId;
  final Map<String, dynamic> initialSnapshot;

  const _StartedMatchSetup({
    required this.tempDir,
    required this.server,
    required this.clients,
    required this.roomId,
    required this.initialSnapshot,
  });

  Future<void> close() async {
    for (final client in clients) {
      await client.close();
    }
    await server.stop();
    tempDir.deleteSync(recursive: true);
  }
}
