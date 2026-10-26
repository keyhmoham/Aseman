package spaces

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"time"

	"github.com/aseman/aseman/internal/plugins/entity"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/plugins/actions/spaces/models/permission"
	"github.com/aseman/aseman/plugins/actions/spaces/models/proxy"
	"github.com/aseman/aseman/plugins/actions/support/helper"
	"github.com/aseman/aseman/plugins/adapters/database/ports"
	"github.com/aseman/aseman/plugins/adapters/vmm/ports"
)

// tunnelVM is the VMM surface the sandbox provider must expose to open a port
// to the outside (implemented by the Modal adapter via connect tokens).
type tunnelVM interface {
	CreateTunnel(ctx context.Context, vmID string, port int) (targetURL, token string, err error)
}

// CreateProxy opens a gateway proxy to a port of the space's sandbox (as
// aseman) and posts the webview-shortcut card message in the room so users
// can open the served page. Returns the gateway path for the orchestrator.
func (s *Service) CreateProxy(ctx context.Context, spaceID, roomID identity.ID, port int, title string) (string, error) {
	dec, err := s.AsemanAccount(ctx)
	if err != nil {
		return "", err
	}
	p, err := s.ProxyCreate(ctx, spaceID, roomID, dec, port, title)
	if err != nil {
		return "", err
	}
	_ = s.PostMessage(ctx, spaceID, roomID, dec, fmt.Sprintf(
		"🔗 **%s** preview gateway created. Readiness must be verified after starting the service.\n\nOpen it: %s", p.Title, p.GatewayPath()))
	return p.GatewayPath(), nil
}

// ProxyCreate opens a gateway tunnel to a port of the space's Modal sandbox and
// records it, so users of the space can open whatever is served on that port
// (a landing page, an HTTP route, a dev server) in a webview via the gateway.
func (s *Service) ProxyCreate(ctx context.Context, spaceID, roomID, owner identity.ID, port int, title string) (*proxy.Proxy, error) {
	return s.proxyCreate(ctx, spaceID, roomID, owner, port, title, false)
}

// Apps configured with a public base path need the gateway prefix forwarded
// upstream as well. Persist it in the existing target URL, without schema changes.
func (s *Service) proxyCreate(ctx context.Context, spaceID, roomID, owner identity.ID, port int, title string, preservePath bool) (*proxy.Proxy, error) {
	if preservePath {
		s.proxyCreateMu.Lock()
		defer s.proxyCreateMu.Unlock()
	}
	if port <= 0 || port > 65535 {
		return nil, errs.InvalidArgument("port must be in 1..65535")
	}
	requestedTitle := title
	if title == "" {
		title = "Sandbox service"
	}
	rec, err := s.SandboxStart(ctx, spaceID)
	if err != nil {
		return nil, err
	}
	vm := s.K.VMMFor(vmm.Type(rec.VMType))
	tv, ok := vm.(tunnelVM)
	if !ok {
		return nil, errs.New(errs.CodeUnavailable, "sandbox provider does not support proxying")
	}
	targetURL, token, err := tv.CreateTunnel(ctx, rec.VMID, port)
	if err != nil {
		return nil, err
	}
	// A build-time prefix must remain stable across review/publication/retries.
	// Reuse this caller's matching path-preserving preview and refresh its tunnel
	// credentials, without changing the gateway ID or touching another room.
	if preservePath {
		list, err := s.ProxyList(ctx, spaceID)
		if err != nil {
			return nil, err
		}
		if existing := reusablePathProxy(list, roomID, owner, port); existing != nil {
			existing.TargetURL = strings.TrimRight(targetURL, "/") + existing.GatewayPath()
			existing.Token, existing.UpdatedAt = token, time.Now().UTC()
			if requestedTitle != "" {
				existing.Title = requestedTitle
			}
			if err := s.saveProxy(ctx, existing, false); err != nil {
				return nil, err
			}
			s.holdPreview(spaceID)
			return existing, nil
		}
	}
	id, err := identity.New(s.K.NodeID())
	if err != nil {
		return nil, err
	}
	now := time.Now().UTC()
	p := &proxy.Proxy{
		Entity:  entity.Entity{ID: id, CreatedAt: now, UpdatedAt: now},
		SpaceID: spaceID, RoomID: roomID, OwnerID: owner,
		Port: port, Title: title,
		TargetURL: targetURL, Token: token,
		Path: "/v1/proxy/" + id.String() + "/",
	}
	if preservePath {
		p.TargetURL = strings.TrimRight(p.TargetURL, "/") + p.GatewayPath()
	}
	if err := s.saveProxy(ctx, p, true); err != nil {
		return nil, err
	}
	s.holdPreview(spaceID)
	s.L.Info("proxy created", "space", spaceID.String(), "proxy", id.String(), "port", port)
	return p, nil
}

// ProxyGet loads a proxy by id.
func (s *Service) ProxyGet(ctx context.Context, id identity.ID) (*proxy.Proxy, error) {
	p := &proxy.Proxy{}
	if err := s.R.Get(ctx, "proxies", id, p); err != nil {
		return nil, err
	}
	if err := s.openProxyToken(p); err != nil {
		return nil, err
	}
	return p, nil
}

// ProxyList returns the proxies of a space (newest first).
func (s *Service) ProxyList(ctx context.Context, spaceID identity.ID) ([]proxy.Proxy, error) {
	var out []proxy.Proxy
	if err := s.R.List(ctx, "proxies", database.Filter{
		Equal: map[string]any{"space_id": spaceID.String()}, OrderBy: "created_at", Asc: false,
	}, &out); err != nil {
		return nil, err
	}
	for i := range out {
		if err := s.openProxyToken(&out[i]); err != nil {
			return nil, err
		}
	}
	return out, nil
}

// ProxyDelete removes a proxy record (the tunnel credential is simply dropped;
// Modal keeps the sandbox and the connect token is no longer used).
func (s *Service) ProxyDelete(ctx context.Context, id identity.ID) error {
	return s.R.Delete(ctx, "proxies", id)
}

// proxyCreateTool implements the proxy_create agent tool: expose a sandbox port
// through the gateway and post a chat message with an open button for the room's
// users. It returns the gateway URL the agent can report.
func (s *Service) proxyCreateTool(ctx context.Context, spaceID identity.ID, agentName, argsJSON string) (string, error) {
	var in struct {
		Port         int    `json:"port"`
		Title        string `json:"title"`
		Room         string `json:"room"`
		PreservePath bool   `json:"preserve_path"`
		// Start is the command that starts the service, so the preview can be
		// brought back after the computer has slept.
		Start string `json:"start"`
		// Tool names the tool the page is an interactive frontend of; Path
		// is the page inside the service to show; Show false keeps it off
		// the desk (a backend nobody looks at, say).
		Tool string `json:"tool"`
		Path string `json:"path"`
		Show *bool  `json:"show"`
	}
	if err := json.Unmarshal([]byte(argsJSON), &in); err != nil && argsJSON != "" {
		return "", errs.InvalidArgument("proxy_create args: {\"port\":...,\"title\":\"...\"}")
	}
	var roomID identity.ID
	roomLabel := strings.TrimSpace(in.Room)
	// "home" is the space hall desk, not a room id — bind the proxy record to
	// the execution room (for the chat notice) and open the card on home below.
	switch {
	case roomLabel != "" && roomLabel != "home":
		r, err := identity.Parse(roomLabel)
		if err != nil {
			return "", errs.InvalidArgument("invalid room id")
		}
		roomID = r
	case vmm.RoomFrom(ctx) != "":
		rid, err := identity.Parse(vmm.RoomFrom(ctx))
		if err != nil {
			return "", errs.InvalidArgument("invalid room from context")
		}
		roomID = rid
	}
	if roomLabel != "" && roomLabel != "home" {
		if r := vmm.RoomFrom(ctx); r != "" && r != roomID.String() {
			return "", errs.Permission("proxy room differs from execution room")
		}
	}
	if err := helper.CheckContextAccess(ctx, s.R, spaceID, roomID, true, "proxy_create"); err != nil {
		return "", err
	}
	dec, err := s.AsemanAccount(ctx)
	if err != nil {
		return "", err
	}
	p, err := s.proxyCreate(ctx, spaceID, roomID, dec, in.Port, in.Title, in.PreservePath)
	if err != nil {
		return "", err
	}
	if err := s.setPreviewStart(ctx, p, in.Start); err != nil {
		return "", err
	}
	// With a start command the platform starts the service itself (when
	// nothing answers yet) and waits for it, so the agent does not have to
	// background a process and guess when it is up.
	status := ""
	if start := strings.TrimSpace(in.Start); start != "" {
		switch up, started, log := s.servePreview(ctx, spaceID, in.Port, start, 75*time.Second); {
		case up && started:
			status = fmt.Sprintf("\nStarted the service with the start command; port %d is answering.", in.Port)
		case up:
			status = fmt.Sprintf("\nPort %d is already answering; the start command is saved for when the computer has slept.", in.Port)
		default:
			status = fmt.Sprintf("\nThe start command was saved, but port %d did not answer within 75 seconds of running it. Fix what it reports (build first if the app needs it) and call proxy_create again:\n%s", in.Port, log)
		}
	}
	// Post a chat message with the open button (the gateway path); the client
	// resolves the absolute URL and renders an "Open in webview" button.
	_ = s.PostMessage(ctx, spaceID, roomID, dec, fmt.Sprintf(
		"🔗 **%s** preview gateway created. Readiness must be verified after starting the service.\n\nOpen it: %s", p.Title, p.GatewayPath()))
	// Open as a DeskWeb card on the room's desk (the room of this turn, or an
	// explicit room=). room=home is the space hall ("My trading desk").
	if in.Show == nil || *in.Show {
		show := webPageInput{Page: p.GatewayPath(), Path: in.Path, Tool: in.Tool, Title: in.Title}
		deskRoomID := roomID
		switch {
		case roomLabel == "home" || roomID.IsZero():
			show.Room = "home"
			deskRoomID = identity.ID{}
		default:
			show.Room = roomID.String()
		}
		if d, id, err := s.openWebPage(ctx, spaceID, deskRoomID, agentName, show); err != nil {
			status += "\nThe page could not be opened on the desk: " + err.Error()
		} else if w := windowJSON(d, id); w != nil {
			raw, _ := json.Marshal(w)
			where := "room desk"
			if show.Room == "home" {
				where = "hall desk"
			}
			status += "\nOpened on the " + where + " as a card window: " + string(raw) + ". Arrange it with desk_arrange."
		}
	}
	return p.GatewayPath() + status, nil
}

// proxyManageTool scopes management to the calling workspace and returns only
// the public proxy representation, never tunnel credentials.
func (s *Service) proxyManageTool(ctx context.Context, spaceID identity.ID, name, argsJSON string) (string, error) {
	if name == "proxy_list" {
		records, err := s.ProxyList(ctx, spaceID)
		if err != nil {
			return "", err
		}
		if records == nil {
			records = []proxy.Proxy{}
		}
		data, err := json.Marshal(records)
		return string(data), err
	}
	var in struct {
		ID    string `json:"id"`
		Probe bool   `json:"probe"`
	}
	if err := json.Unmarshal([]byte(argsJSON), &in); err != nil {
		return "", errs.InvalidArgument("proxy tool requires an id")
	}
	id, err := identity.Parse(in.ID)
	if err != nil {
		return "", errs.InvalidArgument("invalid proxy id")
	}
	record, err := s.ProxyGet(ctx, id)
	if err != nil {
		return "", err
	}
	if record.SpaceID != spaceID {
		return "", errs.New(errs.CodePermission, "proxy belongs to another workspace")
	}
	if err := helper.CheckContextAccess(ctx, s.R, record.SpaceID, record.RoomID, name == "proxy_delete", name); err != nil {
		return "", err
	}
	if name == "proxy_get" && in.Probe {
		result, err := probeProxy(ctx, record)
		if err == nil {
			s.holdPreview(spaceID)
		}
		return result, err
	}
	if name == "proxy_delete" {
		if err := s.ProxyDelete(ctx, id); err != nil {
			return "", err
		}
		return "proxy deleted", nil
	}
	data, err := json.Marshal(record)
	return string(data), err
}

// desktopPort is the port the computer's desktop (noVNC) is served on;
// desktopTitle names its proxy.
const (
	desktopPort  = 6080
	desktopTitle = "Desktop"
	toolPrefix   = "Tool · "
)

// proxyKind tells what a proxy fronts: the computer's desktop, an app
// installed on the computer (EnsureToolProxy), or a preview someone
// published, which is the only kind the Previews list shows.
func proxyKind(p *proxy.Proxy) string {
	switch {
	case p.Port == desktopPort && p.Title == desktopTitle:
		return "desktop"
	case strings.HasPrefix(p.Title, toolPrefix):
		return "tool"
	}
	return "preview"
}

// desktopProxy is the one proxy of the project's desktop, pointed at the
// machine awake now. Older nodes made a new one on every start: the extras
// are removed.
func (s *Service) desktopProxy(ctx context.Context, sp, owner identity.ID) (*proxy.Proxy, error) {
	list, err := s.ProxyList(ctx, sp)
	if err != nil {
		return nil, err
	}
	var keep *proxy.Proxy
	for i := range list {
		if proxyKind(&list[i]) != "desktop" {
			continue
		}
		if keep == nil {
			keep = &list[i] // the newest
			continue
		}
		_ = s.ProxyDelete(ctx, list[i].ID)
	}
	if keep == nil {
		return s.ProxyCreate(ctx, sp, identity.ID{}, owner, desktopPort, desktopTitle)
	}
	if err := s.repointProxy(ctx, keep); err != nil {
		return nil, err
	}
	s.holdPreview(sp)
	return keep, nil
}

// repointProxy points a proxy at the project's computer as it is now (a
// machine woken or replaced since answers on a new address).
func (s *Service) repointProxy(ctx context.Context, p *proxy.Proxy) error {
	rec, err := s.SandboxStart(ctx, p.SpaceID)
	if err != nil {
		return err
	}
	tv, ok := s.K.VMMFor(vmm.Type(rec.VMType)).(tunnelVM)
	if !ok {
		return errs.New(errs.CodeUnavailable, "sandbox provider does not support proxying")
	}
	target, token, err := tv.CreateTunnel(ctx, rec.VMID, p.Port)
	if err != nil {
		return err
	}
	p.TargetURL, p.Token, p.UpdatedAt = target, token, time.Now().UTC()
	if p.PreservesPath() {
		p.TargetURL = strings.TrimRight(target, "/") + p.GatewayPath()
	}
	return s.saveProxy(ctx, p, false)
}

func reusablePathProxy(records []proxy.Proxy, room, owner identity.ID, port int) *proxy.Proxy {
	for i := range records {
		p := &records[i]
		if p.RoomID == room && p.OwnerID == owner && p.Port == port && p.PreservesPath() {
			return p
		}
	}
	return nil
}

func (s *Service) CanProxy(ctx context.Context, id, actor identity.ID, write bool) error {
	p, e := s.ProxyGet(ctx, id)
	if e != nil {
		return e
	}
	perm := permission.RoomRead
	if write {
		perm = permission.RoomSend
	}
	return s.Can(ctx, p.SpaceID, p.RoomID, actor, perm)
}
