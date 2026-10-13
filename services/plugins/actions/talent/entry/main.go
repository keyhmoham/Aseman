package main

import (
	"github.com/tradera/tradera/internal/plugins/api"
	"github.com/tradera/tradera/plugins/actions/talent"
)

func New() (api.Plugin, error) { return talent.NewPlugin(), nil }
func main()                    {}
