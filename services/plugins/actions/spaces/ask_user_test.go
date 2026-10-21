package spaces

import (
	"context"
	"strings"
	"testing"

	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
)

func TestAskUserPreservesConcreteOptionsAndRequiresLaterAnswer(t *testing.T) {
	service := &Service{}
	result, err := service.askUserTool(context.Background(), identity.ID{}, `{"question":"Which audience should this use?","options":["Executives","Engineers"]}`)
	if err != nil || !strings.Contains(result, "Executives") || !strings.Contains(result, "Engineers") || !strings.Contains(result, "End this invocation") {
		t.Fatalf("lost user choices: %q, %v", result, err)
	}
	for _, input := range []string{`{"question":" "}`, `{"question":"Choose?","options":["a","b","c","d"]}`} {
		if _, err := service.askUserTool(context.Background(), identity.ID{}, input); errs.CodeOf(err) != errs.CodeInvalidArgument {
			t.Fatalf("invalid question accepted: %s, %v", input, err)
		}
	}
}
