package app_test

import (
	"go/parser"
	"go/token"
	"io/fs"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

func TestHostDoesNotImportPluginImplementations(t *testing.T) {
	root := filepath.Join("..")
	err := filepath.WalkDir(root, func(path string, entry fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if entry.IsDir() {
			if entry.Name() == "testdata" {
				return filepath.SkipDir
			}
			return nil
		}
		if !strings.HasSuffix(path, ".go") || strings.HasSuffix(path, "_test.go") {
			return nil
		}
		file, err := parser.ParseFile(token.NewFileSet(), path, nil, parser.ImportsOnly)
		if err != nil {
			return err
		}
		for _, spec := range file.Imports {
			importPath, err := strconv.Unquote(spec.Path.Value)
			if err != nil {
				return err
			}
			if strings.Contains(importPath, "/plugins/actions/") || strings.Contains(importPath, "/plugins/adapters/") {
				if strings.Contains(importPath, "/actions/support/") || strings.Contains(importPath, "/models") || strings.HasSuffix(importPath, "/ports") || strings.HasSuffix(importPath, "/runtime") || strings.HasSuffix(importPath, "/network/gateway") {
					continue
				}
				t.Errorf("host %s imports plugin implementation %s", path, importPath)
			}
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
}
func TestNamespacesDoNotImportSiblingServices(t *testing.T) {
	root := filepath.Join("..", "..", "plugins", "actions")
	err := filepath.WalkDir(root, func(path string, entry fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if entry.IsDir() {
			if entry.Name() == "entry" {
				return filepath.SkipDir
			}
			return nil
		}
		if !strings.HasSuffix(path, ".go") || strings.HasSuffix(path, "_test.go") {
			return nil
		}
		relative, err := filepath.Rel(root, path)
		if err != nil {
			return err
		}
		owner := strings.Split(filepath.ToSlash(relative), "/")[0]
		file, err := parser.ParseFile(token.NewFileSet(), path, nil, parser.ImportsOnly)
		if err != nil {
			return err
		}
		prefix := "github.com/aseman/aseman/plugins/actions/"
		for _, spec := range file.Imports {
			importPath, _ := strconv.Unquote(spec.Path.Value)
			if !strings.HasPrefix(importPath, prefix) {
				continue
			}
			parts := strings.Split(strings.TrimPrefix(importPath, prefix), "/")
			if parts[0] != owner && len(parts) == 1 {
				t.Errorf("namespace %s imports sibling service %s", owner, importPath)
			}
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
}
