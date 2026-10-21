package federation

import (
	"context"
	"time"

	"github.com/aseman/aseman/internal/plugins/identity"
	nodetypes "github.com/aseman/aseman/plugins/actions/federation/models/node"
)

// Bootstrap registers this node and its discovered central peer.
func (s *Service) Bootstrap(ctx context.Context) error {
	self := &nodetypes.Node{ID: s.K.NodeID(), URL: s.K.Env()["node_url"], PublicKey: s.K.Env()["node_public_key"], Status: nodetypes.StatusOnline, IsCentral: s.K.Env()["central"] == "true", LastSeen: time.Now().UTC()}
	if err := s.R.EnsureCreated(ctx, "nodes", identity.ID{Node: s.K.NodeID()}, self); err != nil {
		return err
	}
	if cid := s.K.Env()["central_node_id"]; cid != "" {
		nid, err := identity.NodeOf(cid)
		if err != nil {
			return err
		}
		peer := &nodetypes.Node{ID: nid, URL: s.K.Env()["central_node_url"], PublicKey: s.K.Env()["central_node_pub"], Status: nodetypes.StatusOnline, LastSeen: time.Now().UTC(), IsCentral: true}
		return s.R.EnsureCreated(ctx, "nodes", identity.ID{Node: nid}, peer)
	}
	return nil
}
