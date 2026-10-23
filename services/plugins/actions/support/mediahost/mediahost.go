// Package mediahost downloads remote image/video/audio URLs into Aseman
// storage and rewrites post/message markup so clients never fetch the
// original link (safety against malicious hosts, and one shared cache).
package mediahost

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"path"
	"regexp"
	"strings"
	"time"

	"github.com/aseman/aseman/pkg/errs"
)

// MaxBytes is how large one hosted medium may be (same bound as post import).
const MaxBytes = 25 << 20

// FetchTimeout bounds how long a remote host may take to answer.
const FetchTimeout = 30 * time.Second

// mediaDirective matches :::image|video|audio <url> on its own line.
var mediaDirective = regexp.MustCompile(`(?m)^(:::(?:image|video|audio)\s+)(\S+)\s*$`)

// aloneMarkdownImage matches a line that is only ![alt](url).
var aloneMarkdownImage = regexp.MustCompile(`(?m)^(!\[[^\]]*\]\()([^)\s]+)((?:\s+"[^"]*")?\))$`)

// Fetcher downloads a URL. Tests inject a fake; production uses [DefaultFetch].
type Fetcher func(ctx context.Context, rawURL string) (name, mime string, data []byte, err error)

// DefaultFetch GETs [rawURL] with SSRF guards, size and MIME limits.
func DefaultFetch(ctx context.Context, rawURL string) (name, mime string, data []byte, err error) {
	return fetch(ctx, &http.Client{
		Timeout: FetchTimeout,
		CheckRedirect: func(req *http.Request, via []*http.Request) error {
			if len(via) >= 5 {
				return fmt.Errorf("too many redirects")
			}
			return guardURL(req.URL)
		},
	}, rawURL)
}

func fetch(ctx context.Context, client *http.Client, rawURL string) (name, mime string, data []byte, err error) {
	u, err := ParsePublicURL(rawURL)
	if err != nil {
		return "", "", nil, err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u.String(), nil)
	if err != nil {
		return "", "", nil, errs.InvalidArgument("invalid media address")
	}
	req.Header.Set("Accept", "image/*,video/*,audio/*,*/*;q=0.8")
	req.Header.Set("User-Agent", "AsemanMediaHost/1.0")
	resp, err := client.Do(req)
	if err != nil {
		return "", "", nil, errs.New(errs.CodeUnavailable, "the media host did not answer")
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return "", "", nil, errs.New(errs.CodeUnavailable, "the media host refused the request")
	}
	mime = strings.ToLower(strings.TrimSpace(strings.Split(resp.Header.Get("Content-Type"), ";")[0]))
	if !AllowedMIME(mime) {
		// Some hosts omit Content-Type; sniff a little from the path.
		if mime == "" || mime == "application/octet-stream" {
			mime = mimeFromName(path.Base(u.Path))
		}
		if !AllowedMIME(mime) {
			return "", "", nil, errs.InvalidArgument("only images, video and audio can be hosted")
		}
	}
	limited := io.LimitReader(resp.Body, MaxBytes+1)
	data, err = io.ReadAll(limited)
	if err != nil {
		return "", "", nil, errs.New(errs.CodeUnavailable, "the media could not be read")
	}
	if len(data) == 0 {
		return "", "", nil, errs.InvalidArgument("the media was empty")
	}
	if len(data) > MaxBytes {
		return "", "", nil, errs.InvalidArgument("a medium may be at most 25 MB")
	}
	name = path.Base(u.Path)
	if name == "" || name == "." || name == "/" {
		name = "media" + extForMIME(mime)
	}
	return name, mime, data, nil
}

// ParsePublicURL normalizes an http(s) URL and rejects private / loopback
// targets (SSRF).
func ParsePublicURL(raw string) (*url.URL, error) {
	raw = strings.TrimSpace(raw)
	u, err := url.Parse(raw)
	if err != nil || u.Host == "" || u.User != nil {
		return nil, errs.InvalidArgument("enter a full http(s) media address")
	}
	scheme := strings.ToLower(u.Scheme)
	if scheme != "http" && scheme != "https" {
		return nil, errs.InvalidArgument("only http(s) media addresses can be hosted")
	}
	u.Fragment = ""
	if err := guardURL(u); err != nil {
		return nil, err
	}
	return u, nil
}

// NormalizeURL is the cache key for a remote medium.
func NormalizeURL(raw string) (string, error) {
	u, err := ParsePublicURL(raw)
	if err != nil {
		return "", err
	}
	u.Scheme = strings.ToLower(u.Scheme)
	u.Host = strings.ToLower(u.Host)
	// Drop default ports so http://x and http://x:80 share a cache entry.
	if (u.Scheme == "http" && strings.HasSuffix(u.Host, ":80")) ||
		(u.Scheme == "https" && strings.HasSuffix(u.Host, ":443")) {
		host, _, _ := net.SplitHostPort(u.Host)
		if host != "" {
			u.Host = host
		}
	}
	return u.String(), nil
}

func guardURL(u *url.URL) error {
	host := u.Hostname()
	if host == "" {
		return errs.InvalidArgument("invalid media host")
	}
	lower := strings.ToLower(host)
	if lower == "localhost" || strings.HasSuffix(lower, ".localhost") ||
		lower == "metadata.google.internal" {
		return errs.InvalidArgument("that media host is not allowed")
	}
	ips, err := net.LookupIP(host)
	if err != nil {
		// Let the HTTP client surface unreachable hosts; still block obvious
		// literal private addresses without DNS.
		if ip := net.ParseIP(host); ip != nil && isPrivateIP(ip) {
			return errs.InvalidArgument("that media host is not allowed")
		}
		return nil
	}
	for _, ip := range ips {
		if isPrivateIP(ip) {
			return errs.InvalidArgument("that media host is not allowed")
		}
	}
	return nil
}

func isPrivateIP(ip net.IP) bool {
	if ip.IsLoopback() || ip.IsLinkLocalUnicast() || ip.IsLinkLocalMulticast() ||
		ip.IsPrivate() || ip.IsUnspecified() || ip.IsMulticast() {
		return true
	}
	// Cloud metadata / CGNAT ranges sometimes used in SSRF.
	if ip4 := ip.To4(); ip4 != nil {
		if ip4[0] == 169 && ip4[1] == 254 {
			return true
		}
	}
	return false
}

// AllowedMIME reports whether [mime] is hostable media.
func AllowedMIME(mime string) bool {
	mime = strings.ToLower(strings.TrimSpace(strings.Split(mime, ";")[0]))
	return strings.HasPrefix(mime, "image/") ||
		strings.HasPrefix(mime, "video/") ||
		strings.HasPrefix(mime, "audio/")
}

func mimeFromName(name string) string {
	switch strings.ToLower(path.Ext(name)) {
	case ".png":
		return "image/png"
	case ".jpg", ".jpeg":
		return "image/jpeg"
	case ".gif":
		return "image/gif"
	case ".webp":
		return "image/webp"
	case ".svg":
		return "image/svg+xml"
	case ".mp4":
		return "video/mp4"
	case ".webm":
		return "video/webm"
	case ".mov":
		return "video/quicktime"
	case ".mp3":
		return "audio/mpeg"
	case ".wav":
		return "audio/wav"
	case ".ogg", ".oga":
		return "audio/ogg"
	case ".m4a":
		return "audio/mp4"
	default:
		return ""
	}
}

func extForMIME(mime string) string {
	switch strings.ToLower(mime) {
	case "image/png":
		return ".png"
	case "image/jpeg":
		return ".jpg"
	case "image/gif":
		return ".gif"
	case "image/webp":
		return ".webp"
	case "video/mp4":
		return ".mp4"
	case "video/webm":
		return ".webm"
	case "audio/mpeg":
		return ".mp3"
	case "audio/wav":
		return ".wav"
	case "audio/ogg":
		return ".ogg"
	default:
		return ".bin"
	}
}

// Hash returns the hex SHA-256 of [data].
func Hash(data []byte) string {
	sum := sha256.Sum256(data)
	return hex.EncodeToString(sum[:])
}

// ContentPath is the gateway path clients load for a stored file.
func ContentPath(fileID string) string {
	return "/v1/files/" + fileID + "/content"
}

// ExternalURLs lists unique remote http(s) media addresses in markup
// (`:::image|video|audio` and lone `![alt](url)` lines).
func ExternalURLs(body string) []string {
	seen := map[string]bool{}
	var out []string
	add := func(raw string) {
		raw = strings.TrimSpace(raw)
		if raw == "" || seen[raw] {
			return
		}
		if !strings.HasPrefix(strings.ToLower(raw), "http://") &&
			!strings.HasPrefix(strings.ToLower(raw), "https://") {
			return
		}
		seen[raw] = true
		out = append(out, raw)
	}
	for _, m := range mediaDirective.FindAllStringSubmatch(body, -1) {
		add(m[2])
	}
	for _, m := range aloneMarkdownImage.FindAllStringSubmatch(body, -1) {
		add(m[2])
	}
	return out
}

// Rewrite replaces each remote media URL in [body] with [refs][url] (a stored
// file content path). URLs not in [refs] are left unchanged.
func Rewrite(body string, refs map[string]string) string {
	if len(refs) == 0 {
		return body
	}
	body = mediaDirective.ReplaceAllStringFunc(body, func(line string) string {
		m := mediaDirective.FindStringSubmatch(line)
		if m == nil {
			return line
		}
		if ref, ok := refs[m[2]]; ok && ref != "" {
			return m[1] + ref
		}
		return line
	})
	body = aloneMarkdownImage.ReplaceAllStringFunc(body, func(line string) string {
		m := aloneMarkdownImage.FindStringSubmatch(line)
		if m == nil {
			return line
		}
		if ref, ok := refs[m[2]]; ok && ref != "" {
			return m[1] + ref + m[3]
		}
		return line
	})
	return body
}
