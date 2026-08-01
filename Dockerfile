# ---------- DART BUILD BASE ----------
FROM dart:3.12.2 AS dart-build-base

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        build-essential \
        ca-certificates \
        curl \
        libsqlite3-dev \
        libssl-dev \
        pkg-config \
    && rm -rf /var/lib/apt/lists/* \
    && curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
        | sh -s -- -y --profile minimal

ENV PATH="/root/.cargo/bin:/usr/lib/dart/bin:/root/.pub-cache/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"


# ---------- BUILD ----------
FROM dart-build-base AS build

WORKDIR /app

COPY pubspec.* ./
RUN dart pub get

COPY . .

RUN dart build cli -t bin/zapiti_server.dart -o /app/build_cli


# ---------- TEST ----------
FROM dart-build-base AS test

WORKDIR /app

COPY pubspec.* ./
RUN dart pub get

COPY . .

RUN dart build cli -t bin/zapiti_server.dart -o /app/build_cli
RUN find /app -name liblibsql_dart.so -print
ENV LD_LIBRARY_PATH=/app/build_cli/bundle/lib

RUN dart analyze
RUN dart test


# ---------- RUNTIME ----------
FROM debian:bookworm-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        libsqlite3-dev \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY --from=build /app/build_cli/bundle /app

ENV LD_LIBRARY_PATH=/app/lib

CMD ["/app/bin/zapiti_server"]
