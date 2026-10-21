// Package local implements the file storage port on the local filesystem. It
// is the default storage (zero configuration).
package local

import (
	"context"
	"io"
	"os"
	"path/filepath"
	"strings"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/pkg/logger"
	"github.com/aseman/aseman/plugins/adapters/base"
	"github.com/aseman/aseman/plugins/adapters/cfg"
	"github.com/aseman/aseman/plugins/adapters/filesystem/ports"
)

// Adapter is the local disk storage plugin.
type Adapter struct {
	base.Base
	basePath string
}

// New creates the adapter plugin.
func New(log *logger.Logger) *Adapter {
	return &Adapter{
		Base: base.Base{
			Name:        "local",
			Category:    api.CategoryFilesystem,
			Version:     "1.0.0",
			Description: "Local filesystem object storage (default)",
			Provides:    []string{"filesystem", "storage"},
			Log:         log,
		},
	}
}

// Init implements api.Plugin.
func (a *Adapter) Init(ctx context.Context, deps *api.Dependencies) error {
	a.HealthCheck = base.WireHealth(a.Health)

	a.Log = deps.Logger
	c := cfg.Filesystem(deps.Config)
	if c.BasePath == "" {
		c.BasePath = "./data/files"
	}
	return a.Open(ctx, c)
}

// Start implements api.Plugin.
func (a *Adapter) Start(ctx context.Context) error { return nil }

// Stop implements api.Plugin.
func (a *Adapter) Stop(ctx context.Context) error { return a.Close(ctx) }

// Name implements filesystem.FileStorage.
func (a *Adapter) Name() string { return "local" }

// Open implements filesystem.FileStorage.
func (a *Adapter) Open(ctx context.Context, c filesystem.Config) error {
	if c.BasePath == "" {
		return errs.InvalidArgument("local storage requires config.base_path")
	}
	if err := os.MkdirAll(c.BasePath, 0o755); err != nil {
		return errs.Wrap(errs.CodePlugin, err, "create base path")
	}
	a.basePath = c.BasePath
	return nil
}

// Close implements filesystem.FileStorage.
func (a *Adapter) Close(ctx context.Context) error { return nil }

// Health implements filesystem.FileStorage.
func (a *Adapter) Health(ctx context.Context) filesystem.Health {
	if a.basePath == "" {
		return filesystem.Health{OK: false, Message: "local storage not open"}
	}
	if _, err := os.Stat(a.basePath); err != nil {
		return filesystem.Health{OK: false, Message: err.Error()}
	}
	return filesystem.Health{OK: true, Message: "local storage healthy"}
}

// safePath resolves a key under basePath, rejecting traversal. The base path is
// normalized to an absolute path first so the containment check is correct even
// when config.base_path is relative (e.g. "./data/files").
func (a *Adapter) safePath(key string) (string, error) {
	base, err := filepath.Abs(a.basePath)
	if err != nil {
		return "", err
	}
	clean := filepath.Clean("/" + strings.TrimPrefix(key, "/"))
	abs := filepath.Join(base, filepath.FromSlash(clean))
	if !strings.HasPrefix(abs, base+string(filepath.Separator)) {
		return "", errs.InvalidArgument("storage key escapes base path")
	}
	return abs, nil
}

// Put implements filesystem.FileStorage.
func (a *Adapter) Put(ctx context.Context, key string, r io.Reader, size int64, contentType string) error {
	p, err := a.safePath(key)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		return errs.Wrap(errs.CodePlugin, err, "create dirs")
	}
	f, err := os.Create(p)
	if err != nil {
		return errs.Wrap(errs.CodePlugin, err, "create file")
	}
	defer f.Close()
	if _, err := io.Copy(f, r); err != nil {
		return errs.Wrap(errs.CodePlugin, err, "write file")
	}
	return nil
}

// Get implements filesystem.FileStorage.
func (a *Adapter) Get(ctx context.Context, key string) (io.ReadCloser, error) {
	p, err := a.safePath(key)
	if err != nil {
		return nil, err
	}
	f, err := os.Open(p)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, errs.NotFound("object " + key)
		}
		return nil, errs.Wrap(errs.CodePlugin, err, "open file")
	}
	return f, nil
}

// Delete implements filesystem.FileStorage.
func (a *Adapter) Delete(ctx context.Context, key string) error {
	p, err := a.safePath(key)
	if err != nil {
		return err
	}
	if err := os.Remove(p); err != nil {
		if os.IsNotExist(err) {
			return errs.NotFound("object " + key)
		}
		return errs.Wrap(errs.CodePlugin, err, "remove file")
	}
	return nil
}

// Stat implements filesystem.FileStorage.
func (a *Adapter) Stat(ctx context.Context, key string) (filesystem.ObjectInfo, error) {
	p, err := a.safePath(key)
	if err != nil {
		return filesystem.ObjectInfo{}, err
	}
	st, err := os.Stat(p)
	if err != nil {
		if os.IsNotExist(err) {
			return filesystem.ObjectInfo{}, errs.NotFound("object " + key)
		}
		return filesystem.ObjectInfo{}, errs.Wrap(errs.CodePlugin, err, "stat file")
	}
	return filesystem.ObjectInfo{
		Key:      key,
		Size:     st.Size(),
		Modified: st.ModTime(),
	}, nil
}

// Exists implements filesystem.FileStorage.
func (a *Adapter) Exists(ctx context.Context, key string) (bool, error) {
	p, err := a.safePath(key)
	if err != nil {
		return false, err
	}
	_, err = os.Stat(p)
	return err == nil, nil
}

// List implements filesystem.FileStorage.
func (a *Adapter) List(ctx context.Context, prefix string) ([]filesystem.ObjectInfo, error) {
	base, err := filepath.Abs(a.basePath)
	if err != nil {
		return nil, err
	}
	root := filepath.Join(base, filepath.FromSlash(strings.TrimPrefix(prefix, "/")))
	var out []filesystem.ObjectInfo
	err = filepath.Walk(root, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return nil
		}
		if info.IsDir() {
			return nil
		}
		rel, err := filepath.Rel(base, path)
		if err != nil {
			return nil
		}
		out = append(out, filesystem.ObjectInfo{
			Key:      filepath.ToSlash(rel),
			Size:     info.Size(),
			Modified: info.ModTime(),
		})
		return nil
	})
	if err != nil {
		return nil, errs.Wrap(errs.CodePlugin, err, "list objects")
	}
	return out, nil
}
