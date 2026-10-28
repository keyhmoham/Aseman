# syntax=docker/dockerfile:1.7
# aseman-egress: the filtering proxy beside each project computer
# (services/cmd/aseman-egress). Built from the services module.
FROM golang:1.26-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN --mount=type=cache,target=/go/pkg/mod go mod download
COPY . .
RUN --mount=type=cache,target=/go/pkg/mod --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 go build -trimpath -o /out/aseman-egress ./cmd/aseman-egress

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/aseman-egress /aseman-egress
USER nonroot
ENTRYPOINT ["/aseman-egress"]
