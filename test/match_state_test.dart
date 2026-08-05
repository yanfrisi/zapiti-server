import 'package:test/test.dart';
import 'package:zapiti_server/match_state.dart';

void main() {
  group('MatchState rotacion de salida', () {
    test('la primera mano deja preparado al siguiente jugador en mesa', () {
      final match = _makeMatch();

      expect(match.currentPlayerId, 'p1');
      expect(match.toPublicJson()['leadPlayerId'], 'p1');
      expect(match.toPublicJson()['nextLeadPlayerId'], 'p2');
    });
  });
  group('MatchState jerarquia', () {
    test('7 de oros va por encima de los 3', () {
      expect(
        ZapitiRules.strength(const SpanishCard(value: 7, suit: Suit.oros)),
        greaterThan(
          ZapitiRules.strength(const SpanishCard(value: 3, suit: Suit.bastos)),
        ),
      );
    });
  });

  group('MatchState al ver', () {
    test('detecta al ver al empezar con 29 chinos', () {
      final match = _makeMatch();
      match.score[1] = 29;

      match.startNewHand(fixedHands: _fixedHands());

      expect(match.alVerState, AlVerState.awaitingDecision);
      expect(match.alVerTeamId, 1);
      expect(match.toPublicJson()['alVerTeamIds'], [1]);
    });

    test('al ver puede conceder la mano y sumar 2 al rival', () {
      final match = _makeMatch();
      match.score[1] = 29;
      match.startNewHand(fixedHands: _fixedHands());

      match.chooseAlVerDecision(teamId: 1, play: false);

      expect(match.alVerState, AlVerState.conceded);
      expect(match.score[2], 2);
      expect(match.handFinished, isTrue);
    });

    test('al ver bloquea truco hasta decidir', () {
      final match = _makeMatch();
      match.score[1] = 29;
      match.startNewHand(fixedHands: _fixedHands());

      expect(() => match.callTruco('p1', value: 1), throwsStateError);
    });

    test('si el equipo al ver juega, la mano sigue', () {
      final match = _makeMatch();
      match.score[1] = 29;
      match.startNewHand(fixedHands: _fixedHands());

      match.chooseAlVerDecision(teamId: 1, play: true);

      expect(match.alVerState, AlVerState.playing);
      expect(match.handFinished, isFalse);
      expect(
        () => match.playCard('p1', match.hands['p1']!.first),
        returnsNormally,
      );
    });
  });

  group('MatchState bot truco', () {
    test('equipo bot flojo pasa una subida cara', () {
      final match = _makeMatch();
      match.startNewHand(fixedHands: _weakBotHands());
      match.callTruco('p1', value: 9);

      final decision = match.chooseBotTrucoDecision(2);

      expect(decision.action, BotTrucoAction.pass);
      expect(decision.player.teamId, 2);
    });

    test('equipo bot fuerte responde el truco', () {
      final match = _makeMatch();
      match.startNewHand(fixedHands: _strongBotHands());
      match.callTruco('p1', value: 9);

      final decision = match.chooseBotTrucoDecision(2);

      expect(decision.action, isNot(BotTrucoAction.pass));
      expect(decision.player.teamId, 2);
    });
  });

  group('MatchState truco', () {
    test('tras aceptar el mismo equipo no puede volver a subir enseguida', () {
      final match = _makeMatch();

      match.callTruco('p1', value: 3);
      match.acceptTruco(teamId: 2);

      expect(match.nextTrucoValueForPlayer('p1'), isNull);
    });

    test(
      'tras aceptar el rival puede subir al siguiente nivel en su turno',
      () {
        final match = _makeMatch();
        match.startNewHand(fixedHands: _fixedHands());

        match.callTruco('p1', value: 3);
        match.acceptTruco(teamId: 2);
        match.playCard('p1', match.hands['p1']!.first);

        expect(match.currentPlayerId, 'p2');
        expect(match.nextTrucoValueForPlayer('p2'), 6);

        match.callTruco('p2', value: 6);

        expect(match.pendingTrucoValue, 6);
        expect(match.trucoCallerTeamId, 2);
      },
    );
    test('rechazar truco mantiene la salida del siguiente jugador en mesa', () {
      final match = _makeMatch();
      match.startNewHand(fixedHands: _fixedHands());
      expect(match.currentPlayerId, 'p2');

      match.callTruco('p2', value: 3);
      match.passTruco(passingTeamId: 1);

      expect(match.score[2], 1);
      expect(match.handFinished, isTrue);

      match.startNewHand(fixedHands: _fixedHands());

      expect(match.currentPlayerId, 'p3');
    });
  });

  group('MatchState pasar mano', () {
    test('permite pasar mano al companero al inicio de la mano', () {
      final match = _makeMatch(allowPassHand: true);
      match.startNewHand(fixedHands: _fixedHands());

      match.passHand(fromPlayerId: 'p1', toPlayerId: 'p3');

      expect(match.currentPlayerId, 'p3');
      expect(match.passedHandState.originalLeaderId, 'p1');
      expect(match.passedHandState.passedToPlayerId, 'p3');
      expect(match.toPublicJson()['allowPassHand'], isTrue);
      expect(match.toPublicJson()['passedHandState'], {
        'originalLeaderId': 'p1',
        'passedToPlayerId': 'p3',
      });
    });

    test('bloquea pasar mano despues de jugar una carta', () {
      final match = _makeMatch(allowPassHand: true);
      match.startNewHand(fixedHands: _fixedHands());
      match.playCard('p1', match.hands['p1']!.first);

      expect(
        () => match.passHand(fromPlayerId: 'p1', toPlayerId: 'p3'),
        throwsStateError,
      );
    });
  });
  group('MatchState turn timeout', () {
    test('juega automaticamente la carta mas baja al vencer el turno', () {
      final match = _makeMatch();
      match.startNewHand(fixedHands: _fixedHands());
      match.turnDeadlineAt = 1000;

      final playedCard = match.playTimeoutCard(now: 1001);

      expect(playedCard.player.playerId, 'p1');
      expect(playedCard.card, SpanishCard(value: 5, suit: Suit.copas));
      expect(match.playedCards.length, 1);
      expect(match.currentPlayerId, 'p2');
      expect(match.turnSecondsRemaining(now: 1001), 30);
    });
  });
}

MatchState _makeMatch({bool allowPassHand = false}) {
  return MatchState.start(
    roomId: 'A7K2',
    createdAt: 1710000000000,
    seed: 42,
    allowPassHand: allowPassHand,
    players: [
      const MatchPlayer(
        playerId: 'p1',
        name: 'Juan',
        teamId: 1,
        connectionId: 'c1',
        characterId: 'p1',
      ),
      const MatchPlayer(
        playerId: 'p2',
        name: 'Bot 2',
        teamId: 2,
        characterId: 'p2',
      ),
      const MatchPlayer(
        playerId: 'p3',
        name: 'Ana',
        teamId: 1,
        connectionId: 'c3',
        characterId: 'p3',
      ),
      const MatchPlayer(
        playerId: 'p4',
        name: 'Bot 4',
        teamId: 2,
        characterId: 'p4',
      ),
    ],
  );
}

Map<String, List<SpanishCard>> _fixedHands() {
  return {
    'p1': const [
      SpanishCard(value: 4, suit: Suit.bastos),
      SpanishCard(value: 3, suit: Suit.oros),
      SpanishCard(value: 5, suit: Suit.copas),
    ],
    'p2': const [
      SpanishCard(value: 12, suit: Suit.oros),
      SpanishCard(value: 11, suit: Suit.oros),
      SpanishCard(value: 5, suit: Suit.oros),
    ],
    'p3': const [
      SpanishCard(value: 10, suit: Suit.bastos),
      SpanishCard(value: 10, suit: Suit.copas),
      SpanishCard(value: 6, suit: Suit.bastos),
    ],
    'p4': const [
      SpanishCard(value: 4, suit: Suit.espadas),
      SpanishCard(value: 5, suit: Suit.espadas),
      SpanishCard(value: 6, suit: Suit.espadas),
    ],
  };
}

Map<String, List<SpanishCard>> _weakBotHands() {
  return {
    'p1': const [
      SpanishCard(value: 4, suit: Suit.bastos),
      SpanishCard(value: 7, suit: Suit.copas),
      SpanishCard(value: 3, suit: Suit.oros),
    ],
    'p2': const [
      SpanishCard(value: 4, suit: Suit.espadas),
      SpanishCard(value: 5, suit: Suit.oros),
      SpanishCard(value: 6, suit: Suit.oros),
    ],
    'p3': const [
      SpanishCard(value: 7, suit: Suit.oros),
      SpanishCard(value: 1, suit: Suit.espadas),
      SpanishCard(value: 2, suit: Suit.bastos),
    ],
    'p4': const [
      SpanishCard(value: 4, suit: Suit.copas),
      SpanishCard(value: 5, suit: Suit.copas),
      SpanishCard(value: 6, suit: Suit.copas),
    ],
  };
}

Map<String, List<SpanishCard>> _strongBotHands() {
  return {
    'p1': const [
      SpanishCard(value: 4, suit: Suit.espadas),
      SpanishCard(value: 5, suit: Suit.oros),
      SpanishCard(value: 6, suit: Suit.oros),
    ],
    'p2': const [
      SpanishCard(value: 4, suit: Suit.bastos),
      SpanishCard(value: 7, suit: Suit.copas),
      SpanishCard(value: 7, suit: Suit.oros),
    ],
    'p3': const [
      SpanishCard(value: 4, suit: Suit.copas),
      SpanishCard(value: 5, suit: Suit.copas),
      SpanishCard(value: 6, suit: Suit.copas),
    ],
    'p4': const [
      SpanishCard(value: 1, suit: Suit.espadas),
      SpanishCard(value: 3, suit: Suit.bastos),
      SpanishCard(value: 2, suit: Suit.oros),
    ],
  };
}
