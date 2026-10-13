package modal

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"regexp"
	"strings"
	"sync"
	"time"
)

// Modal builds a registry image once per reference and reuses that build: a
// mutable tag such as :latest is never pulled again, so sandboxes kept running
// the image from the day the tag was first seen. Resolving the tag to its
// current digest makes a pushed image the one new sandboxes start from.

const imagePinTTL = 5 * time.Minute

type pinnedImage struct {
	ref string
	at  time.Time
}

var (
	imagePinMu sync.Mutex
	imagePins  = map[string]pinnedImage{}
	bearerPart = regexp.MustCompile(`(\w+)="([^"]*)"`)
)

// splitImageRef splits "host/repo:tag" into its registry API host, repository
// and tag. Docker Hub names ("node:22", "user/app") get their defaults.
func splitImageRef(ref string) (host, repo, tag string) {
	tag = "latest"
	name := ref
	if i := strings.LastIndex(ref, ":"); i > strings.LastIndex(ref, "/") {
		name, tag = ref[:i], ref[i+1:]
	}
	first, rest, found := strings.Cut(name, "/")
	if !found || !(strings.ContainsAny(first, ".:") || first == "localhost") {
		if !found {
			name = "library/" + name
		}
		return "registry-1.docker.io", name, tag
	}
	return first, rest, tag
}

// pinImage returns ref with its tag replaced by the digest the registry serves
// for it now. Anything that cannot be resolved (a private image, a registry
// that is down) is returned as given, so sandboxes still start.
func pinImage(ctx context.Context, ref string) string {
	if ref == "" || strings.Contains(ref, "@") {
		return ref
	}
	imagePinMu.Lock()
	hit, ok := imagePins[ref]
	imagePinMu.Unlock()
	if ok && time.Since(hit.at) < imagePinTTL {
		return hit.ref
	}
	pinned := ref
	if digest, err := imageDigest(ctx, ref); err == nil && digest != "" {
		name := ref
		if i := strings.LastIndex(ref, ":"); i > strings.LastIndex(ref, "/") {
			name = ref[:i]
		}
		pinned = name + "@" + digest
	} else if ok {
		pinned = hit.ref // keep the last digest that worked
	}
	imagePinMu.Lock()
	imagePins[ref] = pinnedImage{ref: pinned, at: time.Now()}
	imagePinMu.Unlock()
	return pinned
}

// imageDigest asks the registry for the digest of a tag (anonymous pull scope).
func imageDigest(ctx context.Context, ref string) (string, error) {
	ctx, cancel := context.WithTimeout(ctx, 8*time.Second)
	defer cancel()
	host, repo, tag := splitImageRef(ref)
	manifest := "https://" + host + "/v2/" + repo + "/manifests/" + tag
	head := func(token string) (*http.Response, error) {
		req, err := http.NewRequestWithContext(ctx, http.MethodHead, manifest, nil)
		if err != nil {
			return nil, err
		}
		req.Header.Set("Accept", "application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json")
		if token != "" {
			req.Header.Set("Authorization", "Bearer "+token)
		}
		return http.DefaultClient.Do(req)
	}
	res, err := head("")
	if err != nil {
		return "", err
	}
	res.Body.Close()
	if res.StatusCode == http.StatusUnauthorized {
		token, terr := registryToken(ctx, res.Header.Get("WWW-Authenticate"))
		if terr != nil {
			return "", terr
		}
		if res, err = head(token); err != nil {
			return "", err
		}
		res.Body.Close()
	}
	if res.StatusCode != http.StatusOK {
		return "", fmt.Errorf("registry answered %d for %s", res.StatusCode, ref)
	}
	digest := res.Header.Get("Docker-Content-Digest")
	if !strings.HasPrefix(digest, "sha256:") {
		return "", fmt.Errorf("registry sent no digest for %s", ref)
	}
	return digest, nil
}

// registryToken follows a registry's Bearer challenge for an anonymous token.
func registryToken(ctx context.Context, challenge string) (string, error) {
	if !strings.HasPrefix(strings.ToLower(challenge), "bearer ") {
		return "", fmt.Errorf("unsupported registry auth %q", challenge)
	}
	parts := map[string]string{}
	for _, m := range bearerPart.FindAllStringSubmatch(challenge, -1) {
		parts[m[1]] = m[2]
	}
	if parts["realm"] == "" {
		return "", fmt.Errorf("registry challenge without a realm")
	}
	q := url.Values{}
	for _, k := range []string{"service", "scope"} {
		if parts[k] != "" {
			q.Set(k, parts[k])
		}
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, parts["realm"]+"?"+q.Encode(), nil)
	if err != nil {
		return "", err
	}
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		return "", err
	}
	defer res.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(res.Body, 1<<16))
	if res.StatusCode != http.StatusOK {
		return "", fmt.Errorf("registry token endpoint answered %d", res.StatusCode)
	}
	if m := regexp.MustCompile(`"(?:token|access_token)"\s*:\s*"([^"]+)"`).FindSubmatch(body); m != nil {
		return string(m[1]), nil
	}
	return "", fmt.Errorf("registry token endpoint sent no token")
}
