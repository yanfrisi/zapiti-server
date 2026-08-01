import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:libsql_dart/libsql_dart.dart';

import 'match_state.dart';
import 'ranking_repository.dart';

class TursoRankingStore implements RankingRepository {
  static const databaseUrlEnv = 'TURSO_DATABASE_URL';
  static const authTokenEnv = 'TURSO_AUTH_TOKEN';

  static const _pinHashAlgorithm = 'pbkdf2_sha256';
  static const _pinHashIterations = 120000;
  static const _pinSaltLength = 16;
  static const _pinHashLength = 32;
  static const _sessionTokenLength = 32;

  final LibsqlClient _client;

  TursoRankingStore._(this._client);

  static Future<TursoRankingStore> open({
    String? databaseUrl,
    String? authToken,
    Map<String, String>? environment,
  }) async {
    final env = environment ?? Platform.environment;
    final resolvedUrl = (databaseUrl ?? env[databaseUrlEnv] ?? '').trim();
    final resolvedToken = (authToken ?? env[authTokenEnv] ?? '').trim();

    if (resolvedUrl.isEmpty) {
      throw StateError(
        'Missing required environment variable $databaseUrlEnv.',
      );
    }
    if (resolvedToken.isEmpty) {
      throw StateError('Missing required environment variable $authTokenEnv.');
    }

    final client = LibsqlClient.remote(resolvedUrl, authToken: resolvedToken);

    try {
      await client.connect();
      final rows = await client.query('SELECT 1 AS ok');
      if (rows.isEmpty || rows.first['ok']?.toString() != '1') {
        throw StateError(
          'Turso connectivity check returned an invalid result.',
        );
      }
      final store = TursoRankingStore._(client);
      await store._ensureSchema();
      return store;
    } catch (error) {
      await client.dispose();
      throw StateError(
        'Could not connect to Turso or initialize schema: $error',
      );
    }
  }

  @override
  Future<void> close() => _client.dispose();

  @override
  Future<Map<String, dynamic>> snapshot({int limit = 20}) async {
    final pairRows = await _client.query(
      '''
      SELECT *
      FROM pairs
      WHERE archived_at = 0
      ORDER BY wins DESC, points_for DESC, team_name ASC
      LIMIT ?
      ''',
      positional: [limit],
    );
    final pairs = [for (final row in pairRows) _pairFromRow(row)];

    final allPairRows = await _client.query(
      'SELECT * FROM pairs WHERE archived_at = 0',
    );
    final allPairs = [for (final row in allPairRows) _pairFromRow(row)];

    final playerRows = await _client.query(
      '''
      SELECT *
      FROM players
      ORDER BY wins DESC, played DESC, name ASC
      LIMIT ?
      ''',
      positional: [limit],
    );
    final players = [
      for (final row in playerRows)
        _publicPlayerStats(_playerFromRow(row), allPairs),
    ];

    final matchRows = await _client.query(
      '''
      SELECT *
      FROM matches
      ORDER BY finished_at DESC
      LIMIT ?
      ''',
      positional: [limit],
    );
    final matches = [for (final row in matchRows) _matchFromRow(row)];

    return {'pairs': pairs, 'players': players, 'matches': matches};
  }

  @override
  Future<Map<String, dynamic>?> upsertPlayerProfile({
    required String playerId,
    required String username,
    required String name,
    required String password,
    String teamName = '',
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final normalizedUsername = _normalizeUsername(username);
    final existingByUsername = await _playerByUsername(normalizedUsername);
    if (existingByUsername != null &&
        existingByUsername['playerId']?.toString() != playerId) {
      if (!_passwordMatches(existingByUsername, password)) {
        return null;
      }
      playerId = existingByUsername['playerId']?.toString() ?? playerId;
    }
    final current =
        await _playerById(playerId) ??
        <String, dynamic>{
          'playerId': playerId,
          'createdAt': now,
          'played': 0,
          'wins': 0,
          'losses': 0,
          'pointsFor': 0,
          'pointsAgainst': 0,
          'lastPlayedAt': 0,
        };

    current['playerId'] = playerId;
    current['username'] = normalizedUsername;
    current['name'] = name;
    current['teamName'] = teamName;
    current['updatedAt'] = now;
    _setPasswordHash(current, password);
    final sessionToken = _issueSessionToken(current);
    await _upsertPlayerRow(current);
    return _publicProfile(current, sessionToken: sessionToken);
  }

  @override
  Future<Map<String, dynamic>?> recoverPlayerProfile({
    required String username,
    required String password,
  }) async {
    final player = await _playerByUsername(_normalizeUsername(username));
    if (player == null || !_passwordMatches(player, password)) {
      return null;
    }
    if (player['pin'] != null) {
      _setPasswordHash(player, password);
    }
    final sessionToken = _issueSessionToken(player);
    await _upsertPlayerRow(player);
    return _publicProfile(player, sessionToken: sessionToken);
  }

  @override
  Future<Map<String, dynamic>?> updatePlayerProfileWithSession({
    required String playerId,
    required String name,
    required String sessionToken,
    String teamName = '',
  }) async {
    final player = await _playerById(playerId);
    if (player == null || !_sessionTokenMatches(player, sessionToken)) {
      return null;
    }

    player['name'] = name;
    player['teamName'] = teamName;
    player['updatedAt'] = DateTime.now().millisecondsSinceEpoch;
    await _upsertPlayerRow(player);
    return _publicProfile(player, sessionToken: sessionToken);
  }

  @override
  Future<bool> verifySessionToken({
    required String playerId,
    required String sessionToken,
  }) async {
    final player = await _playerById(playerId);
    return player != null && _sessionTokenMatches(player, sessionToken);
  }

  @override
  Future<List<Map<String, dynamic>>> teamsForPlayer({
    required String playerId,
    required String sessionToken,
    bool includeArchived = false,
  }) async {
    final player = await _playerById(playerId);
    if (player == null || !_sessionTokenMatches(player, sessionToken)) {
      return const [];
    }

    final rows = await _client.query(
      includeArchived
          ? '''
            SELECT *
            FROM pairs
            WHERE player_ids_json LIKE ?
            ORDER BY archived_at ASC, wins DESC, played DESC, team_name ASC
            '''
          : '''
            SELECT *
            FROM pairs
            WHERE player_ids_json LIKE ? AND archived_at = 0
            ORDER BY wins DESC, played DESC, team_name ASC
            ''',
      positional: ['%$playerId%'],
    );
    final teams = <Map<String, dynamic>>[];
    for (final row in rows) {
      final pair = _pairFromRow(row);
      if (_pairContainsPlayer(pair, playerId)) {
        teams.add(await _publicTeam(pair, playerId));
      }
    }
    return teams;
  }

  @override
  Future<Map<String, dynamic>?> createTeamForPlayer({
    required String playerId,
    required String sessionToken,
    required String teammateUsername,
    required String teamName,
  }) async {
    final player = await _playerById(playerId);
    if (player == null || !_sessionTokenMatches(player, sessionToken)) {
      return null;
    }
    final teammate = await _playerByUsername(
      _normalizeUsername(teammateUsername),
    );
    if (teammate == null ||
        teammate['playerId']?.toString() == player['playerId']?.toString()) {
      return null;
    }

    final playerIds = [
      player['playerId'].toString(),
      teammate['playerId'].toString(),
    ]..sort();
    final pairId = playerIds.join('+');
    final now = DateTime.now().millisecondsSinceEpoch;
    final current =
        await _pairById(pairId) ??
        <String, dynamic>{
          'pairId': pairId,
          'playerIds': playerIds,
          'played': 0,
          'wins': 0,
          'losses': 0,
          'pointsFor': 0,
          'pointsAgainst': 0,
          'createdAt': now,
        };
    current['teamName'] = teamName.trim().isEmpty
        ? '${player['name']} / ${teammate['name']}'
        : teamName;
    current['updatedAt'] = now;
    current['archivedAt'] = 0;
    await _upsertPairRow(current);
    return _publicTeam(current, playerId);
  }

  @override
  Future<Map<String, dynamic>?> updateTeamName({
    required String playerId,
    required String sessionToken,
    required String pairId,
    required String teamName,
  }) async {
    final player = await _playerById(playerId);
    final pair = await _pairById(pairId);
    if (player == null ||
        pair == null ||
        !_sessionTokenMatches(player, sessionToken) ||
        !_pairContainsPlayer(pair, playerId)) {
      return null;
    }

    pair['teamName'] = teamName;
    pair['updatedAt'] = DateTime.now().millisecondsSinceEpoch;
    await _upsertPairRow(pair);
    return _publicTeam(pair, playerId);
  }

  @override
  Future<Map<String, dynamic>?> archiveTeam({
    required String playerId,
    required String sessionToken,
    required String pairId,
  }) async {
    final player = await _playerById(playerId);
    final pair = await _pairById(pairId);
    if (player == null ||
        pair == null ||
        !_sessionTokenMatches(player, sessionToken) ||
        !_pairContainsPlayer(pair, playerId)) {
      return null;
    }

    pair['archivedAt'] = DateTime.now().millisecondsSinceEpoch;
    pair['updatedAt'] = pair['archivedAt'];
    await _upsertPairRow(pair);
    return _publicTeam(pair, playerId);
  }

  @override
  Future<Map<String, dynamic>?> teamForPlayer({
    required String playerId,
    required String sessionToken,
    required String pairId,
  }) async {
    final player = await _playerById(playerId);
    final pair = await _pairById(pairId);
    if (player == null ||
        pair == null ||
        !_sessionTokenMatches(player, sessionToken) ||
        !_pairContainsPlayer(pair, playerId) ||
        _asInt(pair['archivedAt']) != 0) {
      return null;
    }
    return _publicTeam(pair, playerId);
  }

  @override
  Future<void> recordFinishedMatch(MatchState match) async {
    final winnerTeamId = match.winningTeamId;
    if (winnerTeamId == null) return;

    final finishedAt = DateTime.now().millisecondsSinceEpoch;
    final teamIds = match.players.map((player) => player.teamId).toSet();
    final matchId = '${match.roomId}_${match.seed}';

    final tx = await _client.transaction(
      behavior: LibsqlTransactionBehavior.immediate,
    );
    try {
      final inserted = await tx.execute(
        '''
        INSERT INTO matches (
          match_id, room_id, finished_at, winner_team_id, score_json, teams_json
        ) VALUES (?, ?, ?, ?, ?, ?)
        ON CONFLICT(match_id) DO NOTHING
        ''',
        positional: [
          matchId,
          match.roomId,
          finishedAt,
          winnerTeamId,
          jsonEncode({'1': match.score[1], '2': match.score[2]}),
          jsonEncode({
            for (final teamId in teamIds)
              '$teamId': match.players
                  .where((player) => player.teamId == teamId)
                  .map(
                    (player) => {
                      'playerId': player.playerId,
                      'name': player.name,
                      'isBot': player.isBot,
                    },
                  )
                  .toList(),
          }),
        ],
      );
      if (inserted == 0) {
        await tx.rollback();
        return;
      }

      for (final player in match.players.where((player) => !player.isBot)) {
        final stats =
            await _playerByIdInTransaction(tx, player.playerId) ??
            <String, dynamic>{
              'playerId': player.playerId,
              'name': player.name,
              'teamName': '',
              'createdAt': finishedAt,
              'played': 0,
              'wins': 0,
              'losses': 0,
              'pointsFor': 0,
              'pointsAgainst': 0,
            };
        stats['name'] = player.name;
        stats['updatedAt'] = finishedAt;
        stats['lastPlayedAt'] = finishedAt;
        stats['played'] = _asInt(stats['played']) + 1;
        if (player.teamId == winnerTeamId) {
          stats['wins'] = _asInt(stats['wins']) + 1;
        } else {
          stats['losses'] = _asInt(stats['losses']) + 1;
        }
        stats['pointsFor'] =
            _asInt(stats['pointsFor']) + (match.score[player.teamId] ?? 0);
        stats['pointsAgainst'] =
            _asInt(stats['pointsAgainst']) +
            _opponentScore(teamIds, match.score, player.teamId);
        await _upsertPlayerRowInTransaction(tx, stats);
      }

      for (final teamId in teamIds) {
        final humanTeamPlayers = match.players
            .where((player) => player.teamId == teamId && !player.isBot)
            .toList();
        if (humanTeamPlayers.isEmpty) continue;

        final explicitPair = await _explicitPairForTeamInTransaction(
          tx,
          humanTeamPlayers,
        );
        final pairId =
            explicitPair?['pairId']?.toString() ?? _pairId(humanTeamPlayers);
        final pairStats =
            explicitPair ??
            await _pairByIdInTransaction(tx, pairId) ??
            <String, dynamic>{
              'pairId': pairId,
              'playerIds': humanTeamPlayers
                  .map((player) => player.playerId)
                  .toList(),
              'played': 0,
              'wins': 0,
              'losses': 0,
              'pointsFor': 0,
              'pointsAgainst': 0,
              'createdAt': finishedAt,
            };
        pairStats['teamName'] =
            explicitPair?['teamName']?.toString() ??
            await _teamNameInTransaction(tx, humanTeamPlayers);
        pairStats['updatedAt'] = finishedAt;
        pairStats['played'] = _asInt(pairStats['played']) + 1;
        if (teamId == winnerTeamId) {
          pairStats['wins'] = _asInt(pairStats['wins']) + 1;
        } else {
          pairStats['losses'] = _asInt(pairStats['losses']) + 1;
        }
        pairStats['pointsFor'] =
            _asInt(pairStats['pointsFor']) + (match.score[teamId] ?? 0);
        pairStats['pointsAgainst'] =
            _asInt(pairStats['pointsAgainst']) +
            _opponentScore(teamIds, match.score, teamId);
        await _upsertPairRowInTransaction(tx, pairStats);
      }

      await tx.commit();
    } catch (_) {
      await tx.rollback();
      rethrow;
    }
  }

  Future<void> _ensureSchema() async {
    await _client.execute('PRAGMA foreign_keys = ON');
    await _client.execute('''
      CREATE TABLE IF NOT EXISTS metadata (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      )
    ''');
    await _client.execute('''
      CREATE TABLE IF NOT EXISTS players (
        player_id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        team_name TEXT NOT NULL DEFAULT '',
        pin_hash_algorithm TEXT NOT NULL DEFAULT '',
        pin_hash_iterations INTEGER NOT NULL DEFAULT 0,
        pin_salt TEXT NOT NULL DEFAULT '',
        pin_hash TEXT NOT NULL DEFAULT '',
        pin_updated_at INTEGER NOT NULL DEFAULT 0,
        username TEXT NOT NULL DEFAULT '',
        session_token_hash TEXT NOT NULL DEFAULT '',
        session_token_issued_at INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL DEFAULT 0,
        updated_at INTEGER NOT NULL DEFAULT 0,
        last_played_at INTEGER NOT NULL DEFAULT 0,
        played INTEGER NOT NULL DEFAULT 0,
        wins INTEGER NOT NULL DEFAULT 0,
        losses INTEGER NOT NULL DEFAULT 0,
        points_for INTEGER NOT NULL DEFAULT 0,
        points_against INTEGER NOT NULL DEFAULT 0
      )
    ''');
    await _ensureColumn('players', 'username', "TEXT NOT NULL DEFAULT ''");
    await _ensureColumn(
      'players',
      'session_token_hash',
      "TEXT NOT NULL DEFAULT ''",
    );
    await _ensureColumn(
      'players',
      'session_token_issued_at',
      'INTEGER NOT NULL DEFAULT 0',
    );
    await _client.execute(
      "CREATE UNIQUE INDEX IF NOT EXISTS idx_players_username_unique "
      "ON players(username) WHERE username <> ''",
    );
    await _client.execute('''
      CREATE TABLE IF NOT EXISTS pairs (
        pair_id TEXT PRIMARY KEY,
        player_ids_json TEXT NOT NULL,
        team_name TEXT NOT NULL,
        played INTEGER NOT NULL DEFAULT 0,
        wins INTEGER NOT NULL DEFAULT 0,
        losses INTEGER NOT NULL DEFAULT 0,
        points_for INTEGER NOT NULL DEFAULT 0,
        points_against INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL DEFAULT 0,
        updated_at INTEGER NOT NULL DEFAULT 0,
        archived_at INTEGER NOT NULL DEFAULT 0
      )
    ''');
    await _ensureColumn('pairs', 'archived_at', 'INTEGER NOT NULL DEFAULT 0');
    await _client.execute('''
      CREATE TABLE IF NOT EXISTS matches (
        match_id TEXT PRIMARY KEY,
        room_id TEXT NOT NULL,
        finished_at INTEGER NOT NULL,
        winner_team_id INTEGER NOT NULL,
        score_json TEXT NOT NULL,
        teams_json TEXT NOT NULL
      )
    ''');
  }

  Future<void> _ensureColumn(
    String table,
    String column,
    String definition,
  ) async {
    final columns = await _client.query('PRAGMA table_info($table)');
    final exists = columns.any((row) => row['name'] == column);
    if (!exists) {
      await _client.execute(
        'ALTER TABLE $table ADD COLUMN $column $definition',
      );
    }
  }

  Future<Map<String, dynamic>?> _playerById(String playerId) async {
    final result = await _client.query(
      'SELECT * FROM players WHERE player_id = ? LIMIT 1',
      positional: [playerId],
    );
    if (result.isEmpty) return null;
    return _playerFromRow(result.first);
  }

  Future<Map<String, dynamic>?> _playerByUsername(String username) async {
    final result = await _client.query(
      'SELECT * FROM players WHERE username = ? LIMIT 1',
      positional: [username],
    );
    if (result.isEmpty) return null;
    return _playerFromRow(result.first);
  }

  Future<Map<String, dynamic>?> _pairById(String pairId) async {
    final result = await _client.query(
      'SELECT * FROM pairs WHERE pair_id = ? LIMIT 1',
      positional: [pairId],
    );
    if (result.isEmpty) return null;
    return _pairFromRow(result.first);
  }

  Future<Map<String, dynamic>?> _playerByIdInTransaction(
    dynamic tx,
    String playerId,
  ) async {
    final result = await tx.query(
      'SELECT * FROM players WHERE player_id = ? LIMIT 1',
      positional: [playerId],
    );
    if (result.isEmpty) return null;
    return _playerFromRow(result.first);
  }

  Future<Map<String, dynamic>?> _pairByIdInTransaction(
    dynamic tx,
    String pairId,
  ) async {
    final result = await tx.query(
      'SELECT * FROM pairs WHERE pair_id = ? LIMIT 1',
      positional: [pairId],
    );
    if (result.isEmpty) return null;
    return _pairFromRow(result.first);
  }

  Future<void> _upsertPlayerRow(Map<String, dynamic> player) async {
    await _client.execute(_upsertPlayerSql, positional: _playerValues(player));
  }

  Future<void> _upsertPlayerRowInTransaction(
    dynamic tx,
    Map<String, dynamic> player,
  ) async {
    await tx.execute(_upsertPlayerSql, positional: _playerValues(player));
  }

  Future<void> _upsertPairRow(Map<String, dynamic> pair) async {
    await _client.execute(_upsertPairSql, positional: _pairValues(pair));
  }

  Future<void> _upsertPairRowInTransaction(
    dynamic tx,
    Map<String, dynamic> pair,
  ) async {
    await tx.execute(_upsertPairSql, positional: _pairValues(pair));
  }

  static const _upsertPlayerSql = '''
    INSERT INTO players (
      player_id, name, team_name, pin_hash_algorithm, pin_hash_iterations,
      pin_salt, pin_hash, pin_updated_at, username, session_token_hash,
      session_token_issued_at, created_at, updated_at, last_played_at,
      played, wins, losses, points_for, points_against
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT(player_id) DO UPDATE SET
      name = excluded.name,
      team_name = excluded.team_name,
      pin_hash_algorithm = excluded.pin_hash_algorithm,
      pin_hash_iterations = excluded.pin_hash_iterations,
      pin_salt = excluded.pin_salt,
      pin_hash = excluded.pin_hash,
      pin_updated_at = excluded.pin_updated_at,
      username = excluded.username,
      session_token_hash = excluded.session_token_hash,
      session_token_issued_at = excluded.session_token_issued_at,
      updated_at = excluded.updated_at,
      last_played_at = excluded.last_played_at,
      played = excluded.played,
      wins = excluded.wins,
      losses = excluded.losses,
      points_for = excluded.points_for,
      points_against = excluded.points_against
    ''';

  static const _upsertPairSql = '''
    INSERT INTO pairs (
      pair_id, player_ids_json, team_name, played, wins, losses,
      points_for, points_against, created_at, updated_at, archived_at
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT(pair_id) DO UPDATE SET
      player_ids_json = excluded.player_ids_json,
      team_name = excluded.team_name,
      played = excluded.played,
      wins = excluded.wins,
      losses = excluded.losses,
      points_for = excluded.points_for,
      points_against = excluded.points_against,
      updated_at = excluded.updated_at,
      archived_at = excluded.archived_at
    ''';

  List<dynamic> _playerValues(Map<String, dynamic> player) {
    return [
      player['playerId']?.toString() ?? '',
      player['name']?.toString() ?? 'Jugador',
      player['teamName']?.toString() ?? '',
      player['pinHashAlgorithm']?.toString() ?? '',
      _asInt(player['pinHashIterations']),
      player['pinSalt']?.toString() ?? '',
      player['pinHash']?.toString() ?? '',
      _asInt(player['pinUpdatedAt']),
      player['username']?.toString() ?? '',
      player['sessionTokenHash']?.toString() ?? '',
      _asInt(player['sessionTokenIssuedAt']),
      _asInt(player['createdAt']),
      _asInt(player['updatedAt']),
      _asInt(player['lastPlayedAt']),
      _asInt(player['played']),
      _asInt(player['wins']),
      _asInt(player['losses']),
      _asInt(player['pointsFor']),
      _asInt(player['pointsAgainst']),
    ];
  }

  List<dynamic> _pairValues(Map<String, dynamic> pair) {
    return [
      pair['pairId']?.toString() ?? '',
      jsonEncode(pair['playerIds'] as List<dynamic>? ?? const []),
      pair['teamName']?.toString() ?? 'Pareja',
      _asInt(pair['played']),
      _asInt(pair['wins']),
      _asInt(pair['losses']),
      _asInt(pair['pointsFor']),
      _asInt(pair['pointsAgainst']),
      _asInt(pair['createdAt']),
      _asInt(pair['updatedAt']),
      _asInt(pair['archivedAt']),
    ];
  }

  Map<String, dynamic> _playerFromRow(Map<String, dynamic> row) {
    return {
      'playerId': row['player_id'],
      'name': row['name'],
      'teamName': row['team_name'],
      'username': row['username'],
      'pinHashAlgorithm': row['pin_hash_algorithm'],
      'pinHashIterations': row['pin_hash_iterations'],
      'pinSalt': row['pin_salt'],
      'pinHash': row['pin_hash'],
      'pinUpdatedAt': row['pin_updated_at'],
      'sessionTokenHash': row['session_token_hash'],
      'sessionTokenIssuedAt': row['session_token_issued_at'],
      'createdAt': row['created_at'],
      'updatedAt': row['updated_at'],
      'lastPlayedAt': row['last_played_at'],
      'played': row['played'],
      'wins': row['wins'],
      'losses': row['losses'],
      'pointsFor': row['points_for'],
      'pointsAgainst': row['points_against'],
    };
  }

  Map<String, dynamic> _pairFromRow(Map<String, dynamic> row) {
    return {
      'pairId': row['pair_id'],
      'playerIds': jsonDecode(row['player_ids_json'] as String),
      'teamName': row['team_name'],
      'played': row['played'],
      'wins': row['wins'],
      'losses': row['losses'],
      'pointsFor': row['points_for'],
      'pointsAgainst': row['points_against'],
      'createdAt': row['created_at'],
      'updatedAt': row['updated_at'],
      'archivedAt': row['archived_at'],
    };
  }

  Map<String, dynamic> _matchFromRow(Map<String, dynamic> row) {
    return {
      'matchId': row['match_id'],
      'roomId': row['room_id'],
      'finishedAt': row['finished_at'],
      'winnerTeamId': row['winner_team_id'],
      'score': jsonDecode(row['score_json'] as String),
      'teams': jsonDecode(row['teams_json'] as String),
    };
  }

  int _opponentScore(Set<int> teamIds, Map<int, int> score, int teamId) {
    return teamIds
        .where((candidate) => candidate != teamId)
        .map((candidate) => score[candidate] ?? 0)
        .fold(0, (best, score) => score > best ? score : best);
  }

  int _asInt(Object? value) {
    if (value is int) return value;
    if (value is BigInt) return value.toInt();
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }

  Map<String, dynamic> _publicProfile(
    Map<String, dynamic> profile, {
    String? sessionToken,
  }) {
    return {
      'playerId': profile['playerId'],
      'username': profile['username'] ?? '',
      'name': profile['name'],
      if (sessionToken != null) 'sessionToken': sessionToken,
      'teamName': profile['teamName'] ?? '',
      'played': profile['played'] ?? 0,
      'wins': profile['wins'] ?? 0,
      'losses': profile['losses'] ?? 0,
      'pointsFor': profile['pointsFor'] ?? 0,
      'pointsAgainst': profile['pointsAgainst'] ?? 0,
      'lastPlayedAt': profile['lastPlayedAt'] ?? 0,
    };
  }

  Map<String, dynamic> _publicPlayerStats(
    Map<String, dynamic> profile,
    List<Map<String, dynamic>> pairs,
  ) {
    return {
      'playerId': profile['playerId'],
      'username': profile['username'] ?? '',
      'name': profile['name'],
      'teamName': profile['teamName'] ?? '',
      'played': profile['played'] ?? 0,
      'wins': profile['wins'] ?? 0,
      'losses': profile['losses'] ?? 0,
      'pointsFor': profile['pointsFor'] ?? 0,
      'pointsAgainst': profile['pointsAgainst'] ?? 0,
      'lastPlayedAt': profile['lastPlayedAt'] ?? 0,
      'favoritePair': _favoritePairName(profile['playerId']?.toString(), pairs),
    };
  }

  bool _passwordMatches(Map<String, dynamic> profile, String password) {
    final salt = profile['pinSalt']?.toString();
    final hash = profile['pinHash']?.toString();
    if (salt != null && salt.isNotEmpty && hash != null && hash.isNotEmpty) {
      final candidate = _hashPassword(password, base64Decode(salt));
      return _constantTimeEquals(candidate, base64Decode(hash));
    }

    final legacyPin = profile['pin']?.toString();
    return legacyPin != null && legacyPin == password;
  }

  void _setPasswordHash(Map<String, dynamic> profile, String password) {
    final salt = _randomBytes(_pinSaltLength);
    final hash = _hashPassword(password, salt);
    profile['pinHashAlgorithm'] = _pinHashAlgorithm;
    profile['pinHashIterations'] = _pinHashIterations;
    profile['pinSalt'] = base64Encode(salt);
    profile['pinHash'] = base64Encode(hash);
    profile['pinUpdatedAt'] = DateTime.now().millisecondsSinceEpoch;
    profile.remove('pin');
  }

  String _issueSessionToken(Map<String, dynamic> profile) {
    final token = base64UrlEncode(_randomBytes(_sessionTokenLength));
    profile['sessionTokenHash'] = _hashSessionToken(token);
    profile['sessionTokenIssuedAt'] = DateTime.now().millisecondsSinceEpoch;
    return token;
  }

  bool _sessionTokenMatches(Map<String, dynamic> profile, String sessionToken) {
    final storedHash = profile['sessionTokenHash']?.toString() ?? '';
    if (storedHash.isEmpty || sessionToken.isEmpty) return false;
    return _constantTimeEquals(
      utf8.encode(storedHash),
      utf8.encode(_hashSessionToken(sessionToken)),
    );
  }

  String _hashSessionToken(String sessionToken) {
    return sha256.convert(utf8.encode(sessionToken)).toString();
  }

  List<int> _hashPassword(String password, List<int> salt) {
    return _pbkdf2HmacSha256(
      utf8.encode(password),
      salt,
      iterations: _pinHashIterations,
      length: _pinHashLength,
    );
  }

  String _normalizeUsername(String username) {
    return username.trim().toLowerCase();
  }

  List<int> _pbkdf2HmacSha256(
    List<int> password,
    List<int> salt, {
    required int iterations,
    required int length,
  }) {
    final hmac = Hmac(sha256, password);
    final blockCount = (length / sha256.blockSize).ceil();
    final output = <int>[];

    for (var block = 1; block <= blockCount; block++) {
      final blockSalt = [
        ...salt,
        (block >> 24) & 0xff,
        (block >> 16) & 0xff,
        (block >> 8) & 0xff,
        block & 0xff,
      ];
      var previous = hmac.convert(blockSalt).bytes;
      final result = List<int>.from(previous);
      for (var i = 1; i < iterations; i++) {
        previous = hmac.convert(previous).bytes;
        for (var index = 0; index < result.length; index++) {
          result[index] ^= previous[index];
        }
      }
      output.addAll(result);
    }

    return output.take(length).toList();
  }

  List<int> _randomBytes(int length) {
    final random = Random.secure();
    return List<int>.generate(length, (_) => random.nextInt(256));
  }

  bool _constantTimeEquals(List<int> left, List<int> right) {
    if (left.length != right.length) return false;
    var diff = 0;
    for (var index = 0; index < left.length; index++) {
      diff |= left[index] ^ right[index];
    }
    return diff == 0;
  }

  String _favoritePairName(String? playerId, List<Map<String, dynamic>> pairs) {
    if (playerId == null || playerId.isEmpty) return '';
    final playerPairs =
        pairs.where((pair) {
          final playerIds = pair['playerIds'];
          return playerIds is List &&
              playerIds.map((entry) => entry.toString()).contains(playerId);
        }).toList()..sort((a, b) {
          final playedDiff = (b['played'] as int? ?? 0).compareTo(
            a['played'] as int? ?? 0,
          );
          if (playedDiff != 0) return playedDiff;
          return (b['wins'] as int? ?? 0).compareTo(a['wins'] as int? ?? 0);
        });
    if (playerPairs.isEmpty) return '';
    return playerPairs.first['teamName']?.toString() ?? '';
  }

  bool _pairContainsPlayer(Map<String, dynamic> pair, String playerId) {
    final playerIds = pair['playerIds'];
    return playerIds is List &&
        playerIds.map((entry) => entry.toString()).contains(playerId);
  }

  Future<Map<String, dynamic>> _publicTeam(
    Map<String, dynamic> pair,
    String localPlayerId,
  ) async {
    final playerIds = (pair['playerIds'] as List<dynamic>? ?? const [])
        .map((entry) => entry.toString())
        .toList();
    final teammates = <Map<String, dynamic>>[];
    for (final memberId in playerIds) {
      if (memberId == localPlayerId) continue;
      final teammate = await _playerById(memberId);
      if (teammate != null) teammates.add(teammate);
    }
    return {
      ...pair,
      'teammateIds': [for (final teammate in teammates) teammate['playerId']],
      'teammateNames': [for (final teammate in teammates) teammate['name']],
      'teammateUsernames': [
        for (final teammate in teammates) teammate['username'],
      ],
    };
  }

  Future<Map<String, dynamic>?> _explicitPairForTeamInTransaction(
    dynamic tx,
    List<MatchPlayer> players,
  ) async {
    final humanIds = players.map((player) => player.playerId).toSet();
    final pairIds = players
        .map((player) => player.pairId?.trim() ?? '')
        .where((pairId) => pairId.isNotEmpty)
        .toSet();

    for (final pairId in pairIds) {
      final pair = await _pairByIdInTransaction(tx, pairId);
      final rawPlayerIds = pair?['playerIds'];
      if (pair == null || rawPlayerIds is! List) continue;
      final storedIds = rawPlayerIds.map((entry) => entry.toString()).toSet();
      if (humanIds.every(storedIds.contains)) {
        return pair;
      }
    }
    return null;
  }

  String _pairId(List<MatchPlayer> players) {
    final ids = players.map((player) => player.playerId).toList()..sort();
    return ids.join('+');
  }

  Future<String> _teamNameInTransaction(
    dynamic tx,
    List<MatchPlayer> players,
  ) async {
    for (final player in players) {
      final profile = await _playerByIdInTransaction(tx, player.playerId);
      final teamName = profile?['teamName']?.toString().trim() ?? '';
      if (teamName.isNotEmpty) return teamName;
    }
    return players.map((player) => player.name).join(' / ');
  }
}
