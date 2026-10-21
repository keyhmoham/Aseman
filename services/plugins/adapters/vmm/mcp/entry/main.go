package main

import (
	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/pkg/logger"
	"github.com/aseman/aseman/plugins/adapters/vmm/mcp"
)

func New() (api.Plugin, error) { return mcp.New(logger.Global()), nil }
func main()                    {}
