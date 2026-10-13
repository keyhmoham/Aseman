package spaces

import (
	"archive/zip"
	"bytes"
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"io"
	"path"
	"strings"
)

// Validate actual archive bytes and bounded contents, rather than treating a
// filename or a worker's packaging claim as structural proof.
func validateZipArtifact(data []byte) (string, string) {
	archive, err := zip.NewReader(bytes.NewReader(data), int64(len(data)))
	if err != nil {
		return "", "Malformed ZIP archive."
	}
	if len(archive.File) == 0 || len(archive.File) > 1000 {
		return "", "ZIP entry count is empty or exceeds validation limits."
	}
	total := uint64(0)
	seen := map[string]bool{}
	members := []map[string]any{}
	for _, file := range archive.File {
		name := path.Clean(file.Name)
		if path.IsAbs(name) || name == ".." || strings.HasPrefix(name, "../") || strings.ContainsAny(file.Name, "\\:") || seen[name] {
			return "", "ZIP contains unsafe or duplicate member paths."
		}
		seen[name] = true
		if !file.Mode().IsRegular() && !file.FileInfo().IsDir() {
			return "", "ZIP contains unsupported special files."
		}
		if file.FileInfo().IsDir() {
			continue
		}
		if file.UncompressedSize64 > maxFileSize || total > maxFileSize-file.UncompressedSize64 {
			return "", "Expanded ZIP exceeds validation limits."
		}
		total += file.UncompressedSize64
		reader, err := file.Open()
		if err != nil {
			return "", "ZIP member could not be opened."
		}
		content, readErr := io.ReadAll(io.LimitReader(reader, maxFileSize+1))
		closeErr := reader.Close()
		if readErr != nil || closeErr != nil || len(content) > maxFileSize || uint64(len(content)) != file.UncompressedSize64 {
			return "", "ZIP member failed size or checksum validation."
		}
		if len(members) < 30 {
			member := map[string]any{"name": truncateText(name, 200), "bytes": len(content), "sha256": fmt.Sprintf("%x", sha256.Sum256(content))}
			if strings.EqualFold(path.Base(name), "README.md") {
				member["preview"] = truncateText(string(content), 1500)
			}
			members = append(members, member)
		}
	}
	preview, _ := json.Marshal(map[string]any{"format": "zip", "checksums_verified": true, "entry_count": len(archive.File), "expanded_bytes": total, "members": members, "inventory_truncated": len(archive.File) > len(members), "limitation": "Archive structure and bytes are verified; member functionality still requires task-specific checks."})
	return truncateText(string(preview), 6000), ""
}
