package posts

import (
	"testing"

	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/plugins/actions/posts/models"
)

// TestUpdateEditsOnlyMyPost proves the author can edit a post, which marks
// it edited, and nobody else can.
func TestUpdateEditsOnlyMyPost(t *testing.T) {
	s, ctx := feedHarness(t)
	author, _ := identity.New(1)
	other, _ := identity.New(1)
	p, err := s.Create(ctx, author, identity.ID{}, identity.ID{}, "first", nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.Update(ctx, other, p.ID, "hijacked"); errs.CodeOf(err) != errs.CodePermission {
		t.Fatalf("another account edited the post: %v", err)
	}
	if _, err := s.Update(ctx, author, p.ID, "  "); err == nil {
		t.Fatal("an empty body was accepted")
	}
	if _, err := s.Update(ctx, author, p.ID, "second"); err != nil {
		t.Fatal(err)
	}
	got, err := s.Get(ctx, p.ID)
	if err != nil {
		t.Fatal(err)
	}
	if got.Body != "second" || got.EditedAt.IsZero() {
		t.Fatalf("edit not saved: body %q edited %v", got.Body, got.EditedAt)
	}
	view := s.Views(ctx, author, []post.Post{*got})[0]
	if _, ok := view["edited_at"]; !ok {
		t.Fatal("the view does not say the post was edited")
	}
}

// TestForwardNamesTheOriginalAuthor proves a shared post copies its
// original, names who wrote it, and that sharing a share names the first
// author, not the one who shared it.
func TestForwardNamesTheOriginalAuthor(t *testing.T) {
	s, ctx := feedHarness(t)
	alice, _ := identity.New(1)
	bob, _ := identity.New(1)
	carol, _ := identity.New(1)
	orig, err := s.Create(ctx, alice, identity.ID{}, identity.ID{}, "alice's take", []string{"btc"}, nil)
	if err != nil {
		t.Fatal(err)
	}
	shared, err := s.Forward(ctx, bob, identity.ID{}, orig.ID)
	if err != nil {
		t.Fatal(err)
	}
	if shared.AuthorID != bob || shared.ForwardOf != orig.ID || shared.ForwardAuthorID != alice || shared.Body != orig.Body {
		t.Fatalf("shared post %+v", shared)
	}
	again, err := s.Forward(ctx, carol, identity.ID{}, shared.ID)
	if err != nil {
		t.Fatal(err)
	}
	if again.ForwardOf != orig.ID || again.ForwardAuthorID != alice {
		t.Fatalf("a share of a share must name the original: %+v", again)
	}
	view := s.Views(ctx, carol, []post.Post{*again})[0]
	fwd, _ := view["forward_author"].(map[string]any)
	if view["forward_of"] != orig.ID.String() || fwd["id"] != alice.String() {
		t.Fatalf("view %v", view)
	}
	if _, err := s.Update(ctx, bob, shared.ID, "rewritten"); err == nil {
		t.Fatal("a shared post was edited")
	}
}

// TestForwardIntoSpaceNeedsMembership proves a post can only be shared into
// a workspace feed the caller is a member of.
func TestForwardIntoSpaceNeedsMembership(t *testing.T) {
	s, ctx := feedHarness(t)
	alice, _ := identity.New(1)
	bob, _ := identity.New(1)
	space, _ := identity.New(1)
	orig, err := s.Create(ctx, alice, identity.ID{}, identity.ID{}, "public", nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.Forward(ctx, bob, space, orig.ID); err == nil {
		t.Fatal("shared into a space the caller is not in")
	}
	memID, _ := identity.New(1)
	if err := s.R.CreateID(ctx, "memberships", memID, &membershipRow{SpaceID: space.String(), MemberID: bob.String()}); err != nil {
		t.Fatal(err)
	}
	shared, err := s.Forward(ctx, bob, space, orig.ID)
	if err != nil {
		t.Fatal(err)
	}
	if shared.SpaceID != space {
		t.Fatalf("shared into %v, want %v", shared.SpaceID, space)
	}
}

// TestReportFilesOnceAndAdminsResolve proves a report is filed once per
// reporter and post, that authors cannot report themselves, and that an
// admin's removal deletes the post and resolves the report.
func TestReportFilesOnceAndAdminsResolve(t *testing.T) {
	s, ctx := feedHarness(t)
	alice, _ := identity.New(1)
	bob, _ := identity.New(1)
	admin, _ := identity.New(1)
	p, err := s.Create(ctx, alice, identity.ID{}, identity.ID{}, "buy my coin", nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.Report(ctx, alice, p.ID, "spam", ""); err == nil {
		t.Fatal("the author reported their own post")
	}
	if _, err := s.Report(ctx, bob, p.ID, "nonsense", ""); err == nil {
		t.Fatal("an unknown reason was accepted")
	}
	first, err := s.Report(ctx, bob, p.ID, "spam", "")
	if err != nil {
		t.Fatal(err)
	}
	second, err := s.Report(ctx, bob, p.ID, "scam", "it is a scam")
	if err != nil {
		t.Fatal(err)
	}
	if first.ID != second.ID {
		t.Fatal("reporting again filed a second report")
	}
	rows, open, err := s.Reports(ctx, "", 0)
	if err != nil {
		t.Fatal(err)
	}
	if open != 1 || len(rows) != 1 || rows[0]["reason"] != "scam" || rows[0]["body"] != "buy my coin" {
		t.Fatalf("reports %v open %d", rows, open)
	}
	if err := s.RemoveReported(ctx, admin, p.ID); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Get(ctx, p.ID); err == nil {
		t.Fatal("the reported post is still there")
	}
	_, open, err = s.Reports(ctx, "", 0)
	if err != nil {
		t.Fatal(err)
	}
	if open != 0 {
		t.Fatalf("%d reports still open", open)
	}
}
