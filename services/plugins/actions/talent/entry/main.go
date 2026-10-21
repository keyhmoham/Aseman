package main

import (
	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/plugins/actions/talent"
)

func New() (api.Plugin, error) { return talent.NewPlugin(), nil }
func main()                    {}
