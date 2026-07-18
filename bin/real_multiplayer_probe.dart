import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:zapiti_server/server_protocol.dart';

Future<void> main(List<String> args) async {
  final url = args.isNotEmpty ? args.first : 'wss://zapiti-server.onrender.com';
  final maxActions = args.length > 1 ? int.tryParse(args[1]) ?? 40 : 40;
  final runId = DateTime.now().millisecondsSinceEpoch.toString();
  final clients = <ProbeClient>[];
  final errors = <Map<String, dynamic>>[];

  try {
    print('Connecting to $url');
    for (var index = 0; index < 4; index++) {
      final client = await ProbeClient.connect(url, 'c$index');
      client.errors.stream.listen(errors.add);
      clients.add(client);
    }

    final profiles = <Map<String, dynamic>>[];
    for (var index = 0; index < clients.length; index++) {
      final username = 'probe_${runId}_$index';
      clients[index].send(MultiplayerMessage(
        type: MultiplayerMessageType.updateProfile,
        playerId: 'probe_${runId}_p$index',
        payload: {
          'username': username,
          'name': 'Probe $index',
          'password': 'secret$index$runId',
          'teamName': '',
        },
      ));
      final profile = await clients[index].expectType(
        MultiplayerMessageType.profile,
      );
      profiles.add({
        ...profile,
        'username': username,
        'playerId': 'probe_${runId}_p$index',
      });
      print('profile[$index]=${profile['playerId']} user=$username');
    }

    clients[0].send(MultiplayerMessage(
      type: MultiplayerMessageType.createRoom,
      playerId: profiles[0]['playerId'] as String,
      payload: {
        'username': profiles[0]['username'],
        'name': 'Probe 0',
        'sessionToken': profiles[0]['sessionToken'],
        'characterId': 'p1',
      },
    ));
    final created = await clients[0].expectType(
      MultiplayerMessageType.roomSnapshot,
    );
    final roomId = created['roomId'] as String;
    print('room=$roomId');

    for (var index = 1; index < clients.length; index++) {
      clients[index].send(MultiplayerMessage(
        type: MultiplayerMessageType.joinRoom,
        roomId: roomId,
        playerId: profiles[index]['playerId'] as String,
        payload: {
          'username': profiles[index]['username'],
          'name': 'Probe $index',
          'sessionToken': profiles[index]['sessionToken'],
          'characterId': 'p1',
        },
      ));
    }
    await Future.wait([
      for (final client in clients) client.expectRoomWithSeats(4),
    ]);
    print('all four seats joined');

    final team02 = await createTeam(
      clients[0],
      playerId: profiles[0]['playerId'] as String,
      sessionToken: profiles[0]['sessionToken'] as String,
      teammateUsername: profiles[2]['username'] as String,
      teamName: 'Probe 0-2 $runId',
    );
    final team13 = await createTeam(
      clients[1],
      playerId: profiles[1]['playerId'] as String,
      sessionToken: profiles[1]['sessionToken'] as String,
      teammateUsername: profiles[3]['username'] as String,
      teamName: 'Probe 1-3 $runId',
    );
    print('teams: $team02 / $team13');

    await selectTeam(clients[0], roomId, profiles[0], team02);
    await selectTeam(clients[2], roomId, profiles[2], team02);
    await selectTeam(clients[1], roomId, profiles[1], team13);
    await selectTeam(clients[3], roomId, profiles[3], team13);
    print('teams selected by all seats');

    for (var index = 0; index < clients.length; index++) {
      clients[index].send(MultiplayerMessage(
        type: MultiplayerMessageType.playerReady,
        roomId: roomId,
        playerId: profiles[index]['playerId'] as String,
        payload: {'ready': true},
      ));
    }
    final start = await clients[0].expectType(
      MultiplayerMessageType.startGame,
      timeout: const Duration(seconds: 8),
    );
    print('start_game players=${(start['players'] as List).length}');

    final lastMatch = await playSomeTurns(
      clients: clients,
      roomId: roomId,
      profiles: profiles,
      maxActions: maxActions,
    );
    print('played probe actions; score=${jsonEncode(lastMatch['score'])} '
        'handFinished=${lastMatch['handFinished']} '
        'winningTeamId=${lastMatch['winningTeamId']}');

    if (errors.isEmpty) {
      print('PROBE_OK');
    } else {
      print('PROBE_ERRORS ${jsonEncode(errors)}');
      exitCode = 2;
    }
  } catch (error, stackTrace) {
    print('PROBE_FAILED $error');
    print(stackTrace);
    if (errors.isNotEmpty) {
      print('PROBE_ERRORS ${jsonEncode(errors)}');
    }
    exitCode = 1;
  } finally {
    for (final client in clients) {
      await client.close();
    }
  }
}

Future<String> createTeam(
  ProbeClient client, {
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
    (team) {
      final names = team['teammateUsernames'];
      return names is List &&
          names.map((entry) => entry.toString()).contains(teammateUsername);
    },
    orElse: () => throw StateError('Created team not found in $teams'),
  );
  return team['pairId'] as String;
}

Future<void> selectTeam(
  ProbeClient client,
  String roomId,
  Map<String, dynamic> profile,
  String pairId,
) async {
  client.send(MultiplayerMessage(
    type: MultiplayerMessageType.selectTeam,
    roomId: roomId,
    playerId: profile['playerId'] as String,
    payload: {
      'sessionToken': profile['sessionToken'],
      'pairId': pairId,
    },
  ));
  await client.expectSeatPair(profile['playerId'] as String, pairId);
}

Future<Map<String, dynamic>> playSomeTurns({
  required List<ProbeClient> clients,
  required String roomId,
  required List<Map<String, dynamic>> profiles,
  required int maxActions,
}) async {
  final clientsByPlayerId = {
    for (var index = 0; index < profiles.length; index++)
      profiles[index]['playerId'] as String: clients[index],
  };
  var snapshot = await clients[0].expectMatchSnapshot();
  for (var action = 0; action < maxActions; action++) {
    final match = snapshot['match'] as Map<String, dynamic>;
    if (match['winningTeamId'] != null) return match;
    final signature = matchSignature(match);

    if (match['alVerState'] == 'awaitingDecision') {
      final playerId = firstHumanForTeam(match, match['alVerTeamId'] as int?);
      clientsByPlayerId[playerId]!.send(MultiplayerMessage(
        type: MultiplayerMessageType.chooseAlVerDecision,
        roomId: roomId,
        playerId: playerId,
        payload: {'play': true},
      ));
      snapshot = await clients[0].expectChangedMatchSnapshot(signature);
      continue;
    }

    if (match['pendingTrucoValue'] != null) {
      final caller = match['trucoCallerTeamId'] as int?;
      final responseTeam = caller == 1 ? 2 : 1;
      final playerId = firstHumanForTeam(match, responseTeam);
      clientsByPlayerId[playerId]!.send(MultiplayerMessage(
        type: MultiplayerMessageType.acceptTruco,
        roomId: roomId,
        playerId: playerId,
      ));
      snapshot = await clients[0].expectChangedMatchSnapshot(signature);
      continue;
    }

    if (match['handFinished'] == true) {
      final playerId = profiles.first['playerId'] as String;
      clients.first.send(MultiplayerMessage(
        type: MultiplayerMessageType.newHand,
        roomId: roomId,
        playerId: playerId,
      ));
      snapshot = await clients[0].expectChangedMatchSnapshot(signature);
      continue;
    }

    if (match['isRoundAwaitingContinue'] == true) {
      final playerId = profiles.first['playerId'] as String;
      clients.first.send(MultiplayerMessage(
        type: MultiplayerMessageType.continueRound,
        roomId: roomId,
        playerId: playerId,
      ));
      snapshot = await clients[0].expectChangedMatchSnapshot(signature);
      continue;
    }

    final playerId = match['currentPlayerId'] as String;
    final hands = match['hands'] as Map;
    final hand = hands[playerId] as List<dynamic>;
    if (hand.isEmpty) {
      throw StateError('current player $playerId has no cards');
    }
    clientsByPlayerId[playerId]!.send(MultiplayerMessage(
      type: MultiplayerMessageType.playCard,
      roomId: roomId,
      playerId: playerId,
      payload: {'card': Map<String, dynamic>.from(hand.first as Map)},
    ));
    snapshot = await clients[0].expectChangedMatchSnapshot(signature);
  }
  return snapshot['match'] as Map<String, dynamic>;
}

String firstHumanForTeam(Map<String, dynamic> match, int? teamId) {
  final players = match['players'] as List<dynamic>;
  final player = players.cast<Map>().firstWhere(
        (player) =>
            player['teamId'] == teamId && player['aiDifficulty'] == null,
      );
  return player['playerId'] as String;
}

String matchSignature(Map<String, dynamic> match) {
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

class ProbeClient {
  final String label;
  final WebSocket _socket;
  final StreamController<MultiplayerMessage> _messages =
      StreamController<MultiplayerMessage>.broadcast();
  final StreamController<Map<String, dynamic>> errors =
      StreamController<Map<String, dynamic>>.broadcast();
  bool _closed = false;

  ProbeClient._(this.label, this._socket) {
    _socket.listen((event) {
      if (_closed) return;
      final message = MultiplayerMessage.decode(
        event is String ? event : utf8.decode(event),
      );
      if (message.type == MultiplayerMessageType.error) {
        errors.add({
          'client': label,
          'roomId': message.roomId,
          'playerId': message.playerId,
          ...?message.payload,
        });
      }
      _messages.add(message);
    });
  }

  static Future<ProbeClient> connect(String url, String label) async {
    final socket = await WebSocket.connect(url);
    return ProbeClient._(label, socket);
  }

  void send(MultiplayerMessage message) => _socket.add(message.encode());

  Future<Map<String, dynamic>> expectType(
    MultiplayerMessageType type, {
    Duration timeout = const Duration(seconds: 5),
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
    }).timeout(const Duration(seconds: 8));
    return message.payload ?? const {};
  }

  Future<void> expectSeatPair(String playerId, String pairId) async {
    await _messages.stream.firstWhere((message) {
      if (message.type != MultiplayerMessageType.roomSnapshot) return false;
      final seats = message.payload?['seats'] as List<dynamic>? ?? const [];
      return seats.any(
        (seat) =>
            seat is Map &&
            seat['playerId'] == playerId &&
            seat['pairId'] == pairId,
      );
    }).timeout(const Duration(seconds: 8));
  }

  Future<Map<String, dynamic>> expectMatchSnapshot() async {
    final message = await _messages.stream
        .firstWhere((message) =>
            message.type == MultiplayerMessageType.roomSnapshot &&
            message.payload?['match'] is Map)
        .timeout(const Duration(seconds: 8));
    return message.payload ?? const {};
  }

  Future<Map<String, dynamic>> expectChangedMatchSnapshot(
    String previousSignature,
  ) async {
    final message = await _messages.stream.firstWhere((message) {
      if (message.type != MultiplayerMessageType.roomSnapshot) return false;
      final match = message.payload?['match'];
      return match is Map<String, dynamic> &&
          matchSignature(match) != previousSignature;
    }).timeout(const Duration(seconds: 8));
    return message.payload ?? const {};
  }

  Future<void> close() async {
    _closed = true;
    await _socket.close();
    await _messages.close();
    await errors.close();
  }
}
