package hostaccess

import (
	"context"
	"fmt"
	"strings"

	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/pkg/untrusted"
	hm "github.com/aseman/aseman/plugins/actions/hostaccess/models"
	"github.com/aseman/aseman/plugins/adapters/vmm/ports"
)

// A shared folder is attached to a message like a file: the person picks a
// folder of one of their project computers in the composer, and the message
// carries it as "folder:<id>". The agent that answers sees it in its prompt
// (what it is, where, whether it may write, and what is in it) and works in
// it with the folder tools. The folder stays on that computer.

// FolderRefPrefix marks a folder among a message's attachments.
const FolderRefPrefix = "folder:"

// listingCap bounds how many entries of a folder go into a prompt.
const listingCap = 200

func (s *Service) attached(ctx context.Context, ref string) (*hm.SharedFolder, error) {
	if !strings.HasPrefix(ref, FolderRefPrefix) {
		return nil, errs.InvalidArgument("not a folder")
	}
	fid, err := identity.Parse(strings.TrimPrefix(ref, FolderRefPrefix))
	if err != nil {
		return nil, errs.InvalidArgument("invalid folder")
	}
	var f hm.SharedFolder
	if err := s.R.Get(ctx, "shared_folders", fid, &f); err != nil {
		return nil, err
	}
	return &f, nil
}

// CanAttachFolder lets a person attach only their own shared folders.
func (s *Service) CanAttachFolder(ctx context.Context, caller identity.ID, ref string) error {
	f, err := s.attached(ctx, ref)
	if err != nil {
		return err
	}
	if f.OwnerID != caller.String() {
		return errs.Permission("you can attach only folders you shared")
	}
	if !f.Enabled {
		return errs.Conflict(f.Name + " is no longer shared")
	}
	return nil
}

func (s *Service) projectName(ctx context.Context, space string) string {
	id, err := identity.Parse(space)
	if err != nil {
		return "a project"
	}
	var sp struct {
		Name string `json:"name"`
	}
	if s.R.Get(ctx, "spaces", id, &sp) != nil || sp.Name == "" {
		return "a project"
	}
	return sp.Name
}

// FolderMeta is how a message shows an attached folder.
func (s *Service) FolderMeta(ctx context.Context, ref string) (map[string]any, error) {
	f, err := s.attached(ctx, ref)
	if err != nil {
		return nil, err
	}
	return map[string]any{"id": ref, "kind": "folder", "name": f.Name, "mime": "inode/directory", "size": 0,
		"access": f.Access, "path": "/workspace/" + f.Path, "project": s.projectName(ctx, f.SpaceID)}, nil
}

// FolderAttachment is an attached folder as the agent answering the message
// sees it, for the person who sent it.
func (s *Service) FolderAttachment(ctx context.Context, caller identity.ID, ref string) (vmm.FileAttachment, error) {
	if err := s.CanAttachFolder(ctx, caller, ref); err != nil {
		return vmm.FileAttachment{}, err
	}
	f, _ := s.attached(ctx, ref)
	access := "read only (folder_list, folder_read)"
	if f.Access == hm.AccessWrite {
		access = "read and write (folder_list, folder_read, folder_write)"
	}
	var b strings.Builder
	fmt.Fprintf(&b, "Attached folder %q: /workspace/%s on the computer of the project %q, shared with you %s.\n",
		f.Name, f.Path, s.projectName(ctx, f.SpaceID), access)
	fmt.Fprintf(&b, "It is not on your own computer: work in it with those tools and folder %q.\n", f.Name)
	if s.Files != nil {
		if out, err := s.Files.ProjectFiles(ctx, caller, f.SpaceID, "list", f.Path, ""); err == nil {
			items, _ := out["items"].([]any)
			var l strings.Builder
			for i, it := range items {
				if i == listingCap {
					fmt.Fprintf(&l, "… and %d more\n", len(items)-listingCap)
					break
				}
				e, _ := it.(map[string]any)
				name, _ := e["name"].(string)
				if e["type"] == "dir" {
					l.WriteString(name + "/\n")
				} else {
					fmt.Fprintf(&l, "%s (%v bytes)\n", name, e["size"])
				}
			}
			if len(items) == 0 {
				l.WriteString("(empty)\n")
			}
			// File names are the folder's, not instructions.
			b.WriteString("Contents:\n" + untrusted.Wrap("folder "+f.Name, l.String()))
		}
	}
	return vmm.FileAttachment{ID: ref, Name: f.Name + "/", Mime: "inode/directory", Content: b.String()}, nil
}
