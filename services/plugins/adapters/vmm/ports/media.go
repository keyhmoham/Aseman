package vmm

import (
	"context"
	"regexp"
)

var mediaAction = regexp.MustCompile(`(?is)\b(create|generate|make|draw|paint|produce|build|design|render|convert|send|attach|deliver|upload|post|share)\b.{0,120}\b(images?|pictures?|photos?|logos?|icons?|illustrations?|charts?|graphs?|diagrams?|videos?|audio|voice|gifs?|screenshots?|files?|documents?|attachments?|archives?|zip|html|pdf|slides?|posters?|banners?|avatars?|thumbnails?|covers?)\b`)

// MediaRequested is evaluated at the user entry point, never from agent output
// or old history. A host may preserve this grant for the same workflow.
func MediaRequested(request string, attachments []FileAttachment) bool {
	return len(attachments) > 0 || mediaAction.MatchString(request)
}

type mediaIntentCtxKey struct{}

func WithMediaIntent(ctx context.Context, asked bool) context.Context {
	return context.WithValue(ctx, mediaIntentCtxKey{}, asked)
}
func MediaIntent(ctx context.Context) bool {
	value, _ := ctx.Value(mediaIntentCtxKey{}).(bool)
	return value
}

// ArtifactRequested includes software the user asked us to build. Delivering its
// source is part of that request; it does not authorize image generation.
var artifactAction = regexp.MustCompile(`(?is)\b(create|make|build|rebuild|modify|update|extend|expand|upgrade|migrate|refactor|fix|design|implement|develop|deliver|send|attach|share|serve|publish|deploy|host)\b.{0,120}\b(landing[ -]?pages?|web[ -]?sites?|web[ -]?pages?|web[ -]?apps?|apps?|applications?|dashboards?|portfolios?|software|scripts?|code|reports?|presentations?)\b`)

func ArtifactRequested(request string, attachments []FileAttachment) bool {
	return MediaRequested(request, attachments) || artifactAction.MatchString(request)
}

type artifactIntentCtxKey struct{}

func WithArtifactIntent(ctx context.Context, asked bool) context.Context {
	return context.WithValue(ctx, artifactIntentCtxKey{}, asked)
}
func ArtifactIntent(ctx context.Context) bool {
	value, present := ctx.Value(artifactIntentCtxKey{}).(bool)
	if !present {
		return MediaIntent(ctx)
	}
	return value
}
func WithRequestIntent(ctx context.Context, request string, attachments []FileAttachment) context.Context {
	return WithArtifactIntent(WithMediaIntent(ctx, ImageRequested(request, attachments)), ArtifactRequested(request, attachments))
}

// ImageRequested gates raster generation separately from document delivery.
var imageAction = regexp.MustCompile(`(?is)\b(create|generate|make|draw|paint|produce|build|design|render|convert|send|attach|deliver|upload|post|share|edit)\b.{0,120}\b(images?|pictures?|photos?|logos?|icons?|illustrations?|charts?|graphs?|diagrams?|gifs?|screenshots?|posters?|banners?|avatars?|thumbnails?|covers?)\b`)

func ImageRequested(request string, attachments []FileAttachment) bool {
	return len(attachments) > 0 || imageAction.MatchString(request)
}
