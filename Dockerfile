# ---------- BUILD ----------
FROM dart:stable AS build

WORKDIR /app

COPY pubspec.* ./
RUN dart pub get

COPY . .

RUN dart compile exe bin/zapiti_server.dart -o /app/zapiti_server


# ---------- RUNTIME ----------
FROM debian:bookworm-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        libsqlite3-dev \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY --from=build /app/zapiti_server /app/zapiti_server

CMD ["/app/zapiti_server"]