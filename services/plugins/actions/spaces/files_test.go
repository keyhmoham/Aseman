package spaces

import (
	"bytes"
	"encoding/json"
	"image"
	"image/color"
	"image/jpeg"
	"image/png"
	"strings"
	"testing"

	"github.com/tradera/tradera/internal/plugins/identity"
	"github.com/tradera/tradera/plugins/actions/message/models/message"
)

func idFromHex(t *testing.T, s string) identity.ID {
	t.Helper()
	id, err := identity.Parse(s)
	if err != nil {
		t.Fatalf("identity.Parse(%q): %v", s, err)
	}
	return id
}

func TestImageDataForContentDownscales(t *testing.T) {
	// A large 4096x4096 PNG must come back as a bounded JPEG with pixels.
	big := image.NewRGBA(image.Rect(0, 0, 4096, 4096))
	for y := 0; y < 4096; y++ {
		for x := 0; x < 4096; x++ {
			big.Set(x, y, color.RGBA{R: uint8(x % 256), G: uint8(y % 256), B: 120, A: 255})
		}
	}
	var buf bytes.Buffer
	if err := png.Encode(&buf, big); err != nil {
		t.Fatal(err)
	}

	data, mime := imageDataForContent("image/png", buf.Bytes())
	if mime != "image/jpeg" {
		t.Fatalf("mime = %q, want image/jpeg", mime)
	}
	img, err := jpeg.Decode(bytes.NewReader(data))
	if err != nil {
		t.Fatalf("decoded output is not a valid jpeg: %v", err)
	}
	b := img.Bounds()
	if b.Dx() > maxImageDim || b.Dy() > maxImageDim {
		t.Fatalf("downscaled image too large: %dx%d", b.Dx(), b.Dy())
	}
	if b.Dx() < 256 || b.Dy() < 256 {
		t.Fatalf("downscaled image suspiciously small: %dx%d", b.Dx(), b.Dy())
	}
}

func TestImageDataForContentUnsupportedFormat(t *testing.T) {
	// Unknown bytes (e.g. webp) fall back to raw data when small.
	data, mime := imageDataForContent("image/webp", []byte{0x52, 0x49, 0x46, 0x46, 1, 2, 3})
	if string(data) != string([]byte{0x52, 0x49, 0x46, 0x46, 1, 2, 3}) {
		t.Fatalf("raw fallback mismatch: %v", data)
	}
	if mime != "image/webp" {
		t.Fatalf("raw fallback mime = %q", mime)
	}
}

func TestSanitizeName(t *testing.T) {
	cases := map[string]string{
		"report.pdf":         "report.pdf",
		"../../etc/passwd":   ".._.._etc_passwd",
		"a\\b.txt":           "a_b.txt",
		"  spaced name.gif ": "spaced name.gif",
		"":                   "",
		"na\x00me":           "name",
	}
	for in, want := range cases {
		if got := sanitizeName(in); got != want {
			t.Errorf("sanitizeName(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestSniffMime(t *testing.T) {
	cases := []struct {
		name string
		data []byte
		want string
	}{
		{name: "pic.jpg", data: []byte{0xFF, 0xD8, 0xFF, 0xE0, 0x00}, want: "image/jpeg"},
		{name: "anim.gif", data: []byte("GIF89a..."), want: "image/gif"},
		{name: "photo.png", data: []byte{0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n'}, want: "image/png"},
		{name: "pic.webp", data: []byte("RIFF\x00\x00\x00\x00WEBPVP8 "), want: "image/webp"},
		{name: "doc.txt", data: []byte("hello"), want: "text/plain; charset=utf-8"},
		{name: "audio.mp3", data: []byte("ID3\x04\x00\x00\x00"), want: "audio/mpeg"},
		{name: "video.mp4", data: []byte("\x00\x00\x00\x18ftypmp42"), want: "video/mp4"},
	}
	for _, c := range cases {
		if got := sniffMime(c.name, c.data); got != c.want {
			t.Errorf("sniffMime(%q) = %q, want %q", c.name, got, c.want)
		}
	}
}

func TestContentPath(t *testing.T) {
	if got := contentPath(idFromHex(t, "00000000000000010000000000000001")); got != "/v1/files/00000000000000010000000000000001/content" {
		t.Fatalf("contentPath = %q", got)
	}
}

func TestMessageAttachmentsRoundTrip(t *testing.T) {
	m := &message.Message{}
	if got := m.ParseAttachments(); got != nil {
		t.Fatalf("empty attachments = %v, want nil", got)
	}
	m.SetAttachments(nil)
	if got := m.ParseAttachments(); len(got) != 0 {
		t.Fatalf("empty attachments after Set(nil) = %v, want empty", got)
	}
	m.SetAttachments([]string{"00000000000000010000000000000001", "00000000000000010000000000000002"})
	got := m.ParseAttachments()
	if len(got) != 2 || got[0] != "00000000000000010000000000000001" {
		t.Fatalf("round trip failed: %v", got)
	}
}
func TestResolveAttachmentsAreTagOnly(t *testing.T) {
	s, ctx := fileToolHarness(t)
	owner := idFromHex(t, "00000000000000010000000000000001")
	sp, err := s.CreateSpace(ctx, owner, "test space", "")
	if err != nil {
		t.Fatal(err)
	}
	// Upload a text document and an image file into the space.
	txt, err := s.UploadFile(ctx, owner, sp.ID, identity.ID{}, "notes.txt", "text/plain", []byte("buy the dip"))
	if err != nil {
		t.Fatal(err)
	}
	img, err := s.UploadFile(ctx, owner, sp.ID, identity.ID{}, "chart.png", "image/png", []byte{0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a, 1, 2, 3})
	if err != nil {
		t.Fatal(err)
	}
	atts, err := s.ResolveAttachments(ctx, owner, []string{txt.ID.String(), img.ID.String()})
	if err != nil {
		t.Fatal(err)
	}
	if len(atts) != 2 {
		t.Fatalf("expected 2 attachments, got %d", len(atts))
	}
	// Tag-only: metadata present, but no extracted content and no image pixels.
	for _, a := range atts {
		if a.Content != "" || len(a.ImageData) != 0 {
			t.Fatalf("attachment must be tag-only, got %+v", a)
		}
		if a.Name == "" || a.Mime == "" || a.URL == "" {
			t.Fatalf("attachment tag missing metadata: %+v", a)
		}
	}
}

func TestReadFileForAgentReturnsImageMultimodal(t *testing.T) {
	s, ctx := fileToolHarness(t)
	owner := idFromHex(t, "00000000000000010000000000000001")
	sp, err := s.CreateSpace(ctx, owner, "test space", "")
	if err != nil {
		t.Fatal(err)
	}
	// A real, decodable PNG so imageDataForContent can downscale it.
	img := image.NewRGBA(image.Rect(0, 0, 64, 64))
	for y := 0; y < 64; y++ {
		for x := 0; x < 64; x++ {
			img.Set(x, y, color.RGBA{R: uint8(x * 4), G: uint8(y * 4), B: 120, A: 255})
		}
	}
	var buf bytes.Buffer
	if err := png.Encode(&buf, img); err != nil {
		t.Fatal(err)
	}
	f, err := s.UploadFile(ctx, owner, sp.ID, identity.ID{}, "chart.png", "image/png", buf.Bytes())
	if err != nil {
		t.Fatal(err)
	}
	// The agent's file_read on an image returns the multimodal marker.
	out, err := s.readFileForAgent(ctx, sp.ID, `{"file_id":"`+f.ID.String()+`"}`)
	if err != nil {
		t.Fatal(err)
	}
	var m struct {
		Multimodal *struct {
			Text     string `json:"text"`
			ImageURL string `json:"image_url"`
		} `json:"__multimodal"`
	}
	if json.Unmarshal([]byte(out), &m) != nil || m.Multimodal == nil {
		t.Fatalf("expected a multimodal marker, got %q", out)
	}
	if !strings.HasPrefix(m.Multimodal.ImageURL, "data:image/jpeg;base64,") {
		t.Fatalf("image url = %q, want a jpeg data url", m.Multimodal.ImageURL)
	}
	// Text files still return their full content.
	note, err := s.UploadFile(ctx, owner, sp.ID, identity.ID{}, "notes.txt", "text/plain", []byte("buy the dip"))
	if err != nil {
		t.Fatal(err)
	}
	txtOut, err := s.readFileForAgent(ctx, sp.ID, `{"file_id":"`+note.ID.String()+`"}`)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(txtOut, "buy the dip") {
		t.Fatalf("text file content missing from file_read: %q", txtOut)
	}
}
