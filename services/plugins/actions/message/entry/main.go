package main

import (
	"github.com/aseman/aseman/internal/plugins/api"
	namespace "github.com/aseman/aseman/plugins/actions/message"
)

func New() (api.Plugin, error) { return namespace.NewPlugin(), nil }

// Native loading uses New; main permits ordinary whole-module builds.
func main() {}
