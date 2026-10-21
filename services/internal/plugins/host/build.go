package host

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"github.com/aseman/aseman/pkg/errs"
)

// Build compiles a namespace or adapter entry using the host's source tree and
// toolchain. A unique package path isolates the implementation for replacement;
// bridge/core dependencies retain their compatible package identities.
func Build(ctx context.Context, root, source, outdir string) (string, error) {
	if strings.TrimSpace(source) == "" {
		return "", errs.InvalidArgument("plugin source is required")
	}
	root, err := filepath.Abs(root)
	if err != nil {
		return "", err
	}
	sourcePath := source
	if !filepath.IsAbs(sourcePath) {
		sourcePath = filepath.Join(root, sourcePath)
	}
	sourcePath, err = filepath.EvalSymlinks(sourcePath)
	if err != nil {
		return "", err
	}
	relative, err := filepath.Rel(root, sourcePath)
	if err != nil || relative == ".." || strings.HasPrefix(relative, ".."+string(os.PathSeparator)) {
		return "", errs.InvalidArgument("plugin source must be inside node source tree")
	}
	if stat, err := os.Stat(sourcePath); err != nil || !stat.IsDir() {
		return "", errs.InvalidArgument("plugin source must be a directory")
	}
	buildsRoot := filepath.Join(root, "plugins", ".builds")
	buildRelative, err := filepath.Rel(sourcePath, buildsRoot)
	if err != nil || buildRelative == "." || (!strings.HasPrefix(buildRelative, ".."+string(os.PathSeparator)) && buildRelative != "..") {
		return "", errs.InvalidArgument("select an individual namespace or adapter source directory")
	}
	moduleBytes, err := os.ReadFile(filepath.Join(root, "go.mod"))
	if err != nil {
		return "", err
	}
	modulePath := ""
	for _, line := range strings.Split(string(moduleBytes), "\n") {
		if strings.HasPrefix(line, "module ") {
			modulePath = strings.TrimSpace(strings.TrimPrefix(line, "module "))
			break
		}
	}
	if modulePath == "" {
		return "", errs.InvalidArgument("missing module path")
	}
	revision := make([]byte, 12)
	if _, err := rand.Read(revision); err != nil {
		return "", err
	}
	unique := hex.EncodeToString(revision)
	target := filepath.Join(root, "plugins", ".builds", unique)
	if err := os.MkdirAll(target, 0755); err != nil {
		return "", err
	}
	defer os.RemoveAll(target)
	oldImport := modulePath + "/" + filepath.ToSlash(relative)
	newImport := modulePath + "/plugins/.builds/" + unique
	err = filepath.WalkDir(sourcePath, func(path string, entry fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		rel, err := filepath.Rel(sourcePath, path)
		if err != nil {
			return err
		}
		if entry.IsDir() {
			if entry.Name() == ".git" {
				return filepath.SkipDir
			}
			return os.MkdirAll(filepath.Join(target, rel), 0755)
		}
		if entry.Type()&os.ModeSymlink != 0 {
			return errs.InvalidArgument("plugin source cannot contain symlinks")
		}
		if strings.HasSuffix(path, "_test.go") || strings.HasSuffix(path, ".so") {
			return nil
		}
		contents, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		if strings.HasSuffix(path, ".go") {
			contents = []byte(strings.ReplaceAll(string(contents), oldImport, newImport))
		}
		return os.WriteFile(filepath.Join(target, rel), contents, 0644)
	})
	if err != nil {
		return "", err
	}
	entry := target
	if stat, err := os.Stat(filepath.Join(target, "entry")); err == nil && stat.IsDir() {
		entry = filepath.Join(target, "entry")
	}
	if !filepath.IsAbs(outdir) {
		outdir = filepath.Join(root, outdir)
	}
	if err := os.MkdirAll(outdir, 0755); err != nil {
		return "", err
	}
	output := filepath.Join(outdir, filepath.Base(sourcePath)+"-"+unique+".so")
	cmd := exec.CommandContext(ctx, "go", "build", "-trimpath", "-buildmode=plugin", "-o", output, "./"+filepath.ToSlash(strings.TrimPrefix(entry, root+string(os.PathSeparator))))
	cmd.Dir = root
	cmd.Env = append(os.Environ(), "CGO_ENABLED=1")
	result, err := cmd.CombinedOutput()
	if err != nil {
		_ = os.Remove(output)
		return "", errs.Wrap(errs.CodePlugin, err, fmt.Sprintf("build plugin: %s", result))
	}
	return output, nil
}
