package nomad

import (
	"testing"

	"github.com/aseman/aseman/plugins/adapters/vmm/ports"
)

func TestToolRuntimeJobRunsTheRuntimeImage(t *testing.T) {
	a := &Adapter{toolRuntime: "aseman/tool-runtime:test", specs: map[string]vmm.VMSpec{}}
	for _, typ := range []vmm.Type{vmm.TypeElpian, vmm.TypeQuickJS} {
		job, err := a.buildJob(vmm.VMSpec{
			Name: "notes", Type: typ, ImageRef: "ignored",
			Resources:   vmm.ResourceSpec{Network: "aseman_default"},
			Environment: map[string]string{"ASEMAN_TOOL_ID": "abc"},
			Labels: map[string]string{
				vmm.LabelServiceID: "tool-abc", vmm.LabelNetworkAlias: "tool-abc", vmm.LabelServicePort: "8790",
			},
		})
		if err != nil {
			t.Fatal(err)
		}
		task := job.TaskGroups[0].Tasks[0]
		if task.Driver != "docker" || task.Config["image"] != "aseman/tool-runtime:test" {
			t.Fatalf("%s: runs %v on %s", typ, task.Config["image"], task.Driver)
		}
		if task.Env["ASEMAN_TOOL_ENGINE"] != string(typ) || task.Env["ASEMAN_TOOL_ID"] != "abc" {
			t.Fatalf("%s: env %v", typ, task.Env)
		}
		if *job.ID != "aseman-tool-abc" {
			t.Fatalf("job id %s", *job.ID)
		}
		aliases, _ := task.Config["network_aliases"].([]string)
		if task.Config["network_mode"] != "aseman_default" || len(aliases) != 1 || aliases[0] != "tool-abc" {
			t.Fatalf("network %v %v", task.Config["network_mode"], aliases)
		}
	}
}

func TestDockerJobKeepsItsImage(t *testing.T) {
	a := &Adapter{toolRuntime: "aseman/tool-runtime:test"}
	job, err := a.buildJob(vmm.VMSpec{Name: "x", Type: vmm.TypeDocker, ImageRef: "acme/tool:1"})
	if err != nil {
		t.Fatal(err)
	}
	if got := job.TaskGroups[0].Tasks[0].Config["image"]; got != "acme/tool:1" {
		t.Fatalf("image %v", got)
	}
}

func TestServiceAddress(t *testing.T) {
	if got := vmm.ServiceAddress(map[string]string{vmm.LabelNetworkAlias: "tool-a", vmm.LabelServicePort: "8790"}); got != "http://tool-a:8790" {
		t.Fatal(got)
	}
	if vmm.ServiceAddress(map[string]string{vmm.LabelNetworkAlias: "tool-a"}) != "" {
		t.Fatal("address without a port")
	}
}
