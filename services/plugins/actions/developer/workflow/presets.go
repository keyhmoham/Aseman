package workflow

import (
	"sort"
	"strings"
)

// Preset is a built-in kind of resource an upsert knows how to find, create,
// update and delete. Each is written in the same terms a workflow would
// write a `define` in, so the reference shows exactly what it does.
//
// In a preset's templates:
//
//	params  the upsert's match, with, and create_with or update_with, merged
//	id      the resource's id (update and delete)
//	found   the record the find matched (update)
type Preset struct {
	Summary string `json:"summary"`
	ResourceDef
}

// merge lays a workflow's own define over the preset.
func (p Preset) merge(over *ResourceDef) *ResourceDef {
	d := p.ResourceDef
	if over == nil {
		return &d
	}
	if over.Find != nil {
		d.Find = over.Find
	}
	if over.Create != nil {
		d.Create = over.Create
	}
	if over.Update != nil {
		d.Update = over.Update
	}
	if over.Delete != nil {
		d.Delete = over.Delete
	}
	if over.Match != nil {
		d.Match = over.Match
	}
	if over.RecordID != "" {
		d.RecordID = over.RecordID
	}
	if over.Compare != nil {
		d.Compare = over.Compare
	}
	return &d
}

// PresetNames are the built-in resources, sorted.
func PresetNames() []string {
	out := make([]string, 0, len(Presets))
	for k := range Presets {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

func botPreset(kind, summary string, editable ...string) Preset {
	quoted := make([]string, len(editable))
	for i, f := range editable {
		quoted[i] = "'" + f + "'"
	}
	return Preset{Summary: summary, ResourceDef: ResourceDef{
		Find:    &Call{Action: "bots.bot_list", Items: "bots", Page: &Page{}},
		Match:   map[string]any{"name": "${{ params.name }}", "kind": kind},
		Create:  &Call{Action: "bots.bot_create", With: "${{ merge(omit(params, 'avatar'), object('kind', '" + kind + "')) }}", ID: "bot_id"},
		Update:  &Call{Action: "bots.bot_edit", With: "${{ merge(pick(params, " + strings.Join(quoted, ", ") + "), object('bot', id)) }}"},
		Delete:  &Call{Action: "bots.bot_delete", With: map[string]any{"bot": "${{ id }}"}},
		Compare: editable,
	}}
}

// Presets are the built-in resources.
var Presets = map[string]Preset{
	"space": {Summary: "A space (project) the person belongs to, by name. with: name, description, metadata, bots, avatar.", ResourceDef: ResourceDef{
		Find:    &Call{Action: "spaces.space_list", With: map[string]any{"kind": "all"}, Items: "spaces", Page: &Page{}},
		Match:   map[string]any{"name": "${{ params.name }}"},
		Create:  &Call{Action: "spaces.space_create", With: "${{ pick(params, 'name', 'description', 'metadata', 'bots') }}", ID: "space_id"},
		Update:  &Call{Action: "spaces.space_update", With: "${{ merge(pick(params, 'name', 'description', 'avatar'), object('space', id)) }}"},
		Delete:  &Call{Action: "spaces.space_delete", With: map[string]any{"space": "${{ id }}"}},
		Compare: []string{"name", "description", "avatar"},
	}},
	"room": {Summary: "A room of a space, by name. with: space, name, topic, purpose, icon, color.", ResourceDef: ResourceDef{
		Find:    &Call{Action: "spaces.room_list", With: map[string]any{"space": "${{ params.space }}"}, Items: "rooms", Page: &Page{}},
		Match:   map[string]any{"name": "${{ params.name }}"},
		Create:  &Call{Action: "spaces.room_create", With: "${{ params }}", ID: "room_id"},
		Update:  &Call{Action: "spaces.room_update", With: "${{ merge(pick(params, 'name', 'topic', 'purpose', 'icon', 'color'), object('room', id)) }}"},
		Delete:  &Call{Action: "spaces.room_delete", With: map[string]any{"room": "${{ id }}"}},
		Compare: []string{"name", "topic", "purpose", "icon", "color"},
	}},
	"agent": botPreset("agent", "An agent the person owns, by name. with: name, description, instructions, provider, model, max_tokens, max_turns, skills, allowed_tools, resources, cost, env.",
		"name", "instructions", "provider", "model", "cost", "descriptor", "description", "max_turns", "max_tokens", "skills", "resources", "avatar"),
	"app": botPreset("tool", "An app (tool) the person owns, by name. with: name, description, vm_type, image_ref, spec_yml, entities, frontend, module, widget_dsl, cost, env, args.",
		"name", "description", "cost", "descriptor", "avatar"),
	"theme": botPreset("theme", "A theme the person owns, by name. with: name, description, entities, frontend.",
		"name", "description", "avatar"),
	"space_bot": {Summary: "An agent or app installed in a space. with: space, bot (its id), room.", ResourceDef: ResourceDef{
		Find:     &Call{Action: "spaces.bots_list", With: map[string]any{"space": "${{ params.space }}"}, Items: "bots"},
		Match:    map[string]any{"id": "${{ params.bot }}"},
		Create:   &Call{Action: "spaces.bot_add", With: "${{ pick(params, 'space', 'room', 'bot') }}", ID: "${{ params.bot }}"},
		Delete:   &Call{Action: "spaces.bot_remove", With: map[string]any{"space": "${{ params.space }}", "bot": "${{ id }}"}},
		RecordID: "id",
	}},
	"proxy": {Summary: "A preview: a port of a space's computer served by the gateway, by port. with: space, port, title, start, path, room, show.", ResourceDef: ResourceDef{
		Find:   &Call{Action: "spaces.proxy_list", With: map[string]any{"space": "${{ params.space }}"}, Items: "proxies"},
		Match:  map[string]any{"port": "${{ params.port }}"},
		Create: &Call{Action: "spaces.proxy_create", With: "${{ params }}", ID: "proxy_id"},
		Delete: &Call{Action: "spaces.proxy_delete", With: map[string]any{"proxy": "${{ id }}"}},
	}},
	"org": {Summary: "A team developer organization, by name. with: name.", ResourceDef: ResourceDef{
		Find:   &Call{Action: "developer.orgs_list", Items: "orgs"},
		Match:  map[string]any{"name": "${{ params.name }}"},
		Create: &Call{Action: "developer.org_create", With: map[string]any{"name": "${{ params.name }}"}, ID: "org.id"},
		Delete: &Call{Action: "developer.org_delete", With: map[string]any{"org": "${{ id }}"}},
	}},
	"member": {Summary: "A person in a developer organization, by handle. with: org, handle, role.", ResourceDef: ResourceDef{
		Find:    &Call{Action: "developer.members_list", With: map[string]any{"org": "${{ params.org }}"}, Items: "members"},
		Match:   map[string]any{"handle": "${{ trim(lower(params.handle), '@') }}"},
		Create:  &Call{Action: "developer.member_invite", With: "${{ pick(params, 'org', 'handle', 'role') }}", ID: "member.id"},
		Update:  &Call{Action: "developer.member_role", With: map[string]any{"org": "${{ params.org }}", "member": "${{ id }}", "role": "${{ params.role }}"}},
		Delete:  &Call{Action: "developer.member_remove", With: map[string]any{"org": "${{ params.org }}", "member": "${{ id }}"}},
		Compare: []string{"role"},
	}},
	"platform": {Summary: "The organization's sub-platform (one per organization). with: org, name, slug.", ResourceDef: ResourceDef{
		Find:    &Call{Action: "developer.platform_get", With: map[string]any{"org": "${{ params.org }}"}, Item: "platform"},
		Create:  &Call{Action: "developer.platform_create", With: "${{ pick(params, 'org', 'name', 'slug') }}", ID: "platform.id"},
		Update:  &Call{Action: "developer.platform_rename", With: "${{ pick(params, 'org', 'name') }}"},
		Delete:  &Call{Action: "developer.platform_delete", With: map[string]any{"org": "${{ params.org }}"}},
		Compare: []string{"name"},
	}},
	"key": {Summary: "A developer API key, by name. with: org, name, permissions, limits. The secret is in outputs.result.secret when it is created.", ResourceDef: ResourceDef{
		Find:    &Call{Action: "developer.keys_list", With: map[string]any{"org": "${{ params.org }}"}, Items: "keys"},
		Match:   map[string]any{"name": "${{ params.name }}", "status": "active"},
		Create:  &Call{Action: "developer.key_create", With: map[string]any{"org": "${{ params.org }}", "input": "${{ pick(params, 'name', 'permissions', 'limits') }}"}, ID: "key.id"},
		Update:  &Call{Action: "developer.key_update", With: map[string]any{"org": "${{ params.org }}", "id": "${{ id }}", "input": "${{ pick(params, 'name', 'permissions', 'limits') }}"}},
		Delete:  &Call{Action: "developer.key_delete", With: map[string]any{"org": "${{ params.org }}", "id": "${{ id }}"}},
		Compare: []string{"name", "permissions", "limits"},
	}},
	"computer": {Summary: "A developer computer, by name. with: org, name, image, cpu, memoryMb, …", ResourceDef: ResourceDef{
		Find:   &Call{Action: "developer.computers_list", With: map[string]any{"org": "${{ params.org }}"}, Items: "computers"},
		Match:  map[string]any{"name": "${{ params.name }}"},
		Create: &Call{Action: "developer.computer_create", With: map[string]any{"org": "${{ params.org }}", "input": "${{ omit(params, 'org') }}"}, ID: "computer.id"},
		Delete: &Call{Action: "developer.computer_delete", With: map[string]any{"org": "${{ params.org }}", "id": "${{ id }}"}},
	}},
}
