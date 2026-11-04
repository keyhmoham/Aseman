// Command gen-action-schemas writes the input schemas of the platform's
// actions (see pkg/actionschema) for the agents' API catalog:
//
//	go run ./cmd/gen-action-schemas -out plugins/adapters/vmm/harness/action_schemas.json
package main

import (
	"flag"
	"fmt"
	"os"

	"github.com/aseman/aseman/pkg/actionschema"
)

func main() {
	module := flag.String("module", ".", "the Go module's directory (types are resolved across it)")
	root := flag.String("root", "plugins/actions", "directory of the action plugins, under the module")
	out := flag.String("out", "", "file to write (stdout when empty)")
	flag.Parse()
	schemas, err := actionschema.Generate(*module, *root)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	raw, err := actionschema.Encode(schemas)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	if *out == "" {
		os.Stdout.Write(raw)
		return
	}
	if err := os.WriteFile(*out, raw, 0o644); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
