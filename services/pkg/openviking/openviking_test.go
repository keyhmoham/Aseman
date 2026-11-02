package openviking

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

type seen struct {
	method, path string
	header       http.Header
	body         map[string]any
}

func fake(t *testing.T, result any) (*Client, *[]seen) {
	t.Helper()
	var got []seen
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var body map[string]any
		_ = json.NewDecoder(r.Body).Decode(&body)
		got = append(got, seen{r.Method, r.URL.EscapedPath(), r.Header.Clone(), body})
		_ = json.NewEncoder(w).Encode(map[string]any{"status": "ok", "result": result})
	}))
	t.Cleanup(srv.Close)
	return &Client{URL: srv.URL, Key: "root"}, &got
}

func TestPersonIdentifiers(t *testing.T) {
	if got := PersonAccount("abc:1"); got != "person-abc-1" {
		t.Fatalf("PersonAccount = %q", got)
	}
	if got := Peer("abc"); got != "abc" {
		t.Fatalf("Peer = %q", got)
	}
	if SpaceAccount("x") == PersonAccount("x") {
		t.Fatal("a person's account must never be a space's")
	}
}

func TestRecall(t *testing.T) {
	c, got := fake(t, map[string]any{"rendered": "  Ann is vegetarian.  "})
	out, err := c.Recall(context.Background(), "person-ann", BrainUser, "what do I eat?",
		Recall{Session: BrainSession, Peer: "ann", MaxTokens: 1500, Targets: []string{Resources}})
	if err != nil || out != "Ann is vegetarian." {
		t.Fatalf("Recall = %q, %v", out, err)
	}
	r := (*got)[0]
	if r.path != "/api/v1/search/search" || r.body["mode"] != "context" || r.body["session_id"] != BrainSession ||
		r.body["query_expansion"] != "off" || r.body["max_tokens"] != float64(1500) {
		t.Fatalf("request = %+v", r)
	}
	if r.header.Get("X-OpenViking-Account") != "person-ann" || r.header.Get("X-OpenViking-Actor-Peer") != "ann" {
		t.Fatalf("headers = %v", r.header)
	}
	if targets, _ := r.body["target_uri"].([]any); len(targets) != 1 || targets[0] != Resources {
		t.Fatalf("target_uri = %v", r.body["target_uri"])
	}
}

func TestSessionsAndAppend(t *testing.T) {
	c, got := fake(t, map[string]any{})
	ctx := context.Background()
	if err := c.AddMessages(ctx, "person-ann", BrainUser, "saved", []Message{{Role: "user", Content: "hi", PeerID: "ann"}}); err != nil {
		t.Fatal(err)
	}
	if err := c.SetCommitPolicy(ctx, "person-ann", BrainUser, "saved", CommitPolicy{Messages: 20, Tokens: 24000, IdleSeconds: 1800}); err != nil {
		t.Fatal(err)
	}
	if err := c.Append(ctx, "person-ann", BrainUser, BrainNotes, "- likes tea\n"); err != nil {
		t.Fatal(err)
	}
	add, policy, write := (*got)[0], (*got)[1], (*got)[2]
	if add.method != http.MethodPost || add.path != "/api/v1/sessions/saved/messages/batch" {
		t.Fatalf("add = %+v", add)
	}
	if msgs, _ := add.body["messages"].([]any); len(msgs) != 1 || msgs[0].(map[string]any)["peer_id"] != "ann" {
		t.Fatalf("messages = %v", add.body["messages"])
	}
	if policy.method != http.MethodPatch || policy.path != "/api/v1/sessions/saved/config" ||
		policy.body["auto_commit_policy"].(map[string]any)["message_count_threshold"] != float64(20) {
		t.Fatalf("policy = %+v", policy)
	}
	if write.body["mode"] != "append" || write.body["processing_mode"] != "vectors_only" || write.body["uri"] != BrainNotes {
		t.Fatalf("write = %+v", write)
	}
}
