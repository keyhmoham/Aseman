// Package asemanopenui is the App UI OpenUI kit: agent-backed UI islands that
// app builders mix with programmed components under the same Aseman theme.
package asemanopenui

import (
	"embed"
	"io/fs"
	"path"
	"strings"
)

//go:embed embed/*
var embedded embed.FS

// File returns a kit asset (openui.js, openui.css, README.md, …).
func File(name string) ([]byte, error) {
	name = path.Clean("/" + strings.TrimPrefix(name, "/"))
	name = strings.TrimPrefix(name, "/")
	if name == "" || strings.Contains(name, "..") {
		return nil, fs.ErrNotExist
	}
	return embedded.ReadFile(path.Join("embed", name))
}

// FS is the kit filesystem rooted at embed/.
func FS() fs.FS {
	sub, err := fs.Sub(embedded, "embed")
	if err != nil {
		return embedded
	}
	return sub
}
