import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:zapiti_server/match_state.dart';
import 'package:zapiti_server/ranking_repository.dart';
import 'package:zapiti_server/server.dart';

void main() {
  test('GET /version.json exposes app version manifest', () async {
    final server = ZapitiServer(
      customHost: '127.0.0.1',
      customPort: 0,
      customRankingStore: _NoopRankingRepository(),
    );
    await server.start();
    addTearDown(server.stop);

    final client = HttpClient();
    addTearDown(client.close);

    final request = await client.getUrl(
      Uri.parse('http://127.0.0.1:${server.port}/version.json'),
    );
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    final json = jsonDecode(body) as Map<String, dynamic>;

    expect(response.statusCode, HttpStatus.ok);
    expect(response.headers.contentType?.mimeType, 'application/json');
    expect(json['latestVersion'], '0.1.0');
    expect(json['minimumMultiplayerVersion'], '0.1.0');
  });
}

class _NoopRankingRepository implements RankingRepository {
  @override
  Future<void> close() async {}

  @override
  Future<Map<String, dynamic>> snapshot({int limit = 20}) async => {};

  @override
  Future<Map<String, dynamic>?> upsertPlayerProfile({
    required String playerId,
    required String username,
    required String name,
    required String password,
    String teamName = '',
  }) async =>
      null;

  @override
  Future<Map<String, dynamic>?> recoverPlayerProfile({
    required String username,
    required String password,
  }) async =>
      null;

  @override
  Future<Map<String, dynamic>?> updatePlayerProfileWithSession({
    required String playerId,
    required String name,
    required String sessionToken,
    String teamName = '',
  }) async =>
      null;

  @override
  Future<bool> verifySessionToken({
    required String playerId,
    required String sessionToken,
  }) async =>
      false;

  @override
  Future<List<Map<String, dynamic>>> teamsForPlayer({
    required String playerId,
    required String sessionToken,
    bool includeArchived = false,
  }) async =>
      const [];

  @override
  Future<Map<String, dynamic>?> createTeamForPlayer({
    required String playerId,
    required String sessionToken,
    required String teammateUsername,
    required String teamName,
  }) async =>
      null;

  @override
  Future<Map<String, dynamic>?> updateTeamName({
    required String playerId,
    required String sessionToken,
    required String pairId,
    required String teamName,
  }) async =>
      null;

  @override
  Future<Map<String, dynamic>?> archiveTeam({
    required String playerId,
    required String sessionToken,
    required String pairId,
  }) async =>
      null;

  @override
  Future<Map<String, dynamic>?> teamForPlayer({
    required String playerId,
    required String sessionToken,
    required String pairId,
  }) async =>
      null;

  @override
  Future<void> recordFinishedMatch(MatchState match) async {}
}
