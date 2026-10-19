// Package webkit is Tradera's web UI kit: the stylesheet and script that give
// web pages agents build (served from a sandbox through a preview gateway)
// the app's own look — its color scheme, shapes and type, and every
// component the Flutter app renders (the A2UI catalog, the tool UI kit, the
// Elpian widgets) — and their client for the Tradera API (a page calls the
// space's tools' microtools as the person using it).
//
// The node serves it at /v1/webkit/<file> and, inside every preview, at
// <preview>/_tradera/kit/<file>, so a page links "/_tradera/kit/tradera-ui.css"
// and "/_tradera/kit/tradera-ui.js" whatever its base path.
package webkit

import (
	"embed"
	"mime"
	"path"
	"strings"
)

//go:embed kit/*
var files embed.FS

// File returns a kit file and its content type; ok is false for a name the
// kit does not have.
func File(name string) (body []byte, contentType string, ok bool) {
	name = strings.TrimLeft(name, "/")
	if name == "" || strings.Contains(name, "..") || strings.Contains(name, "/") {
		return nil, "", false
	}
	body, err := files.ReadFile("kit/" + name)
	if err != nil {
		return nil, "", false
	}
	contentType = mime.TypeByExtension(path.Ext(name))
	switch path.Ext(name) {
	case ".js":
		contentType = "text/javascript; charset=utf-8"
	case ".css":
		contentType = "text/css; charset=utf-8"
	case ".md":
		contentType = "text/markdown; charset=utf-8"
	}
	if contentType == "" {
		contentType = "application/octet-stream"
	}
	return body, contentType, true
}

// Names lists the kit's files.
func Names() []string {
	entries, _ := files.ReadDir("kit")
	out := make([]string, 0, len(entries))
	for _, e := range entries {
		out = append(out, e.Name())
	}
	return out
}
