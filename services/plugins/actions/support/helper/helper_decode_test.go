package helper

import (
	"testing"

	"github.com/aseman/aseman/internal/plugins/api"
)

func TestDecodeTakesAnEmptyBodyAsNoFields(t *testing.T) {
	var in struct {
		Space string `json:"space"`
	}
	if err := Decode(&api.ActionRequest{}, &in); err != nil || in.Space != "" {
		t.Fatalf("an empty body is {}: %v", err)
	}
	if err := Decode(&api.ActionRequest{Body: []byte("{")}, &in); err == nil {
		t.Fatal("a broken body is still refused")
	}
}
