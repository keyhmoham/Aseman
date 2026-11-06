# syntax=docker/dockerfile:1.7
# Aseman web app (Flutter web build) served by nginx. nginx also proxies the
# aseman API on the same origin, so the app is built with
# API_BASE_URL=same-origin.
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
ARG ASEMAN_PLATFORM=""
RUN flutter build web --release --no-web-resources-cdn --dart-define=API_BASE_URL=same-origin \
    --dart-define=DEVELOPER_API_BASE=${DEVELOPER_API_BASE} \
    --dart-define=ASEMAN_PLATFORM=${ASEMAN_PLATFORM}

FROM nginx:1.29-alpine
COPY deploy/nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /src/build/web /usr/share/nginx/html
EXPOSE 80
