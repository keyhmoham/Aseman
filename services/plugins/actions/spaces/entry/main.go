package main

import (
	"github.com/tradera/tradera/internal/plugins/api"
	namespace "github.com/tradera/tradera/plugins/actions/spaces"
)

func New() (api.Plugin, error) { return namespace.NewPlugin(), nil }

// Native loading uses New; main permits ordinary whole-module builds.
func main() {}
