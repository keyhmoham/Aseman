package agui

import "testing"

func TestClassifyHITLAlwaysChat(t *testing.T) {
	d := Classify(Signals{NeedsHumanInput: true, StructuredData: true})
	if d.Placement != PlacementChat || d.Medium != MediumAgui {
		t.Fatalf("got %+v", d)
	}
}

func TestClassifyComplexNonInteractiveDeskAgui(t *testing.T) {
	d := Classify(Signals{StructuredData: true, HighComplexity: true})
	if d.Placement != PlacementDesk || d.Medium != MediumAgui {
		t.Fatalf("got %+v", d)
	}
}

func TestClassifyInteractiveComplexAPIsAppui(t *testing.T) {
	d := Classify(Signals{
		NeedsInteractivity: true, HighComplexity: true, NeedsAPIs: true,
	})
	if d.Placement != PlacementDesk || d.Medium != MediumAppui {
		t.Fatalf("got %+v", d)
	}
}

func TestClassifyAppRequestAppui(t *testing.T) {
	d := Classify(Signals{UserAskedForApp: true})
	if d.Placement != PlacementDesk || d.Medium != MediumAppui {
		t.Fatalf("got %+v", d)
	}
}

func TestClassifyLowComplexityStructuredChat(t *testing.T) {
	d := Classify(Signals{StructuredData: true})
	if d.Placement != PlacementChat || d.Medium != MediumAgui {
		t.Fatalf("got %+v", d)
	}
}

func TestClassifyMinimalOverridesComplexDesk(t *testing.T) {
	d := Classify(Signals{StructuredData: true, HighComplexity: true, ExplicitMinimal: true})
	if d.Placement != PlacementChat || d.Medium != MediumAgui {
		t.Fatalf("got %+v", d)
	}
}

func TestInferComplexReport(t *testing.T) {
	s := InferSignals("show a large detailed multi-panel report of the metrics")
	if !s.StructuredData || !s.HighComplexity {
		t.Fatalf("got %+v", s)
	}
	d := Classify(s)
	if d.Medium != MediumAgui || d.Placement != PlacementDesk {
		t.Fatalf("got %+v", d)
	}
}

func TestInferAndFenceRoundTrip(t *testing.T) {
	s := InferSignals("which color should we use?")
	if !s.NeedsHumanInput {
		t.Fatal("expected HITL")
	}
	surf := QuestionSurface("Pick a color", []string{"red", "blue"})
	body, err := FormatMessage("Quick pick:", surf)
	if err != nil {
		t.Fatal(err)
	}
	got, rest, ok := ParseFence(body)
	if !ok || got == nil || got.Root == nil {
		t.Fatalf("parse failed: %v %v", ok, body)
	}
	if rest != "Quick pick:" {
		t.Fatalf("rest %q", rest)
	}
}

func TestValidateRoot(t *testing.T) {
	if err := ValidateRoot(Surface{Root: map[string]any{"c": "Nope"}}); err == nil {
		t.Fatal("expected error")
	}
	if err := ValidateRoot(Surface{Root: map[string]any{"c": "Stat"}}); err != nil {
		t.Fatal(err)
	}
}
