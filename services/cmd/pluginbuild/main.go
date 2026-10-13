// pluginbuild compiles the native modules using the same source tree and flags
// as the daemon. It does not import namespace or adapter implementations.
package main

import (
	"flag"
	"fmt"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

func main() {
	output := flag.String("output", "bin/plugins", "plugin output directory")
	flag.Parse()
	err := filepath.WalkDir("plugins", func(path string, entry fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if !entry.IsDir() || entry.Name() != "entry" {
			return nil
		}
		rel, err := filepath.Rel("plugins", filepath.Dir(path))
		if err != nil {
			return err
		}
		parts := strings.Split(filepath.ToSlash(rel), "/")
		if len(parts) < 2 || (parts[0] != "actions" && parts[0] != "adapters") {
			return filepath.SkipDir
		}
		name := parts[len(parts)-1]
		if rel == filepath.Join("adapters", "example") {
			name = "example-adapter"
		}
		if parts[0] == "actions" {
			name += "-ns"
		}
		if rel == filepath.Join("adapters", "cache", "local") {
			name = "local-cache"
		}
		directory := filepath.Join(*output, parts[0])
		if err := os.MkdirAll(directory, 0755); err != nil {
			return err
		}
		cmd := exec.Command("go", "build", "-trimpath", "-buildmode=plugin", "-o", filepath.Join(directory, name+".so"), "./"+filepath.ToSlash(path))
		cmd.Env = append(os.Environ(), "CGO_ENABLED=1")
		cmd.Stdout = os.Stdout
		cmd.Stderr = os.Stderr
		fmt.Println("building", rel)
		if err := cmd.Run(); err != nil {
			return err
		}
		return filepath.SkipDir
	})
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
