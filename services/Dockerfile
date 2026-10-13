# syntax=docker/dockerfile:1.7
# tradera node daemon (traderad) + CLI (tradera).
FROM golang:1.26-alpine AS build
WORKDIR /src
# Optional extra CA for building behind a TLS-intercepting proxy:
#   docker build --secret id=extra_ca,src=/path/ca.crt ...
RUN --mount=type=secret,id=extra_ca,required=false \
    if [ -s /run/secrets/extra_ca ]; then cat /run/secrets/extra_ca >> /etc/ssl/certs/ca-certificates.crt; fi
RUN apk add --no-cache build-base git
COPY go.mod go.sum ./
RUN go env -w GO111MODULE=on
RUN go env -w GOPROXY=https://goproxy.cn,direct
RUN --mount=type=cache,target=/go/pkg/mod go mod download
COPY . .
RUN --mount=type=cache,target=/go/pkg/mod --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=1 go build -trimpath -o /out/traderad ./cmd/traderad && \
    CGO_ENABLED=1 go build -trimpath -o /out/tradera ./cmd/tradera && \
    CGO_ENABLED=1 go run -trimpath ./cmd/pluginbuild

# Retain the matching Go toolchain and module source for admin runtime builds.
FROM build AS runtime
RUN cp /out/traderad /out/tradera /usr/local/bin/
ENV TRADERA_PLUGIN_SOURCE_ROOT=/src \
    TRADERA_PLUGIN_DIRECTORY=/src/bin/plugins
# The daemon keeps its node identity, logs, uploaded files and wasm modules
# under ./data relative to the working directory.
WORKDIR /app
VOLUME /app/data
EXPOSE 8080
ENV TRADERA_CONFIG=/app/config.yml
HEALTHCHECK --interval=10s --timeout=3s --start-period=20s --retries=6 \
    CMD wget -qO- http://127.0.0.1:8080/healthz >/dev/null || exit 1
ENTRYPOINT ["traderad"]
