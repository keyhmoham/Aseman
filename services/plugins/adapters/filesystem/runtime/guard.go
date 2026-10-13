package runtime

import (
	"context"
	"io"
	"sync"

	"github.com/tradera/tradera/internal/plugins/lifetime"
	"github.com/tradera/tradera/plugins/adapters/filesystem/ports"
)

type guardedFilesystem struct {
	port filesystem.FileStorage
	gate *lifetime.Gate
}

func (p *guardedFilesystem) Name() string {
	var zero0 string
	operationCtx, release, err := p.gate.Acquire(context.Background())
	if err != nil {
		return zero0
	}
	defer release()
	_ = operationCtx
	return p.port.Name()
}
func (p *guardedFilesystem) Open(ctx context.Context, cfg filesystem.Config) error {
	operationCtx, release, err := p.gate.Acquire(ctx)
	if err != nil {
		return err
	}
	defer release()
	ctx = operationCtx
	return p.port.Open(ctx, cfg)
}
func (p *guardedFilesystem) Close(ctx context.Context) error {
	operationCtx, release, err := p.gate.Acquire(ctx)
	if err != nil {
		return err
	}
	defer release()
	ctx = operationCtx
	return p.port.Close(ctx)
}
func (p *guardedFilesystem) Health(ctx context.Context) filesystem.Health {
	var zero0 filesystem.Health
	operationCtx, release, err := p.gate.Acquire(ctx)
	if err != nil {
		return zero0
	}
	defer release()
	ctx = operationCtx
	return p.port.Health(ctx)
}
func (p *guardedFilesystem) Put(ctx context.Context, key string, r io.Reader, size int64, contentType string) error {
	operationCtx, release, err := p.gate.Acquire(ctx)
	if err != nil {
		return err
	}
	defer release()
	ctx = operationCtx
	return p.port.Put(ctx, key, r, size, contentType)
}
func (p *guardedFilesystem) Get(ctx context.Context, key string) (io.ReadCloser, error) {
	ctx, release, err := p.gate.Acquire(ctx)
	if err != nil {
		return nil, err
	}
	reader, err := p.port.Get(ctx, key)
	if err != nil {
		release()
		return nil, err
	}
	return &leasedReader{ReadCloser: reader, release: release}, nil
}

func (p *guardedFilesystem) Delete(ctx context.Context, key string) error {
	operationCtx, release, err := p.gate.Acquire(ctx)
	if err != nil {
		return err
	}
	defer release()
	ctx = operationCtx
	return p.port.Delete(ctx, key)
}
func (p *guardedFilesystem) Stat(ctx context.Context, key string) (filesystem.ObjectInfo, error) {
	var zero0 filesystem.ObjectInfo
	operationCtx, release, err := p.gate.Acquire(ctx)
	if err != nil {
		return zero0, err
	}
	defer release()
	ctx = operationCtx
	return p.port.Stat(ctx, key)
}
func (p *guardedFilesystem) Exists(ctx context.Context, key string) (bool, error) {
	var zero0 bool
	operationCtx, release, err := p.gate.Acquire(ctx)
	if err != nil {
		return zero0, err
	}
	defer release()
	ctx = operationCtx
	return p.port.Exists(ctx, key)
}
func (p *guardedFilesystem) List(ctx context.Context, prefix string) ([]filesystem.ObjectInfo, error) {
	var zero0 []filesystem.ObjectInfo
	operationCtx, release, err := p.gate.Acquire(ctx)
	if err != nil {
		return zero0, err
	}
	defer release()
	ctx = operationCtx
	return p.port.List(ctx, prefix)
}

type leasedReader struct {
	io.ReadCloser
	release func()
	once    sync.Once
}

func (r *leasedReader) Close() error { err := r.ReadCloser.Close(); r.once.Do(r.release); return err }

func Guard(port filesystem.FileStorage, gate *lifetime.Gate) filesystem.FileStorage {
	return &guardedFilesystem{port: port, gate: gate}
}
