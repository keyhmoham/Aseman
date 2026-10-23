package surface

// Kind returns the component type name. Prefers "type" when it names a known
// catalog component; otherwise falls back to legacy "component". Chart (and
// similar) may keep a non-component "type" property (e.g. "line") alongside
// "component":"Chart".
func Kind(c map[string]any) string {
	t, _ := c["type"].(string)
	comp, _ := c["component"].(string)
	if known[t] {
		return t
	}
	if comp != "" {
		return comp
	}
	return t
}

// NormalizeKind writes the component kind into "type" when safe. When "type"
// already holds a non-component property (Chart series kind), "component" is
// kept as the discriminator.
func NormalizeKind(c map[string]any) {
	kind := Kind(c)
	if kind == "" {
		return
	}
	t, _ := c["type"].(string)
	if t == "" || known[t] {
		c["type"] = kind
		if comp, _ := c["component"].(string); comp == "" || known[comp] || stringsEqualFold(comp, kind) {
			delete(c, "component")
		}
		return
	}
	// type is a property (e.g. chart series); keep component as kind.
	if comp, _ := c["component"].(string); comp == "" {
		c["component"] = kind
	}
}

func stringsEqualFold(a, b string) bool {
	if a == b {
		return true
	}
	if len(a) != len(b) {
		return false
	}
	for i := 0; i < len(a); i++ {
		ca, cb := a[i], b[i]
		if ca >= 'A' && ca <= 'Z' {
			ca += 'a' - 'A'
		}
		if cb >= 'A' && cb <= 'Z' {
			cb += 'a' - 'A'
		}
		if ca != cb {
			return false
		}
	}
	return true
}
