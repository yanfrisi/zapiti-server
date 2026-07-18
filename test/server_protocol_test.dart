import 'package:test/test.dart';
import 'package:zapiti_server/server_protocol.dart';

void main() {
  group('MultiplayerMessage', () {
    test('serialize and deserialize create_room message', () {
      final message = MultiplayerMessage(
        type: MultiplayerMessageType.createRoom,
        payload: {'name': 'Juan'},
      );

      final json = message.toJson();
      expect(json['type'], 'create_room');
      expect(json['payload']['name'], 'Juan');

      final decoded = MultiplayerMessage.fromJson(json);
      expect(decoded.type, MultiplayerMessageType.createRoom);
      expect(decoded.payload!['name'], 'Juan');
    });

    test('encode and decode message to string', () {
      final message = MultiplayerMessage(
        type: MultiplayerMessageType.joinRoom,
        roomId: 'A7K2',
        payload: {'name': 'Ana'},
      );

      final encoded = message.encode();
      final decoded = MultiplayerMessage.decode(encoded);

      expect(decoded.type, MultiplayerMessageType.joinRoom);
      expect(decoded.roomId, 'A7K2');
      expect(decoded.payload!['name'], 'Ana');
    });

    test('handle error message type', () {
      final message = MultiplayerMessage(
        type: MultiplayerMessageType.error,
        payload: {
          'code': 'room_not_found',
          'message': 'Room does not exist',
        },
      );

      final json = message.toJson();
      expect(json['type'], 'error');
      expect(json['payload']['code'], 'room_not_found');
    });

    test('throw on unknown message type', () {
      final json = {'type': 'unknown_type'};
      expect(
        () => MultiplayerMessage.fromJson(json),
        throwsFormatException,
      );
    });

    test('throw on invalid JSON', () {
      expect(
        () => MultiplayerMessage.decode('invalid json {'),
        throwsFormatException,
      );
    });

    test('serialize room_snapshot with seats', () {
      final snapshot = MultiplayerRoomSnapshot(
        roomId: 'A7K2',
        seats: [
          MultiplayerSeat(
            playerId: 'p1',
            name: 'Juan',
            seatIndex: 0,
            teamId: 1,
            characterId: 'p2',
          ),
          MultiplayerSeat(
            playerId: 'p2',
            name: 'Ana',
            seatIndex: 1,
            teamId: 2,
            ready: true,
          ),
        ],
        phase: 'lobby',
        createdAt: 1710000000000,
      );

      final json = snapshot.toJson();
      expect(json['roomId'], 'A7K2');
      expect(json['phase'], 'lobby');
      expect(json['seats'].length, 2);
      expect(json['seats'][0]['name'], 'Juan');
      expect(json['seats'][0]['teamId'], 1);
      expect(json['seats'][0]['characterId'], 'p2');
      expect(json['seats'][1]['ready'], true);
    });

    test('serialize choose_al_ver_decision message', () {
      final message = MultiplayerMessage(
        type: MultiplayerMessageType.chooseAlVerDecision,
        roomId: 'A7K2',
        playerId: 'p1',
        payload: {'play': true},
      );

      final json = message.toJson();
      expect(json['type'], 'choose_al_ver_decision');
      expect(json['payload']['play'], true);

      final decoded = MultiplayerMessage.fromJson(json);
      expect(decoded.type, MultiplayerMessageType.chooseAlVerDecision);
      expect(decoded.payload!['play'], true);
    });

    test('deserialize room_snapshot', () {
      final json = {
        'roomId': 'A7K2',
        'phase': 'lobby',
        'createdAt': 1710000000000,
        'seats': [
          {
            'playerId': 'p1',
            'name': 'Juan',
            'seatIndex': 0,
            'teamId': 1,
            'ready': false,
            'connected': true,
            'characterId': 'p4',
          },
        ],
      };

      final snapshot = MultiplayerRoomSnapshot.fromJson(json);
      expect(snapshot.roomId, 'A7K2');
      expect(snapshot.seats.length, 1);
      expect(snapshot.seats[0].name, 'Juan');
      expect(snapshot.seats[0].teamId, 1);
      expect(snapshot.seats[0].characterId, 'p4');
    });

    test('encode and decode select_character message', () {
      final message = MultiplayerMessage(
        type: MultiplayerMessageType.selectCharacter,
        roomId: 'A7K2',
        playerId: 'p1',
        payload: {'characterId': 'p3'},
      );

      final decoded = MultiplayerMessage.decode(message.encode());
      expect(decoded.type, MultiplayerMessageType.selectCharacter);
      expect(decoded.payload!['characterId'], 'p3');
    });

    test('encode and decode request_signal message', () {
      final message = MultiplayerMessage(
        type: MultiplayerMessageType.requestSignal,
        roomId: 'A7K2',
        playerId: 'p1',
        payload: {'requesterName': 'Juan'},
      );

      final decoded = MultiplayerMessage.decode(message.encode());
      expect(decoded.type, MultiplayerMessageType.requestSignal);
      expect(decoded.payload!['requesterName'], 'Juan');
    });

    test('encode and decode ranking message', () {
      final message = MultiplayerMessage(
        type: MultiplayerMessageType.ranking,
        payload: {
          'pairs': [
            {'teamName': 'Juan / Ana', 'played': 2, 'wins': 1},
          ],
        },
      );

      final decoded = MultiplayerMessage.decode(message.encode());
      expect(decoded.type, MultiplayerMessageType.ranking);
      expect(decoded.payload!['pairs'], isA<List<dynamic>>());
    });

    test('encode and decode teams message', () {
      final message = MultiplayerMessage(
        type: MultiplayerMessageType.teams,
        playerId: 'player_1',
        payload: {
          'teams': [
            {
              'pairId': 'player_1+player_2',
              'teamName': 'Los Bravos',
              'teammateNames': ['Ana'],
            },
          ],
        },
      );

      final decoded = MultiplayerMessage.decode(message.encode());
      expect(decoded.type, MultiplayerMessageType.teams);
      expect(decoded.payload!['teams'], isA<List<dynamic>>());
    });

    test('encode and decode profile messages', () {
      final update = MultiplayerMessage(
        type: MultiplayerMessageType.updateProfile,
        playerId: 'player_1',
        payload: {
          'username': 'juan',
          'name': 'Juan',
          'password': 'secreto123',
        },
      );
      final profile = MultiplayerMessage(
        type: MultiplayerMessageType.profile,
        playerId: 'player_1',
        payload: {
          'playerId': 'player_1',
          'username': 'juan',
          'name': 'Juan',
          'sessionToken': 'session_123',
          'teamName': 'Los Bravos',
        },
      );

      expect(
        MultiplayerMessage.decode(update.encode()).type,
        MultiplayerMessageType.updateProfile,
      );
      expect(
        MultiplayerMessage.decode(profile.encode()).type,
        MultiplayerMessageType.profile,
      );
      expect(
        MultiplayerMessage.decode(profile.encode()).payload!['teamName'],
        'Los Bravos',
      );
    });
  });

  group('MultiplayerSeat', () {
    test('create and serialize seat', () {
      final seat = MultiplayerSeat(
        playerId: 'p1',
        name: 'Juan',
        seatIndex: 0,
        teamId: 1,
        ready: false,
        connected: true,
        characterId: 'p1',
      );

      final json = seat.toJson();
      expect(json['playerId'], 'p1');
      expect(json['name'], 'Juan');
      expect(json['seatIndex'], 0);
      expect(json['characterId'], 'p1');
    });

    test('copyWith preserves values', () {
      final seat = MultiplayerSeat(
        playerId: 'p1',
        name: 'Juan',
        seatIndex: 0,
        teamId: 1,
        characterId: 'p1',
      );

      final updated = seat.copyWith(ready: true);
      expect(updated.ready, true);
      expect(updated.playerId, 'p1');
    });
  });
}
