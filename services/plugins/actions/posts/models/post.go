// Package post defines the social feed posts published by users. A post may be
// associated with a space/room, carry tags, receive likes and nest comments
// (a comment is a post with a ParentID).
package post

import (
	"time"

	"github.com/tradera/tradera/internal/plugins/entity"
	"github.com/tradera/tradera/internal/plugins/identity"
)

// Post is a user-published feed entry.
type Post struct {
	entity.Entity
	// AuthorID is the account that published the post.
	AuthorID identity.ID `db:"author_id" json:"author_id"`
	// SpaceID optionally links the post to a workspace. Zero = global post.
	SpaceID identity.ID `db:"space_id" json:"space_id,omitempty"`
	// ParentID references the post this is a comment on. Zero = top-level post.
	ParentID identity.ID `db:"parent_id" json:"parent_id,omitempty"`
	// Body is the post text (or the comment text when ParentID is set).
	Body string `db:"body" json:"body"`
	// Tags is a JSON-encoded []string of topic tags.
	Tags string `db:"tags" json:"tags,omitempty"`
	// Media is a JSON-encoded []string of file ids attached to the post.
	Media string `db:"media" json:"media,omitempty"`
	// LikedBy is a JSON-encoded []string of account ids that liked the post.
	LikedBy string `db:"liked_by" json:"liked_by,omitempty"`
	// Likes is the cached count of likes (len of LikedBy).
	Likes int64 `db:"likes" json:"likes"`
	// EditedAt is set when the post body changes after publication.
	EditedAt time.Time `db:"edited_at" json:"edited_at,omitempty"`
}

// ParseTags decodes the tags JSON column.
func (p *Post) ParseTags() []string {
	return parseStrings(p.Tags)
}

// ParseMedia decodes the media JSON column.
func (p *Post) ParseMedia() []string {
	return parseStrings(p.Media)
}

// ParseLikedBy decodes the liked-by JSON column.
func (p *Post) ParseLikedBy() []string {
	return parseStrings(p.LikedBy)
}

// HasLiked reports whether account id is in the liked set.
func (p *Post) HasLiked(id identity.ID) bool {
	want := id.String()
	for _, v := range p.ParseLikedBy() {
		if v == want {
			return true
		}
	}
	return false
}

func parseStrings(s string) []string {
	if s == "" {
		return nil
	}
	var out []string
	if err := unmarshalJSON(s, &out); err != nil {
		return nil
	}
	return out
}
