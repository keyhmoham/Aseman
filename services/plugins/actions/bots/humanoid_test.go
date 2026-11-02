package bots

import "testing"

func TestRandomHumanoidRanges(t *testing.T) {
	seenSkin, seenHair := map[int]bool{}, map[int]bool{}
	for i := 0; i < 80; i++ {
		h := randomHumanoid()
		skin, _ := h["skin"].(int)
		hair, _ := h["hair"].(int)
		if skin < 0 || skin >= humanoidSkinCount {
			t.Fatalf("skin out of range: %v", h)
		}
		if hair < 0 || hair >= humanoidHairCount {
			t.Fatalf("hair out of range: %v", h)
		}
		seenSkin[skin] = true
		seenHair[hair] = true
	}
	if len(seenSkin) < 2 || len(seenHair) < 2 {
		t.Fatalf("expected variety across draws: skin=%v hair=%v", seenSkin, seenHair)
	}
}
