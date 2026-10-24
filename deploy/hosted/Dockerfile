# THEapp hosted sync service. Build from the repository root:
#   docker build -f deploy/hosted/Dockerfile -t theapp-hosted .
# Stage 1 compiles bin/thehub.dart (pure Dart, no Flutter UI code).
FROM ghcr.io/cirruslabs/flutter:stable AS build
WORKDIR /src
COPY pubspec.yaml pubspec.lock ./
RUN flutter pub get
COPY lib ./lib
COPY bin ./bin
RUN dart compile exe bin/thehub.dart -o /out/thehub

# Stage 2: a small runtime image, running as an unprivileged user.
FROM debian:stable-slim
RUN useradd --system --uid 10001 --home /data theapp \
 && mkdir -p /data && chown theapp /data
COPY --from=build /out/thehub /usr/local/bin/thehub
USER theapp
VOLUME ["/data"]
EXPOSE 8080
# Only reachable through the proxy (see docker-compose.yml).
ENTRYPOINT ["thehub", "hosted-serve", "--data", "/data", "--listen", "0.0.0.0", "--port", "8080", "--behind-proxy", "yes"]
