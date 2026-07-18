import 'package:test/test.dart';
import 'package:zapiti_server/match_state.dart';

void main() {
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

      expect(
        () => match.callTruco('p1', value: 1),
        throwsStateError,
      );
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
}

MatchState _makeMatch() {
  return MatchState.start(
    roomId: 'A7K2',
    createdAt: 1710000000000,
    seed: 42,
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
