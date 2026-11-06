package apihttp

import (
	"context"
	"encoding/json"
	"testing"

	"github.com/aseman/aseman/internal/plugins/entity"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/plugins/actions/developer/models"
	"github.com/aseman/aseman/plugins/actions/spaces/models/filedata"
	network "github.com/aseman/aseman/plugins/adapters/network/ports"
)

type clientSpaces struct {
	FileSpaces
	client *models.PlatformClient
	file   *filedata.File
	data   []byte
}

func (s *clientSpaces) PlatformClientFile(_ context.Context, ref string) (*models.PlatformClient, error) {
	if ref != "acme" || s.client == nil {
		return nil, errs.NotFound("Acme has no Android app yet")
	}
	return s.client, nil
}
func (s *clientSpaces) GetFile(_ context.Context, id identity.ID) (*filedata.File, error) {
	if s.file == nil || id != s.file.ID {
		return nil, errs.NotFound("file")
	}
	return s.file, nil
}
func (s *clientSpaces) ReadFileBytes(context.Context, *filedata.File) ([]byte, error) { return s.data, nil }

func clientRequest(slug, file string) *network.Request {
	params, _ := json.Marshal(map[string]string{"slug": slug, "file": file})
	return &network.Request{Method: network.MethodGet, Header: map[string]string{"x-route-params": string(params)}}
}

// Anyone downloads a platform's Android app, signed in or not, while its
// computer sleeps: the APK is the node's.
func TestAnyoneDownloadsAPlatformsAndroidApp(t *testing.T) {
	fid := identity.ID{Node: 1, Entity: 5}
	spaces := &clientSpaces{
		client: &models.PlatformClient{FileID: fid.String(), Version: "1.0.2", SHA256: "abc"},
		file:   &filedata.File{Entity: entity.Entity{ID: fid}, Name: "acme.apk"},
		data:   []byte("PK apk"),
	}
	a := &API{Auth: &viewerAuth{}, Spaces: spaces}
	resp, err := a.platformClientDownload(context.Background(), clientRequest("acme", "android.apk"))
	if err != nil || resp.Status != 200 || string(resp.Body) != "PK apk" {
		t.Fatalf("download: %+v %v", resp, err)
	}
	if resp.Header["Content-Type"] != "application/vnd.android.package-archive" || resp.Header["Content-Disposition"] != `attachment; filename="acme-1.0.2.apk"` || resp.Header["ETag"] != `"abc"` {
		t.Fatalf("headers: %v", resp.Header)
	}
	if _, err := a.platformClientDownload(context.Background(), clientRequest("acme", "ios.ipa")); errs.CodeOf(err) != errs.CodeNotFound {
		t.Fatalf("another file: %v", err)
	}
	if _, err := a.platformClientDownload(context.Background(), clientRequest("nope", "android.apk")); errs.CodeOf(err) != errs.CodeNotFound {
		t.Fatalf("a platform with no app: %v", err)
	}
}
