// Package post defines the social feed posts published by users. A post may be
// associated with a space/room, carry tags, receive likes and nest comments
// (a comment is a post with a ParentID).
package post

import (
	"time"

	"github.com/aseman/aseman/internal/plugins/entity"
	"github.com/aseman/aseman/internal/plugins/identity"
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
	// Source names where an imported post was first published
	// ("coinmarketcap"); "" for a post made here.
	Source string `db:"source" json:"source,omitempty"`
	// SourceID is the post's id at its source: an import publishes each
	// source post once and never changes it afterwards.
	SourceID string `db:"source_id" json:"source_id,omitempty"`
	// SourceAt is when the post was published at its source.
	SourceAt time.Time `db:"source_at" json:"source_at,omitempty"`
	// Featured (1) puts the post above the others in the global feed: an
	// imported trader's latest posts (see Import).
	Featured int64 `db:"featured" json:"featured,omitempty"`
	// ForwardOf is the post this one shares (the first post of a chain of
	// shares); zero for an original post. A shared post carries a copy of its
	// original's body and media, so it outlives the original.
	ForwardOf identity.ID `db:"forward_of" json:"forward_of,omitempty"`
	// ForwardAuthorID is who wrote the original of a shared post.
	ForwardAuthorID identity.ID `db:"forward_author_id" json:"forward_author_id,omitempty"`
}

// IsForward reports whether the post shares another one.
func (p *Post) IsForward() bool { return !p.ForwardOf.IsZero() }

// Report is a post someone reported to the node's admins.
type Report struct {
	entity.Entity
	ReporterID identity.ID `db:"reporter_id" json:"reporter_id"`
	PostID     identity.ID `db:"post_id" json:"post_id"`
	// AccusedID is who wrote the reported post.
	AccusedID identity.ID `db:"accused_id" json:"accused_id"`
	// Reason is spam, harassment, abuse, scam, inappropriate or other.
	Reason string `db:"reason" json:"reason"`
	Note   string `db:"note" json:"note,omitempty"`
	// Body is the post's text as it was when it was reported.
	Body string `db:"body" json:"body"`
	// Status is open, resolved or dismissed.
	Status     string    `db:"status" json:"status"`
	ResolvedBy string    `db:"resolved_by" json:"resolved_by,omitempty"`
	ResolvedAt time.Time `db:"resolved_at" json:"resolved_at,omitempty"`
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
