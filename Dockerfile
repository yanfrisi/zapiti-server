FROM dart:stable AS build

WORKDIR /app

COPY pubspec.* ./
RUN dart pub get

COPY . .
RUN dart compile exe bin/zapiti_server.dart -o /app/server

FROM debian:bookworm-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY --from=build /runtime/ /
COPY --from=build /app/server /app/server

EXPOSE 8080

ENV PORT=8080

CMD ["/app/server"]
