// Package fed implements the node-authenticated inter-node surface. Peers call
// these routes (instead of the user-facing /v1 gateway) and authenticate with
// their node keypair: the receiving node verifies the Ed25519 signature against
// the sender's public key from its node registry.
package fed

import (
	"context"
	"encoding/json"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/bridge"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/internal/plugins/signing"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/pkg/logger"
	"github.com/aseman/aseman/plugins/actions/federation/models/node"
	"github.com/aseman/aseman/plugins/actions/finance/models/wallet"
	"github.com/aseman/aseman/plugins/actions/support/repo"
	"github.com/aseman/aseman/plugins/adapters/database/ports"
	"github.com/aseman/aseman/plugins/adapters/network/ports"
)

type LedgerReplica interface {
	AppendReplica(context.Context, *wallet.LedgerEntry) error
}

// API is the inter-node surface.
type API struct {
	K      api.Kernel
	R      *repo.Repo
	Fin    LedgerReplica
	Log    *logger.Logger
	replay *signing.ReplayGuard
}

// New builds the inter-node API.
func New(k api.Kernel, fin LedgerReplica, log *logger.Logger) *API {
	return &API{
		K: k, R: repo.New(k), Fin: fin,
		Log: log.Named("fed"), replay: signing.NewReplayGuard(),
	}
}

// Register binds the inter-node routes to a network adapter.
func (a *API) Register(net network.Network) error {
	if err := net.Handle(network.MethodCall, "/fed/dispatch", a.routed("DispatchPeer")); err != nil {
		return err
	}
	if err := net.Handle(network.MethodCall, "/fed/ledger", a.routed("LedgerPeer")); err != nil {
		return err
	}
	return nil
}

// verifyNode authenticates a signed inter-node request and returns the sender
// node id.
func (a *API) verifyNode(ctx context.Context, req *network.Request) (identity.NodeID, error) {
	nodeRef := signing.Header(req.Header, signing.HdrNode)
	if nodeRef == "" {
		return 0, errs.Unauthenticated("missing node header")
	}
	nid, err := identity.NodeOf(nodeRef)
	if err != nil {
		return 0, errs.Unauthenticated("invalid node id")
	}
	pub, err := a.nodePublicKey(ctx, nid)
	if err != nil {
		return 0, errs.Unauthenticated("sender node is not registered")
	}
	key := "node:" + nid.String()
	if err := a.replay.VerifyRequest(pub, key, string(req.Method), req.Path, req.Header, req.Body); err != nil {
		return 0, err
	}
	return nid, nil
}

func (a *API) nodePublicKey(ctx context.Context, nid identity.NodeID) (string, error) {
	var list []node.Node
	if err := a.R.List(ctx, "nodes", database.Filter{Equal: map[string]any{"id": identity.ID{Node: nid}.String()}}, &list); err != nil {
		return "", err
	}
	if len(list) == 0 || list[0].PublicKey == "" {
		return "", errs.NotFound("node " + nid.String())
	}
	return list[0].PublicKey, nil
}

// dispatch handles a proxied action call from a peer node.
func (a *API) Dispatch(ctx context.Context, req *network.Request) (*network.Response, error) {
	origin, err := a.verifyNode(ctx, req)
	if err != nil {
		return a.err(err), nil
	}
	var in struct {
		Action string     `json:"action"`
		Caller api.Caller `json:"caller"`
		Body   []byte     `json:"body"`
	}
	if err := json.Unmarshal(req.Body, &in); err != nil {
		return a.err(errs.Wrap(errs.CodeFederation, err, "decode proxied request")), nil
	}
	ns, name, ok := splitAction(in.Action)
	if !ok {
		return a.err(errs.InvalidArgument("malformed action reference")), nil
	}
	if ns == "federation" || ns == "admin" {
		return a.err(errs.Permission("cannot proxy " + ns + " actions")), nil
	}
	resp, err := a.K.Actions().Dispatch(ctx, ns, name, &api.ActionRequest{
		Caller: in.Caller, Origin: origin, Body: in.Body,
	})
	if err != nil {
		return a.err(err), nil
	}
	return &network.Response{Status: resp.Status, Body: resp.Body}, nil
}

// ledger appends a replicated ledger entry from a peer (monotonic seq).
func (a *API) Ledger(ctx context.Context, req *network.Request) (*network.Response, error) {
	origin, err := a.verifyNode(ctx, req)
	if err != nil {
		return a.err(err), nil
	}
	entry := &wallet.LedgerEntry{}
	if err := json.Unmarshal(req.Body, entry); err != nil {
		return a.err(errs.Wrap(errs.CodeFinance, err, "decode ledger entry")), nil
	}
	if entry.NodeID != origin {
		return a.err(errs.Permission("entry node does not match sender")), nil
	}
	if err := a.Fin.AppendReplica(ctx, entry); err != nil {
		return a.err(err), nil
	}
	return &network.Response{Status: 200, Body: []byte(`{"ok":true}`)}, nil
}

func (a *API) err(err error) *network.Response {
	b, _ := json.Marshal(map[string]any{"error": err.Error(), "code": errs.CodeOf(err)})
	return &network.Response{Status: 401, Body: b}
}

func splitAction(ref string) (string, string, bool) {
	for i := 0; i < len(ref); i++ {
		if ref[i] == '/' {
			return ref[:i], ref[i+1:], true
		}
	}
	return "", "", false
}

func (a *API) routed(method string) network.Handler {
	return func(ctx context.Context, req *network.Request) (*network.Response, error) {
		var out *network.Response
		err := bridge.Invoke(ctx, a.K, "federation", method, []any{ctx, req}, &out)
		return out, err
	}
}
func (a *API) Unregister(net network.Network) error {
	_ = net.Unhandle(network.MethodCall, "/fed/dispatch")
	_ = net.Unhandle(network.MethodCall, "/fed/ledger")
	return nil
}
