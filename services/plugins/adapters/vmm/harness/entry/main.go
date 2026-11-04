package main

import (
	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/pkg/logger"
	adapter "github.com/aseman/aseman/plugins/adapters/vmm/harness"
)

func New() (api.Plugin, error) { return adapter.New(logger.Global()), nil }

// Native loading uses New; main permits ordinary whole-module builds.
func main() {}
