package developer

import (
	"bytes"
	"context"
	"encoding/base64"
	"io"
	"net/http"
	"path"
	"strings"

	"github.com/tradera/tradera/internal/plugins/entity"
	"github.com/tradera/tradera/internal/plugins/identity"
	"github.com/tradera/tradera/pkg/errs"
	"github.com/tradera/tradera/plugins/actions/developer/models"
	"github.com/tradera/tradera/plugins/adapters/database/ports"
)

// MaxFileBytes is the largest file one upload may carry.
const MaxFileBytes = 25 << 20

// FileView is a stored file as the console shows it.
type FileView struct {
	ID        string `json:"id"`
	Name      string `json:"name"`
	Size      int64  `json:"size"`
	Mime      string `json:"mime"`
	CreatedAt string `json:"createdAt"`
	Purpose   string `json:"purpose"`
}

func fileView(f models.File) FileView {
	return FileView{ID: f.ID.String(), Name: f.Name, Size: f.Size, Mime: f.Mime, CreatedAt: stamp(f.CreatedAt), Purpose: f.Purpose}
}

// cleanName keeps a file's name to its last element: a name is a label, never a path.
func cleanName(name string) string {
	name = strings.TrimSpace(strings.ReplaceAll(name, "\\", "/"))
	name = path.Base(name)
	if name == "." || name == "/" || name == "" {
		return "file"
	}
	if len(name) > 200 {
		name = name[:200]
	}
	return name
}

// Files lists an organization's files, newest first.
func (s *Service) Files(ctx context.Context, org identity.ID) ([]FileView, error) {
	var list []models.File
	if err := s.R.List(ctx, "dev_files", database.Filter{Equal: map[string]any{"org_id": org.String()}, OrderBy: "created_at"}, &list); err != nil {
		return nil, err
	}
	out := make([]FileView, 0, len(list))
	for _, f := range list {
		out = append(out, fileView(f))
	}
	return out, nil
}

func (s *Service) loadFile(ctx context.Context, org identity.ID, id string) (*models.File, error) {
	fid, err := identity.Parse(id)
	if err != nil {
		return nil, errs.NotFound("file")
	}
	var f models.File
	if err := s.R.Get(ctx, "dev_files", fid, &f); err != nil || f.OrgID != org {
		return nil, errs.NotFound("file")
	}
	return &f, nil
}

// File is one file's details.
func (s *Service) File(ctx context.Context, org identity.ID, id string) (*FileView, error) {
	f, err := s.loadFile(ctx, org, id)
	if err != nil {
		return nil, err
	}
	v := fileView(*f)
	return &v, nil
}

// Upload stores a file for an organization.
func (s *Service) Upload(ctx context.Context, org identity.ID, name, mime, purpose string, data []byte) (*FileView, error) {
	if int64(len(data)) > MaxFileBytes {
		return nil, errs.InvalidArgument("A file can be up to 25 MB.")
	}
	if s.FS() == nil {
		return nil, errs.New(errs.CodeUnavailable, "File storage is unavailable on this node.")
	}
	if err := s.Fin.EnsureFunds(ctx, org, minFunds); err != nil {
		return nil, errs.New(errs.CodeFinance, "This organization's balance is too low to store files. Add funds under Billing in the console.")
	}
	name = cleanName(name)
	if mime == "" {
		mime = http.DetectContentType(data)
	}
	if purpose = strings.TrimSpace(purpose); purpose == "" {
		purpose = "general"
	}
	if len(purpose) > 40 {
		return nil, errs.InvalidArgument("purpose can be up to 40 characters.")
	}
	id, err := s.newID()
	if err != nil {
		return nil, err
	}
	key := "developer/" + org.String() + "/" + id.String()
	if err := s.FS().Put(ctx, key, bytes.NewReader(data), int64(len(data)), mime); err != nil {
		return nil, err
	}
	now := s.now()
	f := &models.File{Entity: entity.Entity{ID: id, CreatedAt: now, UpdatedAt: now}, OrgID: org, Name: name, Size: int64(len(data)), Mime: mime, Purpose: purpose, Key: key}
	if err := s.R.CreateID(ctx, "dev_files", id, f); err != nil {
		_ = s.FS().Delete(context.WithoutCancel(ctx), key)
		return nil, err
	}
	v := fileView(*f)
	return &v, nil
}

func (s *Service) fileBytes(ctx context.Context, org identity.ID, id string) (*models.File, []byte, error) {
	f, err := s.loadFile(ctx, org, id)
	if err != nil {
		return nil, nil, err
	}
	rc, err := s.FS().Get(ctx, f.Key)
	if err != nil {
		return nil, nil, errs.NotFound("file")
	}
	defer rc.Close()
	data, err := io.ReadAll(io.LimitReader(rc, MaxFileBytes+1))
	return f, data, err
}

// ReadFile returns a file and its bytes.
func (s *Service) ReadFile(ctx context.Context, org identity.ID, id string) (*FileView, []byte, error) {
	f, data, err := s.fileBytes(ctx, org, id)
	if err != nil {
		return nil, nil, err
	}
	v := fileView(*f)
	return &v, data, nil
}

// DeleteFile removes a file and its bytes.
func (s *Service) DeleteFile(ctx context.Context, org identity.ID, id string) error {
	f, err := s.loadFile(ctx, org, id)
	if err != nil {
		return err
	}
	if err := s.R.Delete(ctx, "dev_files", f.ID); err != nil {
		return err
	}
	_ = s.FS().Delete(ctx, f.Key)
	return nil
}

// DecodeBase64 reads the console's file uploads, which carry their bytes as base64.
func DecodeBase64(text string) ([]byte, error) {
	data, err := base64.StdEncoding.DecodeString(text)
	if err != nil {
		return nil, errs.InvalidArgument("The file's content is not valid base64.")
	}
	return data, nil
}
