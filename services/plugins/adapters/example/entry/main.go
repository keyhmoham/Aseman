package main

import (
	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/plugins/adapters/example"
)

func New() (api.Plugin, error) { return example.New(), nil }

// Native loading uses New; main permits ordinary whole-module builds.
func main() {}
