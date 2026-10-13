// Package federation implements the federation namespace: the mesh entry point
// for cross-node requests and the node registry. Any action operating on an
// entity owned by another node is proxied to that node's federation.dispatch.
package federation

import (
	"context"
	"encoding/json"
	"time"

	"github.com/tradera/tradera/internal/plugins/api"
	"github.com/tradera/tradera/internal/plugins/identity"
	"github.com/tradera/tradera/internal/plugins/signing"
	"github.com/tradera/tradera/pkg/errs"
	"github.com/tradera/tradera/pkg/logger"
	fed "github.com/tradera/tradera/plugins/actions/federation/gateway"
	"github.com/tradera/tradera/plugins/actions/federation/models/node"
	"github.com/tradera/tradera/plugins/actions/support/helper"
	"github.com/tradera/tradera/plugins/actions/support/repo"
	"github.com/tradera/tradera/plugins/adapters/database/ports"
	"github.com/tradera/tradera/plugins/adapters/network/ports"
)

// Service implements federation operations.
type Service struct {
	Peer *fed.API
	K    api.Kernel
	R    *repo.Repo
	L    *logger.Logger
}

// Local reports whether a universal id belongs to this node.
func (s *Service) Local(id identity.ID) bool {
	return id.Node == s.K.NodeID()
}

// isCentral reports whether this node is the platform central node.
func (s *Service) isCentral() bool { return s.K.Env()["central"] == "true" }

// centralInfo returns this node's registry info (used by the allocator).
func (s *Service) centralInfo() map[string]any {
	return map[string]any{
		"node_id":    s.K.NodeID().String(),
		"url":        s.K.Env()["node_url"],
		"public_key": s.K.Env()["node_public_key"],
	}
}

// AllocateNodeID allocates a fresh timestamp-derived node id for a bootstrap
// node and registers it in this (central) node's registry. Returns the new id
// and this central node's own info so the peer can register back.
func (s *Service) AllocateNodeID(ctx context.Context, pubKey, url, name string) (identity.NodeID, map[string]any, error) {
	if !s.isCentral() {
		return 0, nil, errs.Permission("only the central node allocates node ids")
	}
	if pubKey == "" || url == "" {
		return 0, nil, errs.InvalidArgument("public_key and url required")
	}
	// If this node already registered, return its id.
	var existing []node.Node
	if err := s.R.List(ctx, "nodes", database.Filter{Equal: map[string]any{"public_key": pubKey}}, &existing); err == nil && len(existing) > 0 {
		return existing[0].ID, s.centralInfo(), nil
	}
	// Allocate from the current timestamp (never a counter).
	for {
		nid, err := identity.GenerateNodeID(time.Now())
		if err != nil {
			return 0, nil, err
		}
		rec := &node.Node{
			ID: nid, URL: url, PublicKey: pubKey,
			Status: node.StatusOnline, LastSeen: time.Now().UTC(),
		}
		if err := s.R.CreateID(ctx, "nodes", identity.ID{Node: nid}, rec); err != nil {
			if errs.CodeOf(err) == errs.CodeAlreadyExists {
				continue // collision; retry with a fresh timestamp
			}
			return 0, nil, err
		}
		s.L.Info("allocated node id", "node_id", nid.String(), "name", name, "url", url)
		return nid, s.centralInfo(), nil
	}
}

// NodeURL resolves the API URL of a peer node.
func (s *Service) NodeURL(ctx context.Context, nodeID identity.NodeID) (string, error) {
	var list []node.Node
	if err := s.R.List(ctx, "nodes", database.Filter{Equal: map[string]any{"id": identity.ID{Node: nodeID}.String()}}, &list); err != nil {
		return "", err
	}
	if len(list) == 0 {
		return "", errs.NotFound("node " + nodeID.String())
	}
	return list[0].URL, nil
}

// Proxy forwards an action to the node that owns the entity referenced by id.
// If the entity is local it dispatches directly. Cross-node requests are signed
// with the node keypair and sent to the peer's /fed/dispatch route.
func (s *Service) Proxy(ctx context.Context, entityRef string, namespace, name string, caller api.Caller, body []byte) (*api.ActionResponse, error) {
	id, err := identity.Parse(entityRef)
	if err != nil {
		return nil, err
	}
	if s.Local(id) {
		return s.K.Actions().Dispatch(ctx, namespace, name, &api.ActionRequest{
			Caller: caller, Origin: s.K.NodeID(), Body: body,
		})
	}
	url, err := s.NodeURL(ctx, id.Node)
	if err != nil {
		return nil, errs.Wrap(errs.CodeFederation, err, "resolve owning node")
	}
	wrapped, _ := json.Marshal(map[string]any{
		"action": namespace + "/" + name,
		"caller": caller,
		"body":   body,
	})
	priv := s.K.Env()["node_private_key"]
	if priv == "" {
		return nil, errs.New(errs.CodeUnavailable, "node private key not configured")
	}
	headers, err := signing.SignRequest(priv, "POST", "/fed/dispatch", wrapped)
	if err != nil {
		return nil, errs.Wrap(errs.CodeInternal, err, "sign proxy request")
	}
	headers[signing.HdrNode] = s.K.NodeID().String()
	net := s.K.Network()
	if net == nil {
		return nil, errs.New(errs.CodeUnavailable, "no network adapter for federation")
	}
	resp, err := net.Call(ctx, url, &network.Request{
		Method: network.MethodPost, Path: "/fed/dispatch", Header: headers, Body: wrapped,
	})
	if err != nil {
		return nil, errs.Wrap(errs.CodeFederation, err, "proxy to node "+id.NodeString())
	}
	return &api.ActionResponse{Status: resp.Status, Body: resp.Body}, nil
}

// BuildActions assembles the federation namespace actions.
func BuildActions(s *Service) []api.Action {
	return []api.Action{
		&dispatchAction{s: s},
		&nodesListAction{s: s},
		&nodeRegisterAction{s: s},
		&nodeUnregisterAction{s: s},
		&nodeAllocateAction{s: s},
		&nodeInfoAction{s: s},
	}
}

// dispatchAction receives proxied requests from other nodes.
type dispatchAction struct{ s *Service }

func (a *dispatchAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "federation", Name: "dispatch", Summary: "Execute a request proxied from another node"}
}
func (a *dispatchAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	var in struct {
		Action string     `json:"action"`
		Caller api.Caller `json:"caller"`
		Body   []byte     `json:"body"`
	}
	if err := json.Unmarshal(req.Body, &in); err != nil {
		return nil, errs.Wrap(errs.CodeFederation, err, "decode proxied request")
	}
	ns, name, ok := splitAction(in.Action)
	if !ok {
		return nil, errs.InvalidArgument("malformed action reference " + in.Action)
	}
	if ns == "federation" {
		return nil, errs.Permission("cannot proxy federation actions")
	}
	return a.s.K.Actions().Dispatch(ctx, ns, name, &api.ActionRequest{
		Caller: in.Caller, Origin: req.Origin, Body: in.Body,
	})
}

type nodesListAction struct{ s *Service }

func (a *nodesListAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "federation", Name: "nodes_list", Summary: "List federation peer nodes"}
}
func (a *nodesListAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireAuthenticated(req); err != nil {
		return nil, err
	}
	var nodes []node.Node
	if err := a.s.R.List(ctx, "nodes", database.Filter{}, &nodes); err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"nodes": nodes, "local_node": a.s.K.NodeID().String()})
}

type nodeRegisterAction struct{ s *Service }

func (a *nodeRegisterAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "federation", Name: "node_register", Summary: "Register a federation peer node"}
}
func (a *nodeRegisterAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireUser(req); err != nil {
		return nil, err
	}
	var in struct {
		ID        string `json:"id"`
		URL       string `json:"url"`
		PublicKey string `json:"public_key,omitempty"`
		Central   bool   `json:"central"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	nid, err := identity.NodeOf(in.ID)
	if err != nil {
		return nil, err
	}
	if in.URL == "" {
		return nil, errs.InvalidArgument("url required")
	}
	now := time.Now().UTC()
	rec := &node.Node{
		ID: nid, URL: in.URL, PublicKey: in.PublicKey,
		Status: node.StatusOnline, LastSeen: now, IsCentral: in.Central,
	}
	if err := a.s.R.CreateID(ctx, "nodes", identity.ID{Node: nid}, rec); err != nil {
		if errs.CodeOf(err) == errs.CodeAlreadyExists {
			// update instead
			var list []node.Node
			if err := a.s.R.List(ctx, "nodes", database.Filter{Equal: map[string]any{"id": identity.ID{Node: nid}.String()}}, &list); err == nil && len(list) > 0 {
				existing := list[0]
				existing.URL = in.URL
				existing.PublicKey = in.PublicKey
				existing.IsCentral = in.Central
				existing.LastSeen = now
				if err := a.s.R.UpdateString(ctx, "nodes", identity.ID{Node: nid}.String(), existing); err != nil {
					return nil, err
				}
				return helper.JSON(map[string]any{"node_id": nid.String(), "updated": true})
			}
		}
		return nil, err
	}
	return helper.JSON(map[string]any{"node_id": nid.String()})
}

type nodeUnregisterAction struct{ s *Service }

func (a *nodeUnregisterAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "federation", Name: "node_unregister", Summary: "Remove a federation peer node"}
}
func (a *nodeUnregisterAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireUser(req); err != nil {
		return nil, err
	}
	var in struct {
		ID string `json:"id"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	nid, err := identity.NodeOf(in.ID)
	if err != nil {
		return nil, err
	}
	_ = a.s.R.Delete(ctx, "nodes", identity.ID{Node: nid})
	return helper.JSON(map[string]any{"ok": true})
}

// nodeAllocateAction allocates a timestamp-based node id (central node only).
type nodeAllocateAction struct{ s *Service }

func (a *nodeAllocateAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "federation", Name: "node_allocate",
		Summary: "Allocate a timestamp-derived node id (central node)"}
}
func (a *nodeAllocateAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	var in struct {
		PublicKey string `json:"public_key"`
		URL       string `json:"url"`
		Name      string `json:"name,omitempty"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	nid, central, err := a.s.AllocateNodeID(ctx, in.PublicKey, in.URL, in.Name)
	if err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"node_id": nid.String(), "central": central})
}

type nodeInfoAction struct{ s *Service }

func (a *nodeInfoAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "federation", Name: "node_info", Summary: "Info about this node"}
}
func (a *nodeInfoAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	return helper.JSON(map[string]any{
		"node_id":    a.s.K.NodeID().String(),
		"central":    a.s.K.Env()["central"] == "true",
		"node_url":   a.s.K.Env()["node_url"],
		"public_key": a.s.K.Env()["node_public_key"],
	})
}

func splitAction(ref string) (string, string, bool) {
	for i := 0; i < len(ref); i++ {
		if ref[i] == '/' {
			return ref[:i], ref[i+1:], true
		}
	}
	return "", "", false
}

func (s *Service) DispatchPeer(ctx context.Context, req *network.Request) (*network.Response, error) {
	return s.Peer.Dispatch(ctx, req)
}
func (s *Service) LedgerPeer(ctx context.Context, req *network.Request) (*network.Response, error) {
	return s.Peer.Ledger(ctx, req)
}
