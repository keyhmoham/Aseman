package main

import (
	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/plugins/actions/tools"
)

func New() (api.Plugin, error) { return tools.NewPlugin(), nil }
func main()                    {}
