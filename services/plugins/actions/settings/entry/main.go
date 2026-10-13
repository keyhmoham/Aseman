package main

import (
	"github.com/tradera/tradera/internal/plugins/api"
	"github.com/tradera/tradera/plugins/actions/settings"
)

func New() (api.Plugin, error) { return settings.NewPlugin(), nil }
func main()                    {}
