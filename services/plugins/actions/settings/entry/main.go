package main

import (
	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/plugins/actions/settings"
)

func New() (api.Plugin, error) { return settings.NewPlugin(), nil }
func main()                    {}
