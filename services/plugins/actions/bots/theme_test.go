package bots

import (
	"strings"
	"testing"
)

func TestValidateThemePackJSON(t *testing.T) {
	ok := `{"schema":"aseman.theme/v1","meta":{"id":"t1","name":"T"},"tokens":{"light":{},"dark":{}}}`
	if err := validateThemePackJSON(ok); err != nil {
		t.Fatal(err)
	}
	if err := validateThemePackJSON(""); err == nil {
		t.Fatal("expected empty pack error")
	}
	if err := validateThemePackJSON(`{"schema":"other","meta":{"id":"x","name":"X"},"tokens":{}}`); err == nil {
		t.Fatal("expected schema error")
	}
	if err := validateThemePackJSON(`{"meta":{"id":"","name":"X"},"tokens":{}}`); err == nil {
		t.Fatal("expected meta.id error")
	}
	big := `{"schema":"aseman.theme/v1","meta":{"id":"t","name":"T"},"tokens":{"light":{},"dark":{}},"pad":"` + strings.Repeat("x", themePackMaxBytes) + `"}`
	if err := validateThemePackJSON(big); err == nil {
		t.Fatal("expected size error")
	}
}
