package tools

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"time"

	"github.com/tradera/tradera/pkg/errs"
)

// Compiler is the tool runtime in its compiler role (deploy/tool-runtime,
// `server.mjs --compiler`): it compiles Elpian VM programs (Dart or the JS
// subset) to bytecode, and loads a backend program to report the microtools
// it registers. The node itself links no Elpian code; this is the one place
// it asks for Elpian's front-ends.
type Compiler struct {
	URL  string
	HTTP *http.Client
}

// NewCompiler returns a compiler client, or nil when no compiler is
// configured (programs are then checked when their runtime starts them).
func NewCompiler(url string) *Compiler {
	url = strings.TrimRight(strings.TrimSpace(url), "/")
	if url == "" {
		return nil
	}
	return &Compiler{URL: url, HTTP: &http.Client{Timeout: 60 * time.Second}}
}

func (c *Compiler) post(ctx context.Context, path string, in, out any) error {
	body, _ := json.Marshal(in)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.URL+path, bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	res, err := c.HTTP.Do(req)
	if err != nil {
		return errs.New(errs.CodeUnavailable, "the tool compiler is not reachable: "+err.Error())
	}
	defer res.Body.Close()
	raw, err := io.ReadAll(io.LimitReader(res.Body, 32<<20))
	if err != nil {
		return err
	}
	var failure struct {
		Error string `json:"error"`
	}
	if res.StatusCode >= 300 {
		if json.Unmarshal(raw, &failure) == nil && failure.Error != "" {
			return errs.InvalidArgument(failure.Error)
		}
		return errs.New(errs.CodeUnavailable, "the tool compiler failed: "+res.Status)
	}
	return json.Unmarshal(raw, out)
}

// Compile compiles an Elpian VM program (language dart or js) to bytecode.
func (c *Compiler) Compile(ctx context.Context, language, source string) ([]byte, error) {
	var out struct {
		Bytecode string `json:"bytecode"`
	}
	if err := c.post(ctx, "/compile", map[string]string{"language": language, "source": source}, &out); err != nil {
		return nil, err
	}
	return base64.StdEncoding.DecodeString(out.Bytecode)
}

// Describe loads a backend program in a throwaway runtime and returns the
// microtools it registers, as MCP tools/list reports them.
func (c *Compiler) Describe(ctx context.Context, program *Program) (map[string]any, error) {
	var out map[string]any
	err := c.post(ctx, "/describe", program, &out)
	return out, err
}
