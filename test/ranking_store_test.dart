import 'dart:io';

import 'package:test/test.dart';
import 'package:zapiti_server/match_state.dart';
import 'package:zapiti_server/ranking_store.dart';

void main() {
  test('RankingStore registra jugadores y pareja humana', () {
    final tempDir = Directory.systemTemp.createTempSync('zapiti_ranking_test');
    addTearDown(() => tempDir.deleteSync(recursive: true));
    final store = RankingStore(path: '${tempDir.path}/ranking.json');
    final match = MatchState.start(
      roomId: 'A7K2',
      createdAt: 1710000000000,
      seed: 42,
      players: const [
        MatchPlayer(
          playerId: 'juan_profile',
          name: 'Juan',
          teamId: 1,
          connectionId: 'c1',
          characterId: 'p1',
        ),
        MatchPlayer(
          playerId: 'bot_1',
          name: 'Bot 1',
          teamId: 2,
          characterId: 'p2',
        ),
        MatchPlayer(
          playerId: 'ana_profile',
          name: 'Ana',
          teamId: 1,
          connectionId: 'c2',
          characterId: 'p3',
        ),
        MatchPlayer(
          playerId: 'bot_2',
          name: 'Bot 2',
          teamId: 2,
          characterId: 'p4',
        ),
      ],
    );

    match.score[1] = 30;
    match.score[2] = 12;
    match.winningTeamId = 1;
    store.recordFinishedMatch(match);

    final snapshot = store.snapshot();
    final pairs = snapshot['pairs'] as List<dynamic>;
    expect(pairs, isNotEmpty);
    expect(pairs.first['teamName'], contains('Juan'));
    expect(pairs.first['teamName'], contains('Ana'));
    expect(pairs.first['played'], 1);
  });
}
