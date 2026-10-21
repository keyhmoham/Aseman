package host_test

import (
	"context"
	"path/filepath"
	"testing"

	"github.com/aseman/aseman/internal/plugins/host"
)

func TestBuildRejectsEmptyOrRecursiveSource(t *testing.T) {
	root, err := filepath.Abs("../../..")
	if err != nil {
		t.Fatal(err)
	}
	for _, source := range []string{"", ".", "plugins"} {
		if _, err := host.Build(context.Background(), root, source, t.TempDir()); err == nil {
			t.Errorf("accepted recursive source %q", source)
		}
	}
}
