import 'match_state.dart';

abstract interface class RankingRepository {
  Future<void> close();

  Future<Map<String, dynamic>> snapshot({int limit = 20});

  Future<Map<String, dynamic>?> upsertPlayerProfile({
    required String playerId,
    required String username,
    required String name,
    required String password,
    String teamName = '',
  });

  Future<Map<String, dynamic>?> recoverPlayerProfile({
    required String username,
    required String password,
  });

  Future<Map<String, dynamic>?> updatePlayerProfileWithSession({
    required String playerId,
    required String name,
    required String sessionToken,
    String teamName = '',
  });

  Future<bool> verifySessionToken({
    required String playerId,
    required String sessionToken,
  });

  Future<List<Map<String, dynamic>>> teamsForPlayer({
    required String playerId,
    required String sessionToken,
    bool includeArchived = false,
  });

  Future<Map<String, dynamic>?> createTeamForPlayer({
    required String playerId,
    required String sessionToken,
    required String teammateUsername,
    required String teamName,
  });

  Future<Map<String, dynamic>?> updateTeamName({
    required String playerId,
    required String sessionToken,
    required String pairId,
    required String teamName,
  });

  Future<Map<String, dynamic>?> archiveTeam({
    required String playerId,
    required String sessionToken,
    required String pairId,
  });

  Future<Map<String, dynamic>?> teamForPlayer({
    required String playerId,
    required String sessionToken,
    required String pairId,
  });

  Future<void> recordFinishedMatch(MatchState match);
}
