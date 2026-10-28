// Command evals measures the agents' judgement on labelled sets (evals/):
//
//	go run ./cmd/evals triage [-rules-only] [-set ../evals/triage/emails.jsonl] [-out results.md]
//	go run ./cmd/evals reply-chips [-set ../evals/reply-chips/cases.jsonl] [-out results.md]
//
// A model is any OpenAI-compatible endpoint: EVAL_BASE_URL (default
// https://api.openai.com/v1), EVAL_API_KEY and EVAL_MODEL. -rules-only scores
// triage's rules alone and needs no model (CI runs it).
package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/aseman/aseman/plugins/actions/proactive/triage"
)

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: evals triage|reply-chips [flags]")
		os.Exit(2)
	}
	var err error
	switch os.Args[1] {
	case "triage":
		err = runTriage(os.Args[2:])
	case "reply-chips":
		err = runReplyChips(os.Args[2:])
	default:
		err = errors.New("unknown eval " + os.Args[1])
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

// model calls the OpenAI-compatible endpoint named by the environment.
func model() (triage.Model, string, error) {
	key, name := os.Getenv("EVAL_API_KEY"), os.Getenv("EVAL_MODEL")
	if key == "" || name == "" {
		return nil, "", errors.New("set EVAL_API_KEY and EVAL_MODEL (and EVAL_BASE_URL for another provider), or use -rules-only")
	}
	base := strings.TrimRight(os.Getenv("EVAL_BASE_URL"), "/")
	if base == "" {
		base = "https://api.openai.com/v1"
	}
	client := &http.Client{Timeout: 2 * time.Minute}
	call := func(system, user string) (string, string, error) {
		body, _ := json.Marshal(map[string]any{"model": name, "temperature": 0,
			"messages": []map[string]string{{"role": "system", "content": system}, {"role": "user", "content": user}}})
		req, _ := http.NewRequest(http.MethodPost, base+"/chat/completions", bytes.NewReader(body))
		req.Header.Set("Authorization", "Bearer "+key)
		req.Header.Set("Content-Type", "application/json")
		resp, err := client.Do(req)
		if err != nil {
			return "", name, err
		}
		defer resp.Body.Close()
		data, _ := io.ReadAll(resp.Body)
		if resp.StatusCode >= 300 {
			return "", name, fmt.Errorf("%s: %s", resp.Status, data)
		}
		var out struct {
			Choices []struct {
				Message struct {
					Content string `json:"content"`
				} `json:"message"`
			} `json:"choices"`
		}
		if err := json.Unmarshal(data, &out); err != nil || len(out.Choices) == 0 {
			return "", name, errors.New("unreadable answer")
		}
		return out.Choices[0].Message.Content, name, nil
	}
	return call, name, nil
}

func readJSONL[T any](path string) ([]T, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	var out []T
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 1<<20), 1<<20)
	for sc.Scan() {
		if strings.TrimSpace(sc.Text()) == "" {
			continue
		}
		var v T
		if err := json.Unmarshal(sc.Bytes(), &v); err != nil {
			return nil, err
		}
		out = append(out, v)
	}
	return out, sc.Err()
}

func write(out, text string) error {
	if out == "" {
		fmt.Print(text)
		return nil
	}
	return os.WriteFile(out, []byte(text), 0o644)
}

func pct(a, b int) string {
	if b == 0 {
		return "n/a"
	}
	return fmt.Sprintf("%.1f%%", 100*float64(a)/float64(b))
}
