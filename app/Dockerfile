# syntax=docker/dockerfile:1.7
# Aseman web app (Flutter web build) served by nginx. nginx also proxies the
# node's API on the same origin, so the app is built with
# API_BASE_URL=same-origin.
#
# Render.com (Blueprint: ../render.yaml):
#   Docker context = this directory (app/), Dockerfile = Dockerfile.
#   Runtime env DECILLION_API_URL = the Decillion node
#   (https://preview.decillionai.com). Render's PORT is what nginx listens on.
# Optional build args: DEVELOPER_API_BASE, DECILLION_PLATFORM, WEB_RENDERER.
ARG FLUTTER_IMAGE=ghcr.io/cirruslabs/flutter:3.44.0
FROM ${FLUTTER_IMAGE} AS build
# Optional extra CA for building behind a TLS-intercepting proxy:
#   docker build --secret id=extra_ca,src=/path/ca.crt ...
RUN --mount=type=secret,id=extra_ca,required=false \
    if [ -s /run/secrets/extra_ca ]; then \
      cp /run/secrets/extra_ca /usr/local/share/ca-certificates/extra_ca.crt && update-ca-certificates; \
    fi
WORKDIR /src
# Resolve dependencies first (the native Elpian VM plugin is a path
# dependency; the web build runs the VM as WebAssembly from assets/elpian).
COPY pubspec.yaml pubspec.lock* ./
COPY packages ./packages

RUN flutter config --no-analytics >/dev/null && flutter pub get
COPY . .
# The developer API's base URL, shown in the app's Developer API console
# (e.g. https://api.example.com/v1). Empty: the node has no developer host.
ARG DEVELOPER_API_BASE=""
# A platform's own client: its slug. People sign in to that platform's
# accounts and open its published frontend. Empty: main Aseman.
ARG DECILLION_PLATFORM=""
# Release web: tree-shake unused icons, self-host CanvasKit (paired with
# long-cache nginx rules), and keep dart-defines for same-origin API.
# Optional Wasm build (smaller/faster start when plugins allow) via
#   docker build --build-arg WEB_RENDERER=wasm ...
ARG WEB_RENDERER=canvaskit
RUN if [ "$WEB_RENDERER" = "wasm" ]; then \
      flutter build web --release --wasm --no-web-resources-cdn \
        --tree-shake-icons \
        --dart-define=API_BASE_URL=same-origin \
        --dart-define=DEVELOPER_API_BASE=${DEVELOPER_API_BASE} \
        --dart-define=DECILLION_PLATFORM=${DECILLION_PLATFORM}; \
    else \
      flutter build web --release --no-web-resources-cdn \
        --tree-shake-icons \
        --dart-define=API_BASE_URL=same-origin \
        --dart-define=DEVELOPER_API_BASE=${DEVELOPER_API_BASE} \
        --dart-define=DECILLION_PLATFORM=${DECILLION_PLATFORM}; \
    fi

FROM nginx:1.29-alpine
# Render sets PORT (commonly 10000) and routes to it. Local compose publishes
# container port 80 and does not set PORT, so the default stays 80.
ENV PORT=80
COPY deploy/nginx.conf /etc/nginx/conf.d/default.conf
# Default API proxy: this stack's own node (`aseman:8080`). When
# DECILLION_API_URL is set, the entrypoint replaces it with the Decillion
# proxy (same origin). `./aseman.sh up --decillion` still mounts the template
# for the nginx image's own envsubst.
COPY deploy/api.local.conf /etc/nginx/aseman-api.conf
COPY deploy/api.decillion.conf.template /etc/nginx/aseman-api.decillion.template
COPY deploy/docker-entrypoint.d/15-aseman-web.sh /docker-entrypoint.d/15-aseman-web.sh
RUN chmod 755 /docker-entrypoint.d/15-aseman-web.sh
COPY --from=build /src/build/web /usr/share/nginx/html
EXPOSE 80
