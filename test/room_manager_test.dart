import 'package:test/test.dart';
import 'package:zapiti_server/room_manager.dart';

void main() {
  group('RoomManager', () {
    late RoomManager manager;

    setUp(() {
      manager = RoomManager();
    });

    test('create room with player', () {
      final room = manager.createRoom('Juan', 'p1', 'conn1');

      expect(room.roomId, isNotNull);
      expect(room.roomId.length, 4);
      expect(room.seats.length, 1);
      expect(room.seats[0].name, 'Juan');
      expect(room.seats[0].seatIndex, 0);
    });

    test('join room successfully', () {
      final room1 = manager.createRoom('Juan', 'p1', 'conn1');
      final room2 = manager.joinRoom(room1.roomId, 'Ana', 'p2', 'conn2');

      expect(room2, isNotNull);
      expect(room2!.seats.length, 2);
      expect(room2.seats[1].name, 'Ana');
      expect(room2.seats[1].seatIndex, 1);
    });

    test('normalizes player names', () {
      final room = manager.createRoom(
        '  Juan   Fran con nombre largo  ',
        'p1',
        'conn1',
      );

      expect(room.seats[0].name, 'Juan Fran con nomb');
    });

    test('rejects blank player names', () {
      expect(
        () => manager.createRoom('   ', 'p1', 'conn1'),
        throwsStateError,
      );
    });

    test('reject join on non-existent room', () {
      final result = manager.joinRoom('FAKE', 'Ana', 'p2', 'conn2');
      expect(result, isNull);
    });

    test('reject join on full room', () {
      final room = manager.createRoom('P1', 'p1', 'conn1');
      manager.joinRoom(room.roomId, 'P2', 'p2', 'conn2');
      manager.joinRoom(room.roomId, 'P3', 'p3', 'conn3');
      manager.joinRoom(room.roomId, 'P4', 'p4', 'conn4');

      expect(
        () => manager.joinRoom(room.roomId, 'P5', 'p5', 'conn5'),
        throwsStateError,
      );
    });

    test('leave room removes player', () {
      final room = manager.createRoom('Juan', 'p1', 'conn1');
      manager.joinRoom(room.roomId, 'Ana', 'p2', 'conn2');

      manager.leaveRoom(room.roomId, 'p1');

      final updated = manager.getRoom(room.roomId);
      expect(updated!.seats.length, 1);
      expect(updated.seats[0].playerId, 'p2');
    });

    test('empty room is deleted', () {
      final room = manager.createRoom('Juan', 'p1', 'conn1');
      final roomId = room.roomId;

      manager.leaveRoom(roomId, 'p1');

      expect(manager.getRoom(roomId), isNull);
    });

    test('get room returns correct room', () {
      final room1 = manager.createRoom('Juan', 'p1', 'conn1');
      final room2 = manager.createRoom('Ana', 'p2', 'conn2');

      expect(manager.getRoom(room1.roomId), room1);
      expect(manager.getRoom(room2.roomId), room2);
    });

    test('multiple rooms exist independently', () {
      final room1 = manager.createRoom('Juan', 'p1', 'conn1');
      final room2 = manager.createRoom('Ana', 'p2', 'conn2');

      manager.joinRoom(room1.roomId, 'Carlos', 'p3', 'conn3');

      expect(manager.getRoom(room1.roomId)!.seats.length, 2);
      expect(manager.getRoom(room2.roomId)!.seats.length, 1);
    });

    test('handle disconnection removes player from room', () {
      final room = manager.createRoom('Juan', 'p1', 'conn1');
      manager.joinRoom(room.roomId, 'Ana', 'p2', 'conn2');

      final affected = manager.handleDisconnection('conn1');

      expect(affected.contains(room.roomId), true);
      final updated = manager.getRoom(room.roomId);
      expect(updated!.seats.length, 1);
      expect(updated.seats[0].playerId, 'p2');
    });

    test('disconnection removes empty room', () {
      final room = manager.createRoom('Juan', 'p1', 'conn1');
      final roomId = room.roomId;

      manager.handleDisconnection('conn1');

      expect(manager.getRoom(roomId), isNull);
    });

    test('disconnection from non-existent connection does nothing', () {
      final room = manager.createRoom('Juan', 'p1', 'conn1');

      final affected = manager.handleDisconnection('nonexistent');

      expect(affected.isEmpty, true);
      expect(manager.getRoom(room.roomId), isNotNull);
    });

    test('player seat indices are assigned correctly', () {
      final room = manager.createRoom('P1', 'p1', 'conn1');
      manager.joinRoom(room.roomId, 'P2', 'p2', 'conn2');
      manager.joinRoom(room.roomId, 'P3', 'p3', 'conn3');
      manager.joinRoom(room.roomId, 'P4', 'p4', 'conn4');

      final updated = manager.getRoom(room.roomId)!;
      expect(updated.seats[0].seatIndex, 0);
      expect(updated.seats[1].seatIndex, 1);
      expect(updated.seats[2].seatIndex, 2);
      expect(updated.seats[3].seatIndex, 3);
    });
  });
}
