// Package follow models the explicit follow (subscribe) relationship between
// accounts. Following powers user profiles (followers/following counts and the
// follow/unfollow action) and can drive a following feed.
package follow

import (
	"github.com/aseman/aseman/internal/plugins/entity"
	"github.com/aseman/aseman/internal/plugins/identity"
)

// Follow records that FollowerID follows FolloweeID.
type Follow struct {
	entity.Entity
	FollowerID identity.ID `db:"follower_id" json:"follower_id"`
	FolloweeID identity.ID `db:"followee_id" json:"followee_id"`
}
