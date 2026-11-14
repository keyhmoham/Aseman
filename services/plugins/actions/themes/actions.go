package themes

import (
	"context"
	"encoding/json"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/plugins/actions/support/helper"
)

type createAction struct{ s *Service }

func (a *createAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "themes", Name: "create", Summary: "Create a UI theme pack and optionally publish it"}
}
func (a *createAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireAuthenticated(req); err != nil {
		return nil, err
	}
	var in struct {
		Name        string `json:"name"`
		Description string `json:"description,omitempty"`
		Pack        string `json:"pack"`
		Publish     bool   `json:"publish,omitempty"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	themeID, listingID, status, err := a.s.Create(ctx, req.Caller.ID, in.Name, in.Description, in.Pack, in.Publish)
	if err != nil {
		return nil, err
	}
	out := map[string]any{"theme_id": themeID.String(), "status": status, "ok": true}
	if !listingID.IsZero() {
		out["listing_id"] = listingID.String()
	}
	return helper.JSON(out)
}

type editAction struct{ s *Service }

func (a *editAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "themes", Name: "edit", Summary: "Update a theme pack you own"}
}
func (a *editAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireAuthenticated(req); err != nil {
		return nil, err
	}
	var in struct {
		Theme       string `json:"theme"`
		Name        string `json:"name,omitempty"`
		Description string `json:"description,omitempty"`
		Pack        string `json:"pack"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	id, err := identity.Parse(in.Theme)
	if err != nil {
		return nil, errs.InvalidArgument("invalid theme id")
	}
	if err := a.s.Edit(ctx, req.Caller.ID, id, in.Name, in.Description, in.Pack); err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"ok": true})
}

type getAction struct{ s *Service }

func (a *getAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "themes", Name: "get", Summary: "Fetch a theme pack JSON by theme id"}
}
func (a *getAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireAuthenticated(req); err != nil {
		return nil, err
	}
	var in struct {
		Theme string `json:"theme"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	id, err := identity.Parse(in.Theme)
	if err != nil {
		return nil, errs.InvalidArgument("invalid theme id")
	}
	raw, err := a.s.PackJSON(ctx, id)
	if err != nil {
		return nil, err
	}
	var pack any
	_ = json.Unmarshal([]byte(raw), &pack)
	return helper.JSON(map[string]any{"theme_id": id.String(), "pack": pack, "pack_json": raw})
}

type applyAction struct{ s *Service }

func (a *applyAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "themes", Name: "apply", Summary: "Apply a theme pack to your account"}
}
func (a *applyAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireAuthenticated(req); err != nil {
		return nil, err
	}
	var in struct {
		Theme   string `json:"theme,omitempty"`
		Listing string `json:"listing,omitempty"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	switch {
	case in.Listing != "":
		id, err := identity.Parse(in.Listing)
		if err != nil {
			return nil, errs.InvalidArgument("invalid listing id")
		}
		if err := a.s.ApplyFromListing(ctx, req.Caller.ID, id); err != nil {
			return nil, err
		}
	case in.Theme != "":
		id, err := identity.Parse(in.Theme)
		if err != nil {
			return nil, errs.InvalidArgument("invalid theme id")
		}
		if err := a.s.ApplyTheme(ctx, req.Caller.ID, id); err != nil {
			return nil, err
		}
	default:
		return nil, errs.InvalidArgument("theme or listing required")
	}
	return helper.JSON(map[string]any{"ok": true})
}

type activeAction struct{ s *Service }

func (a *activeAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "themes", Name: "active", Summary: "Get a theme just applied in this flow (not session theming — that lives in auth.session_metadata)"}
}
func (a *activeAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireAuthenticated(req); err != nil {
		return nil, err
	}
	// Account-level user_themes is only a write-through for themes.apply in
	// the same client flow. Login / new sessions must not treat this as the
	// session look — session theming starts empty.
	row, err := a.s.Active(ctx, req.Caller.ID)
	if err != nil {
		return nil, err
	}
	if row == nil {
		return helper.JSON(map[string]any{"active": false})
	}
	var pack any
	_ = json.Unmarshal([]byte(row.PackJSON), &pack)
	out := map[string]any{
		"active":    true,
		"theme_id":  row.ThemeID.String(),
		"pack":      pack,
		"pack_json": row.PackJSON,
	}
	if !row.ListingID.IsZero() {
		out["listing_id"] = row.ListingID.String()
	}
	return helper.JSON(out)
}

type uninstallAction struct{ s *Service }

func (a *uninstallAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "themes", Name: "uninstall", Summary: "Clear your applied theme and return to the builtin Sky look"}
}
func (a *uninstallAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireAuthenticated(req); err != nil {
		return nil, err
	}
	if err := a.s.Clear(ctx, req.Caller.ID); err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"ok": true})
}

type importSamplesAction struct{ s *Service }

func (a *importSamplesAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "themes", Name: "import_samples", Summary: "Import sample theme packs into the marketplace (admin)"}
}
func (a *importSamplesAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireAuthenticated(req); err != nil {
		return nil, err
	}
	if err := helper.RequireNodeAdmin(ctx, a.s.R, req, a.s.K.Env()["admin_handle"]); err != nil {
		return nil, err
	}
	n, err := a.s.ImportSamples(ctx, req.Caller.ID)
	if err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"created": n, "ok": true})
}

// BuildActions assembles the themes namespace actions.
func BuildActions(s *Service) []api.Action {
	return []api.Action{
		&createAction{s: s},
		&editAction{s: s},
		&getAction{s: s},
		&applyAction{s: s},
		&activeAction{s: s},
		&uninstallAction{s: s},
		&importSamplesAction{s: s},
	}
}
