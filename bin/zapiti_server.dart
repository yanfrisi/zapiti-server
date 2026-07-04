import 'dart:io';
import 'package:zapiti_server/server.dart';

void main() async {
  try {
    final server = ZapitiServer();
    await server.start();
    
    // Permitir parada limpia con Ctrl+C
    ProcessSignal.sigint.watch().listen((_) {
      print('\nShutting down server...');
      exit(0);
    });
  } catch (e) {
    print('Error starting server: $e');
    exit(1);
  }
}
