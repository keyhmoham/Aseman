package spaces

import (
	"archive/zip"
	"bytes"
	"context"
	"path"
	"strings"

	"github.com/tradera/tradera/pkg/errs"
)

// ArchiveFile is a sandbox source and its relative name in a delivered archive.
type ArchiveFile struct {
	Path string `json:"path"`
	Name string `json:"name,omitempty"`
}

func archiveFiles(ctx context.Context, files []ArchiveFile, read func(context.Context, string) ([]byte, error)) ([]byte, error) {
	if len(files) == 0 || len(files) > 256 {
		return nil, errs.InvalidArgument("archive requires 1..256 files")
	}
	// Validate the entire manifest before reading any content.
	names := make([]string, len(files))
	seen := map[string]bool{}
	for i, file := range files {
		name := file.Name
		if name == "" {
			name = path.Base(file.Path)
		}
		clean := path.Clean(name)
		if file.Path == "" || clean == "." || clean == ".." || strings.HasPrefix(clean, "../") || path.IsAbs(clean) || strings.ContainsAny(name, "\\\x00") || seen[clean] {
			return nil, errs.InvalidArgument("invalid or duplicate archive member: " + name)
		}
		names[i] = clean
		seen[clean] = true
	}
	var buf bytes.Buffer
	writer := zip.NewWriter(&buf)
	var total int
	for i, file := range files {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		data, err := read(ctx, file.Path)
		if err != nil {
			return nil, err
		}
		total += len(data)
		if total > maxFileSize {
			return nil, errs.InvalidArgument("archive source size exceeds file limit")
		}
		member, err := writer.Create(names[i])
		if err != nil {
			return nil, err
		}
		if _, err = member.Write(data); err != nil {
			return nil, err
		}
	}
	if err := writer.Close(); err != nil {
		return nil, err
	}
	if buf.Len() > maxFileSize {
		return nil, errs.InvalidArgument("archive exceeds file limit")
	}
	return buf.Bytes(), nil
}

func shellFilePath(path string) string {
	if strings.HasPrefix(path, "-") {
		path = "./" + path
	}
	return "'" + strings.ReplaceAll(path, "'", "'\\''") + "'"
}
