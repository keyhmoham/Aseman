package spaces

import (
	"context"
	"encoding/json"
	"testing"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/plugins/actions/spaces/models/membership"
	database "github.com/aseman/aseman/plugins/adapters/database/ports"
)

func TestTheLeadHiresAMarketplaceAgentIntoTheSpace(t *testing.T) {
	s, ctx := fileToolHarness(t)
	owner := idFromHex(t, "00000000000000010000000000000001")
	sp, err := s.CreateSpace(ctx, owner, "launch team", "")
	if err != nil {
		t.Fatal(err)
	}
	elsewhere, err := s.CreateSpace(ctx, idFromHex(t, "00000000000000010000000000000002"), "publisher's space", "")
	if err != nil {
		t.Fatal(err)
	}
	analyst := addAgent(t, s, ctx, elsewhere.ID, "data-analyst", "vm-analyst")
	listing := idFromHex(t, "00000000000000010000000000000077")
	var installed []identity.ID
	s.hireFn = func(ctx context.Context, by, listingID, spaceID identity.ID) (identity.ID, error) {
		if listingID != listing {
			t.Fatalf("listing %s", listingID)
		}
		installed = append(installed, by)
		return analyst.ID, s.AddBot(ctx, by, spaceID, identity.ID{}, analyst.ID)
	}
	hire := func(caller identity.ID) (*api.ActionResponse, error) {
		body, _ := json.Marshal(map[string]string{"space": sp.ID.String(), "listing": listing.String()})
		return s.agentHire(ctx, &api.ActionRequest{Caller: api.Caller{ID: caller, Kind: "user"}, Body: body})
	}
	if _, err := hire(idFromHex(t, "00000000000000010000000000000003")); err == nil {
		t.Fatal("someone who cannot manage the space's agents cannot hire into it")
	}
	resp, err := hire(owner)
	if err != nil {
		t.Fatal(err)
	}
	var out map[string]string
	if err := json.Unmarshal(resp.Body, &out); err != nil {
		t.Fatal(err)
	}
	if out["bot_id"] != analyst.ID.String() || out["account_id"] != analyst.AccountID.String() || out["name"] != "data-analyst" {
		t.Fatalf("hired: %v", out)
	}
	if len(installed) != 1 || installed[0] != owner {
		t.Fatalf("installed by the payer: %v", installed)
	}
	var mems []membership.Membership
	if err := s.R.List(ctx, "memberships", database.Filter{Equal: map[string]any{
		"space_id": sp.ID.String(), "member_id": analyst.AccountID.String()}}, &mems); err != nil || len(mems) != 1 {
		t.Fatalf("the agent is a member of the space: %v %v", mems, err)
	}
}
