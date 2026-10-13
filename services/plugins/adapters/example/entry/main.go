package main

import (
	"github.com/tradera/tradera/internal/plugins/api"
	"github.com/tradera/tradera/plugins/adapters/example"
)

func New() (api.Plugin, error) { return example.New(), nil }

// Native loading uses New; main permits ordinary whole-module builds.
func main() {}
