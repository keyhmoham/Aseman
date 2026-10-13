package main

import (
	"github.com/tradera/tradera/internal/plugins/api"
	"github.com/tradera/tradera/plugins/actions/tools"
)

func New() (api.Plugin, error) { return tools.NewPlugin(), nil }
func main()                    {}
