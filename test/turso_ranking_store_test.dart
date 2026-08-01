import 'dart:io';

import 'package:libsql_dart/libsql_dart.dart';
import 'package:test/test.dart';
import 'package:zapiti_server/match_state.dart';
import 'package:zapiti_server/turso_ranking_store.dart';

void main() {
  final databaseUrl =
      (Platform.environment[TursoRankingStore.databaseUrlEnv] ?? '').trim();
  final authToken = (Platform.environment[TursoRankingStore.authTokenEnv] ?? '')
      .trim();
  final hasTursoEnvironment = databaseUrl.isNotEmpty && authToken.isNotEmpty;

  test(
    'TursoRankingStore persists profiles, teams, ranking, matches, and rollbacks',
    () async {
      final prefix = 'it_${DateTime.now().microsecondsSinceEpoch}';
      final juanId = '${prefix}_juan';
      final anaId = '${prefix}_ana';
      final rollbackId = '${prefix}_rollback';
      final juanUsername = '${prefix}_juan';
      final anaUsername = '${prefix}_ana';
      final rollbackUsername = '${prefix}_rollback';
      final pairId = '$anaId+$juanId';

      final store = await TursoRankingStore.open(
        databaseUrl: databaseUrl,
        authToken: authToken,
      );
      addTearDown(store.close);

      final client = LibsqlClient.remote(databaseUrl, authToken: authToken);
      await client.connect();
      addTearDown(client.dispose);
      addTearDown(() async {
        await client.execute(
          'DELETE FROM matches WHERE match_id LIKE ?',
          positional: ['${prefix}_%'],
        );
        await client.execute(
          'DELETE FROM pairs WHERE pair_id LIKE ?',
          positional: ['${prefix}_%'],
        );
        await client.execute(
          'DELETE FROM players WHERE player_id LIKE ?',
          positional: ['${prefix}_%'],
        );
        await client.execute(
          'DELETE FROM metadata WHERE key LIKE ?',
          positional: ['${prefix}_%'],
        );
      });

      final selectOne = await client.query('SELECT 1 AS ok');
      expect(selectOne, isNotEmpty);
      expect(selectOne.first['ok']?.toString(), '1');

      await _expectSchema(client);

      final juan = await store.upsertPlayerProfile(
        playerId: juanId,
        username: juanUsername,
        name: 'Juan',
        password: 'secreto123',
        teamName: 'Los Bravos',
      );
      expect(juan, isNotNull);
      final token = juan!['sessionToken'] as String;

      final updated = await store.updatePlayerProfileWithSession(
        playerId: juanId,
        name: 'Juan Fran',
        teamName: 'Los Finos',
        sessionToken: token,
      );
      expect(updated, isNotNull);
      expect(updated!['name'], 'Juan Fran');
      expect(updated['sessionToken'], token);

      final recovered = await store.recoverPlayerProfile(
        username: juanUsername,
        password: 'secreto123',
      );
      expect(recovered, isNotNull);
      final recoveredToken = recovered!['sessionToken'] as String;

      expect(
        await store.verifySessionToken(
          playerId: juanId,
          sessionToken: recoveredToken,
        ),
        isTrue,
      );
      expect(
        await store.verifySessionToken(
          playerId: juanId,
          sessionToken: 'token_malo',
        ),
        isFalse,
      );

      await store.upsertPlayerProfile(
        playerId: anaId,
        username: anaUsername,
        name: 'Ana',
        password: 'secreto456',
      );

      final createdTeam = await store.createTeamForPlayer(
        playerId: juanId,
        sessionToken: recoveredToken,
        teammateUsername: anaUsername,
        teamName: 'Equipo Turso',
      );
      expect(createdTeam, isNotNull);
      expect(createdTeam!['pairId'], pairId);
      expect(createdTeam['teammateNames'], ['Ana']);

      final listedTeams = await store.teamsForPlayer(
        playerId: juanId,
        sessionToken: recoveredToken,
      );
      expect(listedTeams.single['pairId'], pairId);

      final renamedTeam = await store.updateTeamName(
        playerId: juanId,
        sessionToken: recoveredToken,
        pairId: pairId,
        teamName: 'Equipo Renombrado',
      );
      expect(renamedTeam, isNotNull);
      expect(renamedTeam!['teamName'], 'Equipo Renombrado');

      final selectedTeam = await store.teamForPlayer(
        playerId: juanId,
        sessionToken: recoveredToken,
        pairId: pairId,
      );
      expect(selectedTeam, isNotNull);
      expect(selectedTeam!['pairId'], pairId);

      final match = _finishedMatch(
        roomId: '${prefix}_room',
        seed: 42,
        playerOneId: juanId,
        playerTwoId: anaId,
        pairId: pairId,
      );
      await store.recordFinishedMatch(match);
      await store.recordFinishedMatch(match);

      final playerStats = await client.query(
        '''
        SELECT played, wins, losses, points_for, points_against
        FROM players
        WHERE player_id = ?
        ''',
        positional: [juanId],
      );
      expect(playerStats.single['played'], 1);
      expect(playerStats.single['wins'], 1);
      expect(playerStats.single['losses'], 0);
      expect(playerStats.single['points_for'], 30);
      expect(playerStats.single['points_against'], 12);

      final pairStats = await client.query(
        '''
        SELECT played, wins, losses, points_for, points_against
        FROM pairs
        WHERE pair_id = ?
        ''',
        positional: [pairId],
      );
      expect(pairStats.single['played'], 1);
      expect(pairStats.single['wins'], 1);
      expect(pairStats.single['losses'], 0);
      expect(pairStats.single['points_for'], 30);
      expect(pairStats.single['points_against'], 12);

      final matches = await client.query(
        'SELECT COUNT(*) AS total FROM matches WHERE match_id = ?',
        positional: ['${prefix}_room_42'],
      );
      expect(matches.single['total'], 1);

      final snapshot = await store.snapshot(limit: 1000);
      final snapshotPlayers = snapshot['players'] as List<dynamic>;
      final snapshotPairs = snapshot['pairs'] as List<dynamic>;
      final snapshotMatches = snapshot['matches'] as List<dynamic>;
      expect(
        snapshotPlayers.any(
          (player) => player is Map && player['playerId'] == juanId,
        ),
        isTrue,
      );
      expect(
        snapshotPairs.any((pair) => pair is Map && pair['pairId'] == pairId),
        isTrue,
      );
      expect(
        snapshotMatches.any(
          (match) => match is Map && match['matchId'] == '${prefix}_room_42',
        ),
        isTrue,
      );

      final archivedTeam = await store.archiveTeam(
        playerId: juanId,
        sessionToken: recoveredToken,
        pairId: pairId,
      );
      expect(archivedTeam, isNotNull);
      expect(archivedTeam!['archivedAt'], isNot(0));
      expect(
        await store.teamForPlayer(
          playerId: juanId,
          sessionToken: recoveredToken,
          pairId: pairId,
        ),
        isNull,
      );

      await store.upsertPlayerProfile(
        playerId: rollbackId,
        username: rollbackUsername,
        name: 'Rollback',
        password: 'secreto789',
      );
      await _expectRollbackOnFailedTransaction(
        client,
        key: '${prefix}_rollback_marker',
        conflictingUsername: rollbackUsername,
      );
    },
    skip: hasTursoEnvironment
        ? false
        : 'Set TURSO_DATABASE_URL and TURSO_AUTH_TOKEN to run this test.',
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

Future<void> _expectSchema(LibsqlClient client) async {
  final tables = await client.query('''
    SELECT name
    FROM sqlite_master
    WHERE type = 'table' AND name IN ('metadata', 'players', 'pairs', 'matches')
    ORDER BY name
    ''');
  expect(tables.map((row) => row['name']).toSet(), {
    'matches',
    'metadata',
    'pairs',
    'players',
  });

  final indexes = await client.query('''
    SELECT name, sql
    FROM sqlite_master
    WHERE type = 'index' AND name = 'idx_players_username_unique'
    LIMIT 1
    ''');
  expect(indexes, hasLength(1));
  final indexSql = indexes.single['sql']?.toString() ?? '';
  expect(indexSql, contains('idx_players_username_unique'));
  expect(indexSql, contains('ON players(username)'));
  expect(indexSql, contains("WHERE username <> ''"));
}

Future<void> _expectRollbackOnFailedTransaction(
  LibsqlClient client, {
  required String key,
  required String conflictingUsername,
}) async {
  final tx = await client.transaction(
    behavior: LibsqlTransactionBehavior.immediate,
  );
  try {
    await tx.execute(
      'INSERT INTO metadata (key, value) VALUES (?, ?)',
      positional: [key, 'should_rollback'],
    );
    await tx.execute(
      '''
      INSERT INTO players (
        player_id, name, team_name, username
      ) VALUES (?, ?, ?, ?)
      ''',
      positional: ['${key}_player', 'Should Rollback', '', conflictingUsername],
    );
    await tx.commit();
    fail('Expected the transaction to fail.');
  } catch (_) {
    await tx.rollback();
  }

  final marker = await client.query(
    'SELECT value FROM metadata WHERE key = ?',
    positional: [key],
  );
  expect(marker, isEmpty);
}

MatchState _finishedMatch({
  required String roomId,
  required int seed,
  required String playerOneId,
  required String playerTwoId,
  required String pairId,
}) {
  final match = MatchState.start(
    roomId: roomId,
    createdAt: 1710000000000,
    seed: seed,
    players: [
      MatchPlayer(
        playerId: playerOneId,
        name: 'Juan Fran',
        teamId: 1,
        connectionId: 'c1',
        pairId: pairId,
        teamName: 'Equipo Renombrado',
        characterId: 'p1',
      ),
      const MatchPlayer(
        playerId: 'bot_1',
        name: 'Bot 1',
        teamId: 2,
        characterId: 'p2',
      ),
      MatchPlayer(
        playerId: playerTwoId,
        name: 'Ana',
        teamId: 1,
        connectionId: 'c2',
        pairId: pairId,
        teamName: 'Equipo Renombrado',
        characterId: 'p3',
      ),
      const MatchPlayer(
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
  return match;
}
