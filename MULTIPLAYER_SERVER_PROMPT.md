# Prompt para crear el servidor multijugador de Zapiti

Quiero que crees un proyecto completo de servidor multijugador para mi juego de cartas Zapiti. El cliente ya existe en Flutter y se comunicara con el servidor mediante WebSocket usando mensajes JSON.

## Objetivo

Crear un servidor WebSocket autoritativo para partidas multijugador de Zapiti.

El servidor debe permitir:

- Crear salas.
- Unirse a salas existentes mediante codigo.
- Mantener jugadores conectados.
- Asignar asientos a los jugadores.
- Marcar jugadores como listos.
- Enviar snapshots de la sala a todos los clientes.
- Gestionar desconexiones.
- Preparar la base para jugar cartas, pedir truco, aceptar truco, subir apuesta, pasar, continuar ronda y enviar senas.

El primer objetivo no es implementar toda la IA ni todas las reglas completas del juego, sino dejar un servidor solido y extensible para conectar el lobby Flutter y empezar partidas reales.

## Tecnologia deseada

Usar Dart puro, sin Flutter.

El servidor debe poder ejecutarse con:

```bash
dart run bin/zapiti_server.dart
```

Debe escuchar por defecto en:

```text
0.0.0.0:8080
```

Y aceptar conexiones WebSocket en:

```text
ws://localhost:8080
```

El puerto debe poder cambiarse con una variable de entorno:

```bash
PORT=9090 dart run bin/zapiti_server.dart
```

En Windows tambien debe funcionar.

## Estructura del proyecto

Crea un proyecto independiente llamado `zapiti_server` con esta estructura:

```text
zapiti_server/
  pubspec.yaml
  README.md
  bin/
    zapiti_server.dart
  lib/
    client_connection.dart
    room.dart
    room_manager.dart
    server_protocol.dart
  test/
    room_manager_test.dart
    server_protocol_test.dart
```

## Protocolo WebSocket

Todos los mensajes son JSON.

Cada mensaje debe tener esta forma base:

```json
{
  "type": "message_type",
  "roomId": "ABC123",
  "playerId": "player-id",
  "payload": {}
}
```

Campos:

- `type`: obligatorio.
- `roomId`: opcional segun mensaje.
- `playerId`: opcional segun mensaje.
- `payload`: objeto JSON opcional.

## Tipos de mensaje

Implementar estos tipos:

```text
create_room
join_room
leave_room
room_snapshot
player_ready
start_game
play_card
call_truco
accept_truco
pass_truco
raise_truco
continue_round
signal
error
```

## Modelos del protocolo

Crear en `server_protocol.dart`:

- `enum MultiplayerMessageType`
- `class MultiplayerMessage`
- `class MultiplayerSeat`
- `class MultiplayerRoomSnapshot`

### MultiplayerMessage

Debe tener:

```dart
final MultiplayerMessageType type;
final String? roomId;
final String? playerId;
final Map<String, dynamic>? payload;
```

Debe implementar:

```dart
Map<String, dynamic> toJson()
factory MultiplayerMessage.fromJson(Map<String, dynamic> json)
String encode()
factory MultiplayerMessage.decode(String source)
```

Si llega un tipo desconocido, debe generar un mensaje de error controlado o lanzar una excepcion clara que luego el servidor convierta en respuesta `error`.

### MultiplayerSeat

Debe representar un jugador dentro de una sala:

```dart
final String playerId;
final String name;
final int seatIndex;
final bool ready;
final bool connected;
```

Debe implementar `toJson` y `fromJson`.

### MultiplayerRoomSnapshot

Debe representar el estado publico de una sala:

```dart
final String roomId;
final List<MultiplayerSeat> seats;
final String phase;
final int createdAt;
```

Fases iniciales recomendadas:

```text
lobby
starting
playing
finished
```

Debe implementar `toJson` y `fromJson`.

## Comportamiento del servidor

### Al conectar un cliente

El servidor debe:

- Aceptar la conexion WebSocket.
- Crear un `ClientConnection` interno con un `connectionId`.
- Esperar mensajes JSON del cliente.
- Responder con `error` si el JSON es invalido.

### create_room

Cuando recibe:

```json
{
  "type": "create_room",
  "payload": {
    "name": "Juan"
  }
}
```

Debe:

- Crear una sala con codigo corto, por ejemplo `A7K2`.
- Crear un jugador para el cliente.
- Asignarle el asiento 0.
- Guardar la sala en memoria.
- Responder al cliente con `room_snapshot`.

Respuesta esperada:

```json
{
  "type": "room_snapshot",
  "roomId": "A7K2",
  "playerId": "generated-player-id",
  "payload": {
    "roomId": "A7K2",
    "phase": "lobby",
    "createdAt": 1710000000000,
    "seats": [
      {
        "playerId": "generated-player-id",
        "name": "Juan",
        "seatIndex": 0,
        "ready": false,
        "connected": true
      }
    ]
  }
}
```

### join_room

Cuando recibe:

```json
{
  "type": "join_room",
  "roomId": "A7K2",
  "payload": {
    "name": "Ana"
  }
}
```

Debe:

- Buscar la sala.
- Rechazar si no existe.
- Rechazar si ya hay 4 jugadores.
- Asignar el primer asiento libre.
- Crear un jugador para el cliente.
- Enviar `room_snapshot` a todos los jugadores de la sala.

### player_ready

Cuando recibe:

```json
{
  "type": "player_ready",
  "roomId": "A7K2",
  "playerId": "player-id",
  "payload": {
    "ready": true
  }
}
```

Debe:

- Validar que el jugador pertenece a la sala.
- Actualizar `ready`.
- Emitir `room_snapshot` a todos.
- Si hay al menos 2 jugadores y todos estan listos, puede cambiar la fase a `starting` y emitir `start_game`.

Para este primer MVP, si se emite `start_game`, puede ser solo una notificacion sin repartir cartas todavia.

### leave_room y desconexion

Al recibir `leave_room` o al cerrarse el WebSocket:

- Marcar al jugador como desconectado o eliminarlo de la sala.
- Para MVP, se recomienda eliminarlo de la sala.
- Emitir `room_snapshot` a los demas.
- Si la sala queda vacia, borrarla de memoria.

### Mensajes de juego

Los siguientes mensajes deben existir y validarse de forma basica, aunque no implementen todas las reglas todavia:

```text
play_card
call_truco
accept_truco
pass_truco
raise_truco
continue_round
signal
```

Para MVP:

- Validar que `roomId` existe.
- Validar que `playerId` pertenece a la sala.
- Reenviar el mensaje a los demas jugadores de la sala o responder con un snapshot.
- Si falta algun dato, responder `error`.

Mas adelante estos mensajes se convertiran en acciones autoritativas con reglas completas.

## Errores

Todo error debe responder con:

```json
{
  "type": "error",
  "roomId": "A7K2",
  "playerId": "player-id",
  "payload": {
    "message": "Descripcion clara del error",
    "code": "ERROR_CODE"
  }
}
```

Codigos recomendados:

```text
invalid_json
unknown_message_type
room_not_found
room_full
player_not_found
invalid_payload
not_in_room
internal_error
```

## Requisitos importantes

- El servidor debe ser autoritativo: el cliente pide acciones, pero el servidor decide si son validas.
- El estado de salas debe estar en memoria para este primer MVP.
- No usar base de datos todavia.
- No usar autenticacion todavia.
- El codigo debe ser simple, mantenible y testeable.
- No bloquear el event loop.
- Manejar desconexiones sin romper el servidor.
- Loguear en consola conexiones, creacion de salas, union de jugadores, errores y desconexiones.
- Evitar dependencias innecesarias.

## Tests

Crear tests para:

- Parsear y serializar `MultiplayerMessage`.
- Parsear y serializar `MultiplayerRoomSnapshot`.
- Crear una sala.
- Unirse a una sala.
- Rechazar sala inexistente.
- Rechazar sala llena.
- Marcar jugador como listo.
- Eliminar jugador al desconectar.
- Borrar sala vacia.

Los tests deben ejecutarse con:

```bash
dart test
```

## README

El `README.md` del servidor debe explicar:

- Como instalar dependencias.
- Como ejecutar el servidor.
- Como cambiar el puerto.
- Como conectarse desde el emulador Android.
- Como conectarse desde un movil fisico en la misma red.

Notas de conexion:

- En navegador local: `ws://localhost:8080`
- En Android emulator: `ws://10.0.2.2:8080`
- En movil fisico: `ws://IP_DEL_PC:8080`

Ejemplo:

```text
ws://192.168.1.50:8080
```

## Entregable final

Quiero que entregues:

- Proyecto completo `zapiti_server`.
- Codigo listo para ejecutar.
- Tests funcionando.
- README con instrucciones.
- Protocolo documentado en el README.
- Sin dependencias de Flutter.

## Extra opcional

Si queda tiempo, anadir:

- Endpoint HTTP simple `GET /health` que responda `OK`.
- Comando en consola al arrancar mostrando:

```text
Zapiti server listening on ws://0.0.0.0:8080
```

- Cierre limpio con Ctrl+C.
