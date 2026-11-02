package users

import (
	"context"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"regexp"
	"strings"
	"syscall"
	"time"

	"golang.org/x/net/html"
)

// Reading a web page for your Aseman (the read_webpage tool). The node fetches it, not the person's device,
// so it is held to what a server must be before it fetches anything for anyone: public addresses only (the
// check is made on the address actually dialled, after DNS and at every redirect), http and https on their own
// ports, a short deadline and a small body. What comes back is the page's text and its links, nothing run.

const (
	webTimeout   = 10 * time.Second
	webMaxBody   = 1 << 20
	webTextChars = 12000
	webMaxLinks  = 30
)

// blockedIP is an address a fetch for someone else must never reach: this machine, the private network, link-local
// (cloud metadata lives there), and anything that is not an ordinary public address.
func blockedIP(ip net.IP) bool {
	if ip == nil {
		return true
	}
	if v4 := ip.To4(); v4 != nil && v4[0] == 100 && v4[1]&0xC0 == 64 { // 100.64.0.0/10, carrier-grade NAT
		return true
	}
	return ip.IsLoopback() || ip.IsPrivate() || ip.IsLinkLocalUnicast() || ip.IsLinkLocalMulticast() || ip.IsMulticast() || ip.IsUnspecified() || ip.IsInterfaceLocalMulticast()
}

// webClient dials only public addresses: the address is checked where the connection is made, so a name that
// resolves to a private address (or changes its answer) cannot get past a check made earlier.
func webClient() *http.Client {
	dialer := &net.Dialer{
		Timeout: 5 * time.Second,
		Control: func(network, address string, _ syscall.RawConn) error {
			host, _, err := net.SplitHostPort(address)
			if err != nil || blockedIP(net.ParseIP(host)) {
				return fmt.Errorf("that address is not a public web server")
			}
			return nil
		},
	}
	return &http.Client{
		Timeout:   webTimeout,
		Transport: &http.Transport{DialContext: dialer.DialContext, Proxy: nil, DisableKeepAlives: true, ResponseHeaderTimeout: 8 * time.Second},
		CheckRedirect: func(req *http.Request, via []*http.Request) error {
			if len(via) >= 5 {
				return fmt.Errorf("too many redirects")
			}
			return checkWebURL(req.URL)
		},
	}
}

func checkWebURL(u *url.URL) error {
	if u.Scheme != "http" && u.Scheme != "https" {
		return fmt.Errorf("only http and https pages can be read")
	}
	if u.Hostname() == "" {
		return fmt.Errorf("that is not a web address")
	}
	if p := u.Port(); p != "" && p != "80" && p != "443" {
		return fmt.Errorf("only ordinary web ports can be read")
	}
	return nil
}

// parseWebURL accepts "example.com/about" as well as a full address.
func parseWebURL(raw string) (*url.URL, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return nil, fmt.Errorf("a web address is needed")
	}
	if !strings.Contains(raw, "://") {
		raw = "https://" + raw
	}
	u, err := url.Parse(raw)
	if err != nil {
		return nil, fmt.Errorf("that is not a web address")
	}
	return u, checkWebURL(u)
}

// readWebpage fetches a page and returns its text (and where it links to).
func readWebpage(ctx context.Context, raw string) (string, error) {
	u, err := parseWebURL(raw)
	if err != nil {
		return "", err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u.String(), nil)
	if err != nil {
		return "", err
	}
	req.Header.Set("User-Agent", "Mozilla/5.0 (compatible; AsemanBot/1.0)")
	req.Header.Set("Accept", "text/html,text/plain,application/json;q=0.9,*/*;q=0.1")
	resp, err := webClient().Do(req)
	if err != nil {
		return "", fmt.Errorf("couldn't reach %s: %s", u.Host, shortNetError(err))
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 400 {
		return "", fmt.Errorf("%s answered %d", u.Host, resp.StatusCode)
	}
	kind := strings.ToLower(resp.Header.Get("Content-Type"))
	body, err := io.ReadAll(io.LimitReader(resp.Body, webMaxBody))
	if err != nil {
		return "", fmt.Errorf("the page was cut short")
	}
	switch {
	case strings.Contains(kind, "text/html"), kind == "":
		return pageText(resp.Request.URL, body), nil
	case strings.HasPrefix(kind, "text/"), strings.Contains(kind, "json"):
		return clip(string(body), webTextChars), nil
	}
	return "", fmt.Errorf("that is not a page of text (%s)", kind)
}

func shortNetError(err error) string {
	msg := err.Error()
	if i := strings.LastIndex(msg, ": "); i >= 0 {
		msg = msg[i+2:]
	}
	return clip(msg, 120)
}

var spaces = regexp.MustCompile(`\s+`)

// pageText is a page's title, description, readable text and its links on the same site.
func pageText(base *url.URL, body []byte) string {
	doc, err := html.Parse(strings.NewReader(string(body)))
	if err != nil {
		return clip(spaces.ReplaceAllString(string(body), " "), webTextChars)
	}
	var title, desc string
	var text strings.Builder
	type link struct{ label, href string }
	var links []link
	seen := map[string]bool{}
	var walk func(n *html.Node)
	walk = func(n *html.Node) {
		if n.Type == html.ElementNode {
			switch n.Data {
			case "script", "style", "noscript", "svg", "template", "iframe":
				return
			case "title":
				if title == "" && n.FirstChild != nil {
					title = strings.TrimSpace(n.FirstChild.Data)
				}
				return
			case "meta":
				var name, content string
				for _, a := range n.Attr {
					switch strings.ToLower(a.Key) {
					case "name", "property":
						name = strings.ToLower(a.Val)
					case "content":
						content = a.Val
					}
				}
				if desc == "" && (name == "description" || name == "og:description") {
					desc = strings.TrimSpace(content)
				}
			case "a":
				var href string
				for _, a := range n.Attr {
					if a.Key == "href" {
						href = a.Val
					}
				}
				if ref, err := base.Parse(href); err == nil && ref.Host == base.Host && ref.Scheme != "" && !seen[ref.Path] && len(links) < webMaxLinks && ref.Path != "" && ref.Path != "/" {
					if label := strings.TrimSpace(spaces.ReplaceAllString(nodeText(n), " ")); label != "" {
						seen[ref.Path] = true
						links = append(links, link{clip(label, 60), ref.Path})
					}
				}
			case "p", "div", "li", "br", "h1", "h2", "h3", "h4", "h5", "h6", "tr", "section", "article":
				text.WriteString("\n")
			}
		}
		if n.Type == html.TextNode {
			text.WriteString(n.Data)
			text.WriteString(" ")
		}
		for c := n.FirstChild; c != nil; c = c.NextSibling {
			walk(c)
		}
	}
	walk(doc)
	lines := strings.Split(text.String(), "\n")
	var out strings.Builder
	if title != "" {
		out.WriteString("Title: " + clip(title, 200) + "\n")
	}
	if desc != "" {
		out.WriteString("Description: " + clip(desc, 400) + "\n")
	}
	out.WriteString("\n")
	for _, l := range lines {
		if l = strings.TrimSpace(spaces.ReplaceAllString(l, " ")); l != "" {
			out.WriteString(l + "\n")
		}
	}
	page := clip(out.String(), webTextChars)
	if len(links) > 0 {
		page += "\n\nLinks on this site:\n"
		for _, l := range links {
			page += "- " + l.label + " → " + l.href + "\n"
		}
	}
	if strings.TrimSpace(page) == "" {
		return "(the page has no text a server can read: it may be drawn by scripts)"
	}
	return page
}

func nodeText(n *html.Node) string {
	if n.Type == html.TextNode {
		return n.Data
	}
	var b strings.Builder
	for c := n.FirstChild; c != nil; c = c.NextSibling {
		b.WriteString(nodeText(c))
	}
	return b.String()
}

// A site or address in a note: something to look at on the web.
var siteMention = regexp.MustCompile(`(?i)https?://\S+|\b[a-z0-9][a-z0-9-]*\.(com|org|net|io|ai|co|dev|app|xyz|me|info|uk|de|fr|ir)\b`)

func mentionsSite(body string) bool { return siteMention.MatchString(body) }
