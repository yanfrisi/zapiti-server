import 'dart:convert';
import 'dart:io';

import 'match_state.dart';

class RankingStore {
  final File file;

  RankingStore({String? path})
      : file = File(path ?? 'data/zapiti_ranking.json');

  Map<String, dynamic> snapshot({int limit = 20}) {
    final data = _readData();
    final pairs = (_asStringMap(data['pairs']) ?? const <String, dynamic>{})
        .values
        .whereType<Map>()
        .map((entry) => Map<String, dynamic>.from(entry))
        .toList()
      ..sort((a, b) {
        final winDiff =
            (b['wins'] as int? ?? 0).compareTo(a['wins'] as int? ?? 0);
        if (winDiff != 0) return winDiff;
        final pointsDiff = (b['pointsFor'] as int? ?? 0)
            .compareTo(a['pointsFor'] as int? ?? 0);
        if (pointsDiff != 0) return pointsDiff;
        return (a['teamName']?.toString() ?? '')
            .compareTo(b['teamName']?.toString() ?? '');
      });

    return {
      'pairs': pairs.take(limit).toList(),
      'matches': ((data['matches'] as List<dynamic>? ?? const [])
              .whereType<Map>()
              .map((entry) => Map<String, dynamic>.from(entry))
              .toList()
            ..sort((a, b) =>
                (b['finishedAt'] as int? ?? 0).compareTo(a['finishedAt'] as int? ?? 0)))
          .take(limit)
          .toList(),
    };
  }

  void recordFinishedMatch(MatchState match) {
    final winnerTeamId = match.winningTeamId;
    if (winnerTeamId == null) return;

    final data = _readData();
    final players =
        Map<String, dynamic>.from(_asStringMap(data['players']) ?? const <String, dynamic>{});
    final pairs =
        Map<String, dynamic>.from(_asStringMap(data['pairs']) ?? const <String, dynamic>{});
    final matches = [
      ...(data['matches'] as List<dynamic>? ?? const []),
    ];
    final finishedAt = DateTime.now().millisecondsSinceEpoch;
    final teamIds = match.players.map((player) => player.teamId).toSet();

    for (final player in match.players.where((player) => !player.isBot)) {
      final stats = Map<String, dynamic>.from(
        _asStringMap(players[player.playerId]) ??
            <String, dynamic>{
              'playerId': player.playerId,
              'name': player.name,
              'createdAt': finishedAt,
              'played': 0,
              'wins': 0,
              'losses': 0,
            },
      );
      stats['name'] = player.name;
      stats['updatedAt'] = finishedAt;
      stats['played'] = (stats['played'] as int? ?? 0) + 1;
      if (player.teamId == winnerTeamId) {
        stats['wins'] = (stats['wins'] as int? ?? 0) + 1;
      } else {
        stats['losses'] = (stats['losses'] as int? ?? 0) + 1;
      }
      players[player.playerId] = stats;
    }

    for (final teamId in teamIds) {
      final humanTeamPlayers = match.players
          .where((player) => player.teamId == teamId && !player.isBot)
          .toList();
      if (humanTeamPlayers.isEmpty) continue;

      final pairId = _pairId(humanTeamPlayers);
      final pairStats = Map<String, dynamic>.from(
        _asStringMap(pairs[pairId]) ??
            <String, dynamic>{
              'pairId': pairId,
              'playerIds': humanTeamPlayers.map((player) => player.playerId).toList(),
              'teamName': _teamName(humanTeamPlayers),
              'played': 0,
              'wins': 0,
              'losses': 0,
              'pointsFor': 0,
              'pointsAgainst': 0,
              'createdAt': finishedAt,
            },
      );
      pairStats['teamName'] = _teamName(humanTeamPlayers);
      pairStats['updatedAt'] = finishedAt;
      pairStats['played'] = (pairStats['played'] as int? ?? 0) + 1;
      if (teamId == winnerTeamId) {
        pairStats['wins'] = (pairStats['wins'] as int? ?? 0) + 1;
      } else {
        pairStats['losses'] = (pairStats['losses'] as int? ?? 0) + 1;
      }
      pairStats['pointsFor'] =
          (pairStats['pointsFor'] as int? ?? 0) + (match.score[teamId] ?? 0);
      final opponentScore = teamIds
          .where((candidate) => candidate != teamId)
          .map((candidate) => match.score[candidate] ?? 0)
          .fold(0, (best, score) => score > best ? score : best);
      pairStats['pointsAgainst'] =
          (pairStats['pointsAgainst'] as int? ?? 0) + opponentScore;
      pairs[pairId] = pairStats;
    }

    matches.add({
      'matchId': '${match.roomId}_${match.seed}',
      'roomId': match.roomId,
      'finishedAt': finishedAt,
      'winnerTeamId': winnerTeamId,
      'score': {'1': match.score[1], '2': match.score[2]},
      'teams': {
        for (final teamId in teamIds)
          '$teamId': match.players
              .where((player) => player.teamId == teamId)
              .map((player) => {
                    'playerId': player.playerId,
                    'name': player.name,
                    'isBot': player.isBot,
                  })
              .toList(),
      },
    });

    data['players'] = players;
    data['pairs'] = pairs;
    data['matches'] = matches;
    _writeData(data);
  }

  Map<String, dynamic> _readData() {
    if (!file.existsSync()) {
      return {'players': {}, 'pairs': {}, 'matches': []};
    }
    final decoded = jsonDecode(file.readAsStringSync());
    if (decoded is Map<String, dynamic>) return decoded;
    return {'players': {}, 'pairs': {}, 'matches': []};
  }

  void _writeData(Map<String, dynamic> data) {
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(data),
      flush: true,
    );
  }

  Map<String, dynamic>? _asStringMap(Object? value) {
    if (value is! Map) return null;
    return Map<String, dynamic>.from(value);
  }

  String _pairId(List<MatchPlayer> players) {
    final ids = players.map((player) => player.playerId).toList()..sort();
    return ids.join('+');
  }

  String _teamName(List<MatchPlayer> players) {
    return players.map((player) => player.name).join(' / ');
  }
}
