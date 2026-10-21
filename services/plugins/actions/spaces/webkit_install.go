package spaces

// Aseman's web UI kit on the space's computer: agents read its guide there
// (/opt/aseman/webkit/README.md) and copy it into a page they check locally;
// previews get it from the gateway itself. The node writes it onto a machine
// that has just woken when the machine's copy is missing or older, like the
// desktop program.

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"strings"

	"github.com/aseman/aseman/pkg/webkit"
	"github.com/aseman/aseman/plugins/actions/bots/models/bot"
	vmm "github.com/aseman/aseman/plugins/adapters/vmm/ports"
)

// WebkitDir is where the kit lives on the computer.
const WebkitDir = "/opt/aseman/webkit"

// webkitChunk keeps every command under the kernel's limit on one argument
// (128 KiB), base64 included.
const webkitChunk = 72 << 10

// webkitVersion names the kit's contents.
func webkitVersion() string {
	h := sha256.New()
	for _, name := range webkit.Names() {
		body, _, _ := webkit.File(name)
		h.Write([]byte(name))
		h.Write(body)
	}
	return hex.EncodeToString(h.Sum(nil))[:16]
}

// webkitCheckCommand prints "current" when the machine has this kit.
func webkitCheckCommand(version string) string {
	return `test "$(cat ` + WebkitDir + `/VERSION 2>/dev/null)" = "` + version + `" && echo current || echo stale`
}

// webkitInstallCommands write the kit: each file in chunks into a staging
// folder, then the folder replaces the old one in one move.
func webkitInstallCommands(version string) []string {
	stage := WebkitDir + ".new"
	cmds := []string{"rm -rf " + stage + " && mkdir -p " + stage}
	for _, name := range webkit.Names() {
		body, _, _ := webkit.File(name)
		for i := 0; i < len(body) || i == 0; i += webkitChunk {
			end := min(len(body), i+webkitChunk)
			op := ">>"
			if i == 0 {
				op = ">"
			}
			cmds = append(cmds, "echo "+base64.StdEncoding.EncodeToString(body[i:end])+" | base64 -d "+op+stage+"/"+name)
			if end == len(body) {
				break
			}
		}
	}
	cmds = append(cmds, "echo "+version+" >"+stage+"/VERSION && rm -rf "+WebkitDir+" && mv "+stage+" "+WebkitDir+" && chmod -R a+rX "+WebkitDir)
	return cmds
}

// provideWebkit puts the kit on a machine that has just woken. Best effort:
// pages work without it (the gateway serves the kit to previews).
func (s *Service) provideWebkit(ctx context.Context, rec *bot.Bot) {
	vm := s.K.VMMFor(vmm.Type(rec.VMType))
	sender, ok := vm.(interface {
		Send(ctx context.Context, vmID, command string) (string, error)
	})
	if vm == nil || !ok {
		return
	}
	version := webkitVersion()
	out, err := sender.Send(ctx, rec.VMID, webkitCheckCommand(version))
	if err != nil || strings.Contains(out, "current") {
		return
	}
	for _, cmd := range webkitInstallCommands(version) {
		if _, err := sender.Send(ctx, rec.VMID, cmd); err != nil {
			if s.L != nil {
				s.L.Warn("web UI kit not installed on the computer", "vm", rec.VMID, "err", err.Error())
			}
			return
		}
	}
}
