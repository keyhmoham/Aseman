package spaces

import (
	"bytes"
	"encoding/csv"
	"encoding/json"
	"fmt"
	"image"
	_ "image/gif"
	_ "image/jpeg"
	_ "image/png"
	"path/filepath"
	"strings"
)

// Structural checks complement the inspector's assessment of task-specific
// content. Preview text gives the inspector evidence beyond a filename.
func validateArtifact(name, mime string, data []byte) (string, string) {
	if len(data) == 0 {
		return "", "File is empty."
	}
	extension := strings.ToLower(filepath.Ext(name))
	switch {
	case extension == ".zip" || mime == "application/zip":
		return validateZipArtifact(data)
	case extension == ".html" || extension == ".htm" || mime == "text/html":
		inspection, _, err := inspectHTML(data)
		if err != nil {
			return "", "HTML could not be parsed."
		}
		preview, _ := json.Marshal(map[string]any{"sha256": inspection.SHA256, "title": inspection.Title, "headings": inspection.Headings[:min(12, len(inspection.Headings))], "elements": inspection.Elements, "checks": inspection.Checks, "limitations": inspection.Limitations})
		return truncateText(string(preview), 3000), ""
	case mime == "image/png" || mime == "image/jpeg" || mime == "image/gif":
		config, format, err := image.DecodeConfig(bytes.NewReader(data))
		if err != nil {
			return "", err.Error()
		}
		if config.Width <= 0 || config.Height <= 0 || int64(config.Width)*int64(config.Height) > 64000000 {
			return "", "Image dimensions exceed validation limits."
		}
		if _, _, err := image.Decode(bytes.NewReader(data)); err != nil {
			return "", err.Error()
		}
		return fmt.Sprintf("%s image, %dx%d pixels", format, config.Width, config.Height), ""
	case extension == ".json":
		if !json.Valid(data) {
			return "", "Malformed JSON."
		}
	case extension == ".csv":
		reader := csv.NewReader(bytes.NewReader(data))
		if _, err := reader.ReadAll(); err != nil {
			return "", err.Error()
		}
	case mime == "application/pdf" || extension == ".pdf":
		if !bytes.HasPrefix(data, []byte("%PDF-")) || !bytes.Contains(data[max(0, len(data)-1024):], []byte("%%EOF")) {
			return "", "Invalid PDF signature."
		}
	}
	if isTextFile(mime, name) {
		if len(data) > 3000 {
			data = data[:3000]
		}
		return string(data), ""
	}
	return fmt.Sprintf("%d bytes; content-specific checks still required", len(data)), ""
}
