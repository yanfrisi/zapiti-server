import 'dart:io';

import 'package:zapiti_server/ranking_repository.dart';
import 'package:zapiti_server/ranking_store.dart';
import 'package:zapiti_server/server.dart';
import 'package:zapiti_server/turso_ranking_store.dart';

Future<void> main() async {
  try {
    final rankingStore = await _openRankingRepository();
    final server = ZapitiServer(customRankingStore: rankingStore);
    await server.start();

    Future<void> shutdown() async {
      print('\nShutting down server...');
      await server.stop();
      exit(0);
    }

    ProcessSignal.sigint.watch().listen((_) {
      shutdown();
    });
    if (!Platform.isWindows) {
      ProcessSignal.sigterm.watch().listen((_) {
        shutdown();
      });
    }
  } catch (e) {
    print('Error starting server: $e');
    exit(1);
  }
}

Future<RankingRepository> _openRankingRepository() async {
  final backend = (Platform.environment['ZAPITI_DB_BACKEND'] ?? 'sqlite')
      .trim()
      .toLowerCase();
  switch (backend) {
    case 'sqlite':
      return RankingStore();
    case 'turso':
      return TursoRankingStore.open();
    default:
      throw StateError(
        'Unknown ZAPITI_DB_BACKEND "$backend". Use "sqlite" or "turso".',
      );
  }
}
