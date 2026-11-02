package main

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/aseman/aseman/pkg/crypto"
)

func main() {
	token := mustRead("/tmp/aseman_token")
	priv := mustRead("/tmp/aseman_priv")
	audio, err := os.ReadFile("/tmp/e2e-voice.wav")
	if err != nil {
		fatal(err)
	}
	bodyMap := map[string]any{
		"audio": base64.StdEncoding.EncodeToString(audio),
		"mime":  "audio/wav",
	}
	body, _ := json.Marshal(bodyMap)
	path := "/v1/users/voice_turn"
	nonce, err := crypto.NewNonce()
	if err != nil {
		fatal(err)
	}
	ts := strconv.FormatInt(time.Now().Unix(), 10)
	payload := crypto.RequestPayload(http.MethodPost, path, nonce, ts, crypto.BodyHash(body))
	sig, err := crypto.SignHex(priv, payload)
	if err != nil {
		fatal(err)
	}
	req, err := http.NewRequest(http.MethodPost, "http://127.0.0.1:8080"+path, bytes.NewReader(body))
	if err != nil {
		fatal(err)
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("X-Aseman-Nonce", nonce)
	req.Header.Set("X-Aseman-Timestamp", ts)
	req.Header.Set("X-Aseman-Signature", sig)
	client := &http.Client{Timeout: 5 * time.Minute}
	resp, err := client.Do(req)
	if err != nil {
		fatal(err)
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(resp.Body)
	fmt.Printf("http=%d bytes=%d\n", resp.StatusCode, len(raw))
	var out map[string]any
	if err := json.Unmarshal(raw, &out); err != nil {
		fmt.Println(string(raw))
		fatal(err)
	}
	if a, ok := out["audio"].(string); ok && len(a) > 80 {
		out["audio"] = fmt.Sprintf("%s...( %d b64 chars)", a[:40], len(a))
	}
	b, _ := json.MarshalIndent(out, "", "  ")
	fmt.Println(string(b))
	reply, _ := out["reply"].(string)
	heard, _ := out["heard"].(string)
	audioB64, _ := out["audio"].(string)
	if resp.StatusCode >= 300 || reply == "" || heard == "" {
		os.Exit(1)
	}
	if strings.Contains(strings.ToLower(reply), "something went wrong") {
		fmt.Fprintln(os.Stderr, "reply looks like an error fallback")
		os.Exit(1)
	}
	if audioB64 == "" {
		fmt.Fprintln(os.Stderr, "missing TTS audio")
		os.Exit(1)
	}
	fmt.Println("E2E_OK")
}

func mustRead(path string) string {
	b, err := os.ReadFile(path)
	if err != nil {
		fatal(err)
	}
	return string(bytes.TrimSpace(b))
}

func fatal(err error) {
	fmt.Fprintln(os.Stderr, err)
	os.Exit(1)
}
