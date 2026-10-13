package main

import (
	"github.com/tradera/tradera/internal/plugins/api"
	"github.com/tradera/tradera/pkg/logger"
	adapter "github.com/tradera/tradera/plugins/adapters/database/postgres"
)

func New() (api.Plugin, error) { return adapter.New(logger.Global()), nil }

// Native loading uses New; main permits ordinary whole-module builds.
func main() {}
