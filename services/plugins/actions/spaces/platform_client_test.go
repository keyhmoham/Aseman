package spaces

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/plugins/actions/developer/models"
)

// fakeBuilder is a computer running aseman-platform-client.
type fakeBuilder struct {
	mu       sync.Mutex
	commands []string
	status   string // what status.json says
	running  bool
}

func (f *fakeBuilder) exec(_ context.Context, _ identity.ID, command string) (string, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.commands = append(f.commands, command)
	if strings.Contains(command, "nohup") {
		f.running = true
		return "exit=0\nstarted\n", nil
	}
	r := "0"
	if f.running {
		r = "1"
	}
	return "exit=0\nrunning=" + r + "\n" + f.status + "\n", nil
}

func (f *fakeBuilder) set(status string, running bool) {
	f.mu.Lock()
	f.status, f.running = status, running
	f.mu.Unlock()
}

// Publishing an Elpian frontend gives the platform an Android app: it is
// built on the frontend space's computer with the frontend's public address
// in it, stored on the node and recorded on the platform.
func TestAPlatformsAndroidAppIsBuiltStoredAndRecorded(t *testing.T) {
	t.Setenv("ASEMAN_PUBLIC_URL", "https://aseman.example/")
	s, ctx := fileToolHarness(t)
	person := directPerson(t, s, ctx, "00000000000000010000000000000001", "founder")
	sp, err := s.CreateSpace(ctx, person, "studio", "")
	if err != nil {
		t.Fatal(err)
	}
	apk := []byte("PK\x03\x04 an apk")
	sum := sha256.Sum256(apk)
	builder := &fakeBuilder{status: `{"state":"building","step":"downloading Flutter 3.44.0"}`}
	s.clientExecFn = builder.exec
	s.clientPollEvery = 10 * time.Millisecond
	var read string
	reads := 0
	clientReadRetry = time.Millisecond
	s.clientReadFn = func(_ context.Context, _ identity.ID, path string) ([]byte, error) {
		read = path
		// The stored copy lags at first: the app built before.
		if reads++; reads == 1 {
			return []byte("the previous build"), nil
		}
		return apk, nil
	}
	recorded := make(chan models.PlatformClient, 1)
	s.clientRecordFn = func(_ context.Context, platformID string, c models.PlatformClient) error {
		if platformID != "pf1" {
			t.Errorf("recorded on %s", platformID)
		}
		recorded <- c
		return nil
	}
	target := models.PlatformClientTarget{PlatformID: "pf1", Slug: "acme-shop", Name: "Acme Shop", ProxyID: "p1", SpaceID: sp.ID.String(), UI: "elpian",
		Client: &models.PlatformClient{Version: "1.0.4", AppID: "com.acme.shop"}}

	build, err := s.StartPlatformClientBuild(ctx, person, target, models.PlatformClientOptions{Accent: "#4F5BD5"})
	if err != nil || build.State != "building" || build.Version != "1.0.5" {
		t.Fatalf("start: %+v %v", build, err)
	}
	start := builder.commands[0]
	for _, want := range []string{"'--frontend' 'https://aseman.example/v1/platforms/acme-shop/app/'", "'--app-id' 'com.acme.shop'",
		"'--name' 'Acme Shop'", "'--accent' '#4F5BD5'", "'--out' '/workspace/.aseman/platform-clients/acme-shop/acme-shop.apk'", "nohup"} {
		if !strings.Contains(start, want) {
			t.Fatalf("the build command lacks %s: %s", want, start)
		}
	}
	if strings.Contains(start, "--godot") || build.Godot {
		t.Fatalf("Godot is off unless asked for: %s", start)
	}
	// A second ask while it builds joins it.
	if again, _ := s.StartPlatformClientBuild(ctx, person, target, models.PlatformClientOptions{}); again.State != "building" || len(builder.commands) != 1 {
		t.Fatalf("a second build started: %+v", again)
	}
	time.Sleep(40 * time.Millisecond)
	if st, _ := s.PlatformClientBuildStatus(ctx, person, target); st.Step != "downloading Flutter 3.44.0" {
		t.Fatalf("status while building: %+v", st)
	}
	builder.set(`{"state":"done","step":"built","apk":"/workspace/.aseman/platform-clients/acme-shop/acme-shop.apk","size":13,"sha256":"`+hex.EncodeToString(sum[:])+`"}`, false)
	var rec models.PlatformClient
	select {
	case rec = <-recorded:
	case <-time.After(3 * time.Second):
		t.Fatal("the app was never recorded")
	}
	if reads != 2 || read != "/workspace/.aseman/platform-clients/acme-shop/acme-shop.apk" || rec.Version != "1.0.5" || rec.AppID != "com.acme.shop" ||
		rec.SHA256 != hex.EncodeToString(sum[:]) || rec.BuiltBy != person.String() || rec.Size != int64(len(apk)) {
		t.Fatalf("recorded %+v (read %s)", rec, read)
	}
	id, _ := identity.Parse(rec.FileID)
	file, err := s.GetFile(ctx, id)
	if err != nil || file.Mime != apkMime || file.SpaceID != sp.ID {
		t.Fatalf("stored file: %+v %v", file, err)
	}
	deadline := time.Now().Add(2 * time.Second)
	for {
		st, _ := s.PlatformClientBuildStatus(ctx, person, target)
		if st.State == "done" {
			if st.URL != "https://aseman.example/v1/platforms/acme-shop/client/android.apk" {
				t.Fatalf("download address: %+v", st)
			}
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("never done: %+v", st)
		}
		time.Sleep(5 * time.Millisecond)
	}
}

// A build that fails says why, with the build's last output.
func TestAFailedPlatformAppBuildSaysWhy(t *testing.T) {
	s, ctx := fileToolHarness(t)
	person := directPerson(t, s, ctx, "00000000000000010000000000000001", "founder")
	sp, err := s.CreateSpace(ctx, person, "studio", "")
	if err != nil {
		t.Fatal(err)
	}
	builder := &fakeBuilder{status: `{"state":"failed","step":"building the APK","error":"the APK did not build","log":"Gradle: 429 Too Many Requests"}`}
	s.clientExecFn = builder.exec
	s.clientPollEvery = 5 * time.Millisecond
	target := models.PlatformClientTarget{PlatformID: "pf1", Slug: "acme", Name: "Acme", ProxyID: "p1", SpaceID: sp.ID.String(), UI: "elpian"}
	if _, err := s.StartPlatformClientBuild(ctx, person, target, models.PlatformClientOptions{NodeURL: "http://node.local:8080"}); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(2 * time.Second)
	for {
		st, _ := s.PlatformClientBuildStatus(ctx, person, target)
		if st.State == "failed" {
			if st.Error != "the APK did not build" || !strings.Contains(st.Log, "429") {
				t.Fatalf("failure: %+v", st)
			}
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("never failed: %+v", st)
		}
		time.Sleep(5 * time.Millisecond)
	}
}

// What a build refuses before it starts.
func TestAPlatformAppNeedsAnElpianFrontendAndAPublicNode(t *testing.T) {
	t.Setenv("ASEMAN_PUBLIC_URL", "")
	s, ctx := fileToolHarness(t)
	person := directPerson(t, s, ctx, "00000000000000010000000000000001", "founder")
	outsider := directPerson(t, s, ctx, "00000000000000010000000000000002", "outsider")
	sp, err := s.CreateSpace(ctx, person, "studio", "")
	if err != nil {
		t.Fatal(err)
	}
	s.clientExecFn = func(context.Context, identity.ID, string) (string, error) {
		t.Fatal("the computer was asked to build")
		return "", nil
	}
	base := models.PlatformClientTarget{PlatformID: "pf1", Slug: "acme", Name: "Acme", ProxyID: "p1", SpaceID: sp.ID.String(), UI: "elpian"}
	cases := []struct {
		name   string
		target func(models.PlatformClientTarget) models.PlatformClientTarget
		who    identity.ID
		opts   models.PlatformClientOptions
		code   errs.Code
	}{
		{"no frontend", func(t models.PlatformClientTarget) models.PlatformClientTarget { t.ProxyID = ""; return t }, person, models.PlatformClientOptions{NodeURL: "https://n"}, errs.CodeInvalidArgument},
		{"web frontend", func(t models.PlatformClientTarget) models.PlatformClientTarget { t.UI = "web"; return t }, person, models.PlatformClientOptions{NodeURL: "https://n"}, errs.CodeInvalidArgument},
		{"not a member", func(t models.PlatformClientTarget) models.PlatformClientTarget { return t }, outsider, models.PlatformClientOptions{NodeURL: "https://n"}, errs.CodePermission},
		{"no public address", func(t models.PlatformClientTarget) models.PlatformClientTarget { return t }, person, models.PlatformClientOptions{}, errs.CodeUnavailable},
		{"bad app id", func(t models.PlatformClientTarget) models.PlatformClientTarget { return t }, person, models.PlatformClientOptions{NodeURL: "https://n", AppID: "shop"}, errs.CodeInvalidArgument},
		{"bad version", func(t models.PlatformClientTarget) models.PlatformClientTarget { return t }, person, models.PlatformClientOptions{NodeURL: "https://n", Version: "v2"}, errs.CodeInvalidArgument},
	}
	for _, c := range cases {
		if _, err := s.StartPlatformClientBuild(ctx, c.who, c.target(base), c.opts); errs.CodeOf(err) != c.code {
			t.Fatalf("%s: %v", c.name, err)
		}
	}
	if nextClientVersion("") != "1.0.0" || nextClientVersion("2.3.9") != "2.3.10" || nextClientVersion("x") != "1.0.0" {
		t.Fatal("versions")
	}
}

// Godot is off by default; asking turns it on, and a rebuild keeps the last
// build's choice until it is turned off again.
func TestAPlatformAppTurnsGodotOnOnlyWhenAsked(t *testing.T) {
	t.Setenv("ASEMAN_PUBLIC_URL", "https://aseman.example")
	s, ctx := fileToolHarness(t)
	person := directPerson(t, s, ctx, "00000000000000010000000000000001", "founder")
	sp, err := s.CreateSpace(ctx, person, "studio", "")
	if err != nil {
		t.Fatal(err)
	}
	var commands []string
	s.clientExecFn = func(_ context.Context, _ identity.ID, command string) (string, error) {
		if strings.Contains(command, "nohup") {
			commands = append(commands, command)
			return "exit=0\nstarted\n", nil
		}
		return "exit=0\nrunning=0\n{\"state\":\"failed\",\"error\":\"stop\"}\n", nil
	}
	s.clientPollEvery = time.Millisecond
	target := models.PlatformClientTarget{PlatformID: "pf1", Slug: "acme", Name: "Acme", ProxyID: "p1", SpaceID: sp.ID.String(), UI: "elpian"}
	on, off := true, false
	build := func(tg models.PlatformClientTarget, godot *bool) models.PlatformClientBuild {
		t.Helper()
		b, err := s.StartPlatformClientBuild(ctx, person, tg, models.PlatformClientOptions{Godot: godot})
		if err != nil {
			t.Fatal(err)
		}
		deadline := time.Now().Add(2 * time.Second)
		for st, _ := s.PlatformClientBuildStatus(ctx, person, tg); st.State == "building"; st, _ = s.PlatformClientBuildStatus(ctx, person, tg) {
			if time.Now().After(deadline) {
				t.Fatal("the build never ended")
			}
			time.Sleep(time.Millisecond)
		}
		return b
	}
	if b := build(target, nil); b.Godot || strings.Contains(commands[0], "--godot") {
		t.Fatalf("first build: %+v %s", b, commands[0])
	}
	if b := build(target, &on); !b.Godot || !strings.Contains(commands[1], "'--godot'") {
		t.Fatalf("turned on: %+v %s", b, commands[1])
	}
	withGodot := target
	withGodot.Client = &models.PlatformClient{Version: "1.0.0", Godot: true}
	if b := build(withGodot, nil); !b.Godot || !strings.Contains(commands[2], "'--godot'") {
		t.Fatalf("a rebuild keeps Godot on: %+v %s", b, commands[2])
	}
	if b := build(withGodot, &off); b.Godot || strings.Contains(commands[3], "--godot") {
		t.Fatalf("turned off: %+v %s", b, commands[3])
	}
}
