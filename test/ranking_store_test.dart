import 'dart:convert';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';
import 'package:zapiti_server/match_state.dart';
import 'package:zapiti_server/ranking_store.dart';

void main() {
  test('RankingStore recupera perfil por usuario y contrasena', () {
    final tempDir = Directory.systemTemp.createTempSync('zapiti_profile_test');
    addTearDown(() => tempDir.deleteSync(recursive: true));
    final dbPath = '${tempDir.path}/ranking.sqlite';
    final store = RankingStore(path: dbPath);

    store.upsertPlayerProfile(
      playerId: 'juan_profile',
      username: 'juan',
      name: 'Juan',
      password: 'secreto123',
      teamName: 'Los Bravos',
    );

    final profile = store.recoverPlayerProfile(
      username: 'juan',
      password: 'secreto123',
    );

    expect(profile, isNotNull);
    expect(profile!['playerId'], 'juan_profile');
    expect(profile['username'], 'juan');
    expect(profile['name'], 'Juan');
    expect(profile['pin'], isNull);
    expect(profile['sessionToken'], isA<String>());
    expect(profile['teamName'], 'Los Bravos');
    expect(
      store.verifySessionToken(
        playerId: 'juan_profile',
        sessionToken: profile['sessionToken'] as String,
      ),
      isTrue,
    );

    store.close();
    final db = sqlite3.open(dbPath);
    final storedPlayer = db.select(
      'SELECT * FROM players WHERE player_id = ?',
      ['juan_profile'],
    ).first;
    expect(storedPlayer['pin_salt'], isA<String>());
    expect(storedPlayer['pin_hash'], isA<String>());
    expect(storedPlayer['pin_hash_algorithm'], 'pbkdf2_sha256');
    expect(storedPlayer['session_token_hash'], isA<String>());
    expect(storedPlayer['session_token_hash'], isNot(profile['sessionToken']));
    db.dispose();
  });

  test('RankingStore actualiza perfil con token de sesion', () {
    final tempDir = Directory.systemTemp.createTempSync('zapiti_session_test');
    addTearDown(() => tempDir.deleteSync(recursive: true));
    final store = RankingStore(path: '${tempDir.path}/ranking.sqlite');
    addTearDown(store.close);

    final created = store.upsertPlayerProfile(
      playerId: 'juan_profile',
      username: 'juan',
      name: 'Juan',
      password: 'secreto123',
      teamName: 'Los Bravos',
    );
    final token = created!['sessionToken'] as String;

    final updated = store.updatePlayerProfileWithSession(
      playerId: 'juan_profile',
      name: 'Juan Fran',
      teamName: 'Los Finos',
      sessionToken: token,
    );
    final rejected = store.updatePlayerProfileWithSession(
      playerId: 'juan_profile',
      name: 'Intruso',
      sessionToken: 'token_malo',
    );
    final snapshot = store.snapshot();
    final player = (snapshot['players'] as List).first as Map;

    expect(updated, isNotNull);
    expect(updated!['name'], 'Juan Fran');
    expect(updated['sessionToken'], token);
    expect(rejected, isNull);
    expect(player['name'], 'Juan Fran');
    expect(player['sessionToken'], isNull);
  });

  test('RankingStore rechaza usuario existente con otra contrasena', () {
    final tempDir = Directory.systemTemp.createTempSync('zapiti_user_test');
    addTearDown(() => tempDir.deleteSync(recursive: true));
    final store = RankingStore(path: '${tempDir.path}/ranking.sqlite');
    addTearDown(store.close);

    store.upsertPlayerProfile(
      playerId: 'juan_profile',
      username: 'juan',
      name: 'Juan',
      password: 'secreto123',
    );

    final rejected = store.upsertPlayerProfile(
      playerId: 'otro_profile',
      username: 'juan',
      name: 'Otro',
      password: 'otraClave',
    );

    expect(rejected, isNull);
  });

  test('RankingStore gestiona equipos del jugador', () {
    final tempDir = Directory.systemTemp.createTempSync('zapiti_team_test');
    addTearDown(() => tempDir.deleteSync(recursive: true));
    final store = RankingStore(path: '${tempDir.path}/ranking.sqlite');
    addTearDown(store.close);

    final juan = store.upsertPlayerProfile(
      playerId: 'juan_profile',
      username: 'juan',
      name: 'Juan',
      password: 'secreto123',
    );
    store.upsertPlayerProfile(
      playerId: 'ana_profile',
      username: 'ana',
      name: 'Ana',
      password: 'secreto456',
    );
    final token = juan!['sessionToken'] as String;

    final created = store.createTeamForPlayer(
      playerId: 'juan_profile',
      sessionToken: token,
      teammateUsername: 'ana',
      teamName: 'Los Bravos',
    );
    final renamed = store.updateTeamName(
      playerId: 'juan_profile',
      sessionToken: token,
      pairId: created!['pairId'] as String,
      teamName: 'Los Finos',
    );
    final teams = store.teamsForPlayer(
      playerId: 'juan_profile',
      sessionToken: token,
    );
    final archived = store.archiveTeam(
      playerId: 'juan_profile',
      sessionToken: token,
      pairId: created['pairId'] as String,
    );
    final activeTeams = store.teamsForPlayer(
      playerId: 'juan_profile',
      sessionToken: token,
    );

    expect(created['teamName'], 'Los Bravos');
    expect(created['teammateNames'], ['Ana']);
    expect(renamed!['teamName'], 'Los Finos');
    expect(teams.single['teamName'], 'Los Finos');
    expect(archived!['archivedAt'], isNot(0));
    expect(activeTeams, isEmpty);
  });

  test('RankingStore importa JSON antiguo y hashea PIN en claro', () {
    final tempDir = Directory.systemTemp.createTempSync('zapiti_legacy_pin_test');
    addTearDown(() => tempDir.deleteSync(recursive: true));
    final legacyFile = File('${tempDir.path}/ranking.json')
      ..createSync(recursive: true)
      ..writeAsStringSync(jsonEncode({
        'players': {
          'legacy_profile': {
            'playerId': 'legacy_profile',
            'name': 'Legacy',
            'pin': '4444',
            'played': 0,
            'wins': 0,
            'losses': 0,
          },
        },
        'pairs': {},
        'matches': [],
      }));
    final dbPath = '${tempDir.path}/ranking.sqlite';
    final store = RankingStore(path: dbPath, legacyJsonPath: legacyFile.path);

    final profile = store.recoverPlayerProfile(
      username: 'legacy',
      password: '4444',
    );

    expect(profile, isNotNull);
    expect(profile!['playerId'], 'legacy_profile');
    expect(profile['pin'], isNull);
    store.close();
    final db = sqlite3.open(dbPath);
    final storedPlayer = db.select(
      'SELECT * FROM players WHERE player_id = ?',
      ['legacy_profile'],
    ).first;
    expect(storedPlayer['pin_hash'], isA<String>());
    expect(storedPlayer['pin_hash'], isNot('4444'));
    db.dispose();
  });

  test('RankingStore registra jugadores y pareja humana', () {
    final tempDir = Directory.systemTemp.createTempSync('zapiti_ranking_test');
    addTearDown(() => tempDir.deleteSync(recursive: true));
    final store = RankingStore(path: '${tempDir.path}/ranking.sqlite');
    store.upsertPlayerProfile(
      playerId: 'juan_profile',
      username: 'juan',
      name: 'Juan',
      password: 'secreto123',
      teamName: 'Los Bravos',
    );
    store.upsertPlayerProfile(
      playerId: 'ana_profile',
      username: 'ana',
      name: 'Ana',
      password: 'secreto456',
      teamName: 'Los Bravos',
    );
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
          pairId: 'ana_profile+juan_profile',
          teamName: 'Nombre temporal',
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
          pairId: 'ana_profile+juan_profile',
          teamName: 'Nombre temporal',
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
    final players = snapshot['players'] as List<dynamic>;
    expect(pairs, isNotEmpty);
    expect(players, isNotEmpty);
    expect(pairs.first['teamName'], 'Los Bravos');
    expect(pairs.first['played'], 1);
    expect(players.first['pin'], isNull);
    expect(players.first['favoritePair'], 'Los Bravos');
    expect(players.first['pointsFor'], 30);
    store.close();
  });
}
