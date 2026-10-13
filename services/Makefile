GO       := go
BIN_DIR  := bin
BIN      := traderad
CLI      := tradera

.PHONY: all build daemon cli plugins test vet lint fmt tidy run clean install

all: build

build: daemon cli plugins

daemon:
	CGO_ENABLED=1 $(GO) build -trimpath -o $(BIN_DIR)/$(BIN) ./cmd/traderad

cli:
	CGO_ENABLED=1 $(GO) build -trimpath -o $(BIN_DIR)/$(CLI) ./cmd/tradera

# Compile namespace and adapter entry points with the daemon's build flags.
plugins:
	CGO_ENABLED=1 $(GO) run -trimpath ./cmd/pluginbuild

test:
	$(GO) test ./...

vet:
	$(GO) vet ./...

lint:
	$(GO) vet ./...

fmt:
	gofmt -w $$(find . -name '*.go' -not -path './vendor/*')

tidy:
	$(GO) mod tidy

run:
	$(BIN_DIR)/$(BIN) -config configs/config.yml

install:
	$(GO) install ./cmd/traderad ./cmd/tradera

clean:
	rm -rf $(BIN_DIR) data

.DEFAULT_GOAL := all