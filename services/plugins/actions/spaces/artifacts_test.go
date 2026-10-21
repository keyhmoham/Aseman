package spaces

import (
	"archive/zip"
	"bytes"
	"context"
	"image"
	"image/png"
	"strings"
	"testing"

	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
)

func TestZipValidationInspectsContentsAndRejectsCorruption(t *testing.T) {
	var data bytes.Buffer
	writer := zip.NewWriter(&data)
	member, err := writer.CreateHeader(&zip.FileHeader{Name: "index.html", Method: zip.Store})
	if err != nil {
		t.Fatal(err)
	}
	_, _ = member.Write([]byte("<!doctype html><title>Actual source</title>"))
	readme, err := writer.Create("README.md")
	if err != nil {
		t.Fatal(err)
	}
	_, _ = readme.Write([]byte("Open index.html in a browser."))
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	preview, failure := validateArtifact("site.zip", "application/zip", data.Bytes())
	if failure != "" || !strings.Contains(preview, `"checksums_verified":true`) || !strings.Contains(preview, "Open index.html") || !strings.Contains(preview, "sha256") {
		t.Fatalf("missing archive evidence: %s %s", preview, failure)
	}
	corrupted := bytes.Clone(data.Bytes())
	offset := bytes.Index(corrupted, []byte("Actual source"))
	if offset < 0 {
		t.Fatal("fixture has no stored source")
	}
	corrupted[offset] ^= 1
	if _, failure := validateArtifact("site.zip", "application/zip", corrupted); failure == "" {
		t.Fatal("CRC-corrupt archive accepted")
	}
	if _, failure := validateArtifact("site.zip", "application/zip", []byte("not an archive")); failure == "" {
		t.Fatal("fake ZIP accepted")
	}
}

func TestArtifactValidationRejectsTruncatedImageBody(t *testing.T) {
	var data bytes.Buffer
	if err := png.Encode(&data, image.NewRGBA(image.Rect(0, 0, 4, 4))); err != nil {
		t.Fatal(err)
	}
	truncated := data.Bytes()[:33]
	if _, _, err := image.DecodeConfig(bytes.NewReader(truncated)); err != nil {
		t.Fatalf("fixture must retain image header: %v", err)
	}
	if _, err := validateArtifact("result.png", "image/png", truncated); err == "" {
		t.Fatal("header alone accepted as a complete image")
	}
	if _, err := validateArtifact("result.png", "image/png", data.Bytes()); err != "" {
		t.Fatal(err)
	}
}

func TestSandboxStopRefusesActiveCommand(t *testing.T) {
	s := &Service{}
	space := identity.ID{Node: 1, Entity: 99}
	gate := s.sandboxGate(space)
	gate <- struct{}{}
	defer func() { <-gate }()
	if _, err := s.SandboxStop(context.Background(), space); errs.CodeOf(err) != errs.CodeConflict {
		t.Fatalf("stop during command=%v", err)
	}
}
