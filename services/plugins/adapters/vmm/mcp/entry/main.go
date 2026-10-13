package main

import (
	"github.com/tradera/tradera/internal/plugins/api"
	"github.com/tradera/tradera/pkg/logger"
	"github.com/tradera/tradera/plugins/adapters/vmm/mcp"
)

func New() (api.Plugin, error) { return mcp.New(logger.Global()), nil }
func main()                    {}
