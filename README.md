# Zapiti Server

Servidor autoritativo de WebSocket para Zapiti.

## Requisitos

- Dart SDK 3 o superior
- Docker, si vas a construir la imagen

## Ejecutar en local

Instala dependencias:

```bash
dart pub get
```

Arranca el servidor:

```bash
dart run bin/zapiti_server.dart
```

Por defecto escucha en `0.0.0.0:8080`, pero puede usar el puerto que marque `PORT`.

### Puerto dinamico

Render inyecta la variable de entorno `PORT`. El servidor la respeta y cae a `8080` si no existe.

## Health check

Endpoint:

```text
GET /health
```

Respuesta:

```json
{ "status": "ok" }
```

## WebSocket

El WebSocket vive en la raiz:

```text
ws://localhost:8080/
```

En produccion, Render expone el mismo endpoint bajo TLS:

```text
wss://zapiti-server.onrender.com/
```

## Docker

Construir imagen:

```bash
docker build -t zapiti-server .
```

Ejecutar localmente:

```bash
docker run -p 8080:8080 -e PORT=8080 zapiti-server
```

## Despliegue en Render

1. Sube este repositorio a GitHub.
2. En Render, crea un `Web Service`.
3. Vincula el repositorio.
4. Elige despliegue con Docker.
5. Selecciona el plan gratuito.
6. Render configurara `PORT` automaticamente.
7. El contenedor debe escuchar en `0.0.0.0`.
8. Verifica `https://TU-SERVICIO.onrender.com/health`.
9. Verifica `wss://TU-SERVICIO.onrender.com/`.

## Protocolo

Los mensajes son JSON.

### Estructura base

```json
{
  "type": "message_type",
  "roomId": "ABC123",
  "playerId": "player-id",
  "payload": {}
}
```

### Snapshot de sala

`room_snapshot` incluye la lista de `seats`. Cada asiento ahora envia `teamId`:

```json
{
  "roomId": "A7K2",
  "phase": "lobby",
  "createdAt": 1710000000000,
  "seats": [
    {
      "playerId": "player-1",
      "name": "Juan",
      "seatIndex": 0,
      "teamId": 1,
      "ready": false,
      "connected": true
    }
  ]
}
```

### Comandos principales

- `create_room`
- `join_room`
- `leave_room`
- `player_ready`
- `select_character`
- `request_signal`
- `start_game`
- `new_hand`
- `restart_game`
- `play_card`
- `call_truco`
- `accept_truco`
- `pass_truco`
- `raise_truco`
- `continue_round`
- `signal`

### Errores habituales

- `invalid_json`
- `unknown_message_type`
- `room_not_found`
- `room_full`
- `player_not_found`
- `invalid_payload`
- `not_in_room`
- `internal_error`

## Tests

```bash
dart test
```

## Estructura

```text
bin/zapiti_server.dart
lib/server.dart
lib/client_connection.dart
lib/room.dart
lib/room_manager.dart
lib/server_protocol.dart
test/
```
