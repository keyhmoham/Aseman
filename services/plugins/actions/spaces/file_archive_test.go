package spaces

import (
	"archive/zip"
	"bytes"
	"context"
	"io"
	"testing"
)

func TestArchiveFilesRoundTripsSourcesWithoutSandboxUtilities(t *testing.T) {
	sources := map[string][]byte{"/site/index.html": []byte("<html>website</html>"), "/site/image.bin": {0, 255, 1}, "/site/empty.txt": {}}
	files := []ArchiveFile{{Path: "/site/index.html"}, {Path: "/site/image.bin", Name: "assets/image.bin"}, {Path: "/site/empty.txt"}}
	data, err := archiveFiles(context.Background(), files, func(_ context.Context, path string) ([]byte, error) { return sources[path], nil })
	if err != nil {
		t.Fatal(err)
	}
	archive, err := zip.NewReader(bytes.NewReader(data), int64(len(data)))
	if err != nil {
		t.Fatal(err)
	}
	if len(archive.File) != len(files) {
		t.Fatalf("members=%d", len(archive.File))
	}
	for i, file := range archive.File {
		reader, err := file.Open()
		if err != nil {
			t.Fatal(err)
		}
		got, err := io.ReadAll(reader)
		reader.Close()
		if err != nil {
			t.Fatal(err)
		}
		if !bytes.Equal(got, sources[files[i].Path]) {
			t.Fatalf("corrupt member %s", file.Name)
		}
	}
}

func TestArchiveRejectsInvalidManifestBeforeReading(t *testing.T) {
	for _, name := range []string{"../escape", "/absolute", "..", "a\\b", "a\x00b", "index.html"} {
		t.Run(name, func(t *testing.T) {
			reads := 0
			_, err := archiveFiles(context.Background(), []ArchiveFile{{Path: "/first", Name: "index.html"}, {Path: "/second", Name: name}}, func(context.Context, string) ([]byte, error) { reads++; return nil, nil })
			if err == nil || reads != 0 {
				t.Fatalf("err=%v reads=%d", err, reads)
			}
		})
	}
}

func TestArchiveHonorsCancellation(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	_, err := archiveFiles(ctx, []ArchiveFile{{Path: "/site/file"}}, func(context.Context, string) ([]byte, error) { t.Fatal("read after cancellation"); return nil, nil })
	if err != context.Canceled {
		t.Fatalf("err=%v", err)
	}
}
