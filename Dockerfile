# Etapa de compilación
FROM dart:stable AS build

WORKDIR /app

# Descargar dependencias primero para aprovechar la caché
COPY pubspec.* ./
RUN dart pub get

# Copiar el código y compilar el servidor
COPY . .
RUN dart pub get --offline
RUN dart compile exe bin/zapiti_server.dart -o /app/server

# Imagen mínima de ejecución
FROM scratch

# Librerías necesarias para ejecutar el binario Dart compilado
COPY --from=build /runtime/ /

# Ejecutable del servidor
COPY --from=build /app/server /app/server

EXPOSE 8080

ENTRYPOINT ["/app/server"]