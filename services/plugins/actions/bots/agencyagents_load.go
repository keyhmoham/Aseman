package bots

import (
	"embed"
	"io/fs"
	"path"
	"regexp"
	"sort"
	"strings"
	"unicode"
)

// Agency Agents roster (MIT), vendored from
// https://github.com/msitarzewski/agency-agents — see agencyagents/SOURCE.md.
//
//go:embed agencyagents
var agencyAgentFS embed.FS

// divisionCategory maps an Agency Agents division folder onto Aseman's market
// categories (settings.categories).
var divisionCategory = map[string]string{
	"academic":            "education",
	"design":              "design",
	"engineering":         "coding",
	"finance":             "finance",
	"game-development":    "coding",
	"gis":                 "research",
	"healthcare":          "support",
	"marketing":           "marketing",
	"paid-media":          "marketing",
	"product":             "operations",
	"project-management":  "operations",
	"research":            "research",
	"sales":               "marketing",
	"security":            "coding",
	"spatial-computing":   "coding",
	"specialized":         "general",
	"support":             "support",
	"testing":             "coding",
}

var (
	frontmatterField = regexp.MustCompile(`(?m)^([A-Za-z0-9_-]+):\s*(.*)$`)
	headingEmoji     = regexp.MustCompile(`^[\x{1F300}-\x{1FAFF}\x{2600}-\x{27BF}\x{FE0F}\x{200D}\s*]+`)
	slugCleaner      = regexp.MustCompile(`[^a-z0-9]+`)
)

// loadAgencySampleAgents reads every agent markdown under agencyagents/ and
// turns it into a sampleAgent. Persona sections become instructions; each
// operational ## section becomes a skill.
func loadAgencySampleAgents() []sampleAgent {
	var files []string
	_ = fs.WalkDir(agencyAgentFS, "agencyagents", func(p string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() {
			return err
		}
		if !strings.HasSuffix(p, ".md") || path.Base(p) == "SOURCE.md" {
			return nil
		}
		files = append(files, p)
		return nil
	})
	sort.Strings(files)

	out := make([]sampleAgent, 0, len(files))
	for _, p := range files {
		raw, err := agencyAgentFS.ReadFile(p)
		if err != nil {
			continue
		}
		agent, ok := parseAgencyAgent(p, string(raw))
		if !ok {
			continue
		}
		out = append(out, agent)
	}
	return out
}

func parseAgencyAgent(filePath, raw string) (sampleAgent, bool) {
	raw = strings.TrimPrefix(raw, "\uFEFF")
	if !strings.HasPrefix(raw, "---") {
		return sampleAgent{}, false
	}
	rest := raw[3:]
	end := strings.Index(rest, "\n---")
	if end < 0 {
		return sampleAgent{}, false
	}
	fm := rest[:end]
	body := strings.TrimLeft(rest[end+4:], "\n")

	fields := parseFrontmatter(fm)
	name := strings.TrimSpace(fields["name"])
	desc := strings.TrimSpace(fields["description"])
	vibe := strings.TrimSpace(fields["vibe"])
	if name == "" || desc == "" {
		return sampleAgent{}, false
	}

	rel := strings.TrimPrefix(filePath, "agencyagents/")
	division, _, _ := strings.Cut(rel, "/")
	category := divisionCategory[division]
	if category == "" {
		category = "general"
	}

	slug := agencySlug(name)
	if slug == "" || slug == "aseman" || slug == "lead" {
		return sampleAgent{}, false
	}

	instructions, skills, usecases := splitAgencyBody(body, name, desc, vibe)
	if strings.TrimSpace(instructions) == "" {
		instructions = "You are " + name + ", a specialist. " + desc
		if vibe != "" {
			instructions += "\n\n" + vibe
		}
		instructions += "\n\nLoad the matching skill before you start a task. Deliver the concrete output the skill describes, and say what you produced."
	}
	if len(usecases) < 3 {
		usecases = ensureUsecases(usecases, desc, vibe, skills)
	}

	return sampleAgent{
		Slug:         slug,
		Name:         name,
		Username:     slug,
		Category:     category,
		Description:  desc,
		Usecases:     usecases,
		Instructions: strings.TrimSpace(instructions),
		Skills:       skills,
	}, true
}

func parseFrontmatter(fm string) map[string]string {
	out := map[string]string{}
	var key, val string
	flush := func() {
		if key == "" {
			return
		}
		out[key] = strings.TrimSpace(val)
		key, val = "", ""
	}
	for _, line := range strings.Split(fm, "\n") {
		if m := frontmatterField.FindStringSubmatch(line); m != nil && !strings.HasPrefix(line, " ") && !strings.HasPrefix(line, "\t") {
			flush()
			key = strings.ToLower(m[1])
			val = strings.TrimSpace(m[2])
			val = strings.Trim(val, `"'`)
			continue
		}
		if key != "" && (strings.HasPrefix(line, " ") || strings.HasPrefix(line, "\t")) {
			val = strings.TrimSpace(val + " " + strings.TrimSpace(line))
		}
	}
	flush()
	return out
}

type agencySection struct {
	Header string // empty for the preamble before the first ##
	Body   string // includes the ## header line when Header is set
	Soul   bool
}

func splitAgencyBody(body, name, desc, vibe string) (instructions string, skills []SkillConfig, usecases []string) {
	sections := splitMarkdownSections(body)
	var soul []string
	var preamble string
	for i, sec := range sections {
		if sec.Header == "" {
			preamble = strings.TrimSpace(sec.Body)
			continue
		}
		if sec.Soul {
			soul = append(soul, strings.TrimSpace(sec.Body))
			continue
		}
		title := cleanHeadingTitle(sec.Header)
		if title == "" {
			title = "Capability"
		}
		text := strings.TrimSpace(sec.Body)
		// Drop the heading line from the skill body; the skill name carries it.
		if lines := strings.SplitN(text, "\n", 2); len(lines) == 2 {
			text = strings.TrimSpace(lines[1])
		} else {
			text = ""
		}
		if text == "" {
			text = "Apply this capability as " + name + "."
		}
		skillDesc := firstSentence(text)
		if skillDesc == "" {
			skillDesc = title + " for " + name
		}
		if len(skillDesc) > 240 {
			skillDesc = skillDesc[:237] + "..."
		}
		skills = append(skills, SkillConfig{
			Name:         title,
			Description:  skillDesc,
			Instructions: text,
		})
		if isCoreMission(sec.Header) || (len(usecases) < 3 && i < 4) {
			usecases = append(usecases, extractUsecases(sec.Body)...)
		}
	}

	var b strings.Builder
	if preamble != "" {
		b.WriteString(preamble)
		b.WriteString("\n\n")
	} else {
		b.WriteString("You are **")
		b.WriteString(name)
		b.WriteString("**. ")
		b.WriteString(desc)
		if vibe != "" {
			b.WriteString("\n\n")
			b.WriteString(vibe)
		}
		b.WriteString("\n\n")
	}
	for _, s := range soul {
		b.WriteString(s)
		b.WriteString("\n\n")
	}
	b.WriteString("When a task matches one of your skills, read that skill's instructions before you act. Deliver the concrete output the skill describes, and say what you produced.\n")
	instructions = strings.TrimSpace(b.String())
	return instructions, skills, uniqStrings(usecases)
}

func splitMarkdownSections(body string) []agencySection {
	lines := strings.Split(body, "\n")
	var sections []agencySection
	var cur agencySection
	var fenceMarker byte
	var fenceLen int
	flush := func() {
		if cur.Header == "" && strings.TrimSpace(cur.Body) == "" {
			return
		}
		sections = append(sections, cur)
		cur = agencySection{}
	}
	for _, line := range lines {
		if fenceMarker != 0 {
			cur.Body += line + "\n"
			if closed, _ := fenceCloses(line, fenceMarker, fenceLen); closed {
				fenceMarker, fenceLen = 0, 0
			}
			continue
		}
		if open, marker, length := fenceOpens(line); open {
			fenceMarker, fenceLen = marker, length
			cur.Body += line + "\n"
			continue
		}
		if strings.HasPrefix(line, "## ") {
			flush()
			cur = agencySection{Header: line, Body: line + "\n", Soul: isSoulHeader(line)}
			continue
		}
		cur.Body += line + "\n"
	}
	flush()
	return sections
}

func fenceOpens(line string) (bool, byte, int) {
	i := 0
	for i < len(line) && i < 3 && line[i] == ' ' {
		i++
	}
	if i >= len(line) {
		return false, 0, 0
	}
	ch := line[i]
	if ch != '`' && ch != '~' {
		return false, 0, 0
	}
	j := i
	for j < len(line) && line[j] == ch {
		j++
	}
	if j-i < 3 {
		return false, 0, 0
	}
	return true, ch, j - i
}

func fenceCloses(line string, marker byte, openLen int) (bool, int) {
	i := 0
	for i < len(line) && i < 3 && line[i] == ' ' {
		i++
	}
	if i >= len(line) || line[i] != marker {
		return false, 0
	}
	j := i
	for j < len(line) && line[j] == marker {
		j++
	}
	if j-i < openLen {
		return false, 0
	}
	rest := strings.TrimSpace(line[j:])
	return rest == "", j - i
}

func isSoulHeader(line string) bool {
	// Mirrors agency-agents scripts/convert.sh openclaw SOUL keywords.
	h := strings.ToLower(line)
	return strings.Contains(h, "identity") ||
		(strings.Contains(h, "learning") && strings.Contains(h, "memory")) ||
		strings.Contains(h, "communication") ||
		strings.Contains(h, "style") ||
		strings.Contains(h, "critical rule") ||
		strings.Contains(h, "rules you must follow")
}

func isCoreMission(header string) bool {
	h := strings.ToLower(header)
	return strings.Contains(h, "core mission") || strings.Contains(h, "mission")
}

func cleanHeadingTitle(header string) string {
	t := strings.TrimSpace(strings.TrimPrefix(header, "##"))
	t = headingEmoji.ReplaceAllString(t, "")
	t = strings.TrimSpace(t)
	t = strings.Trim(t, "*_ ")
	return t
}

func extractUsecases(section string) []string {
	var out []string
	for _, line := range strings.Split(section, "\n") {
		trim := strings.TrimSpace(line)
		switch {
		case strings.HasPrefix(trim, "### "):
			title := cleanHeadingTitle("## " + strings.TrimPrefix(trim, "### "))
			if title != "" && !isGenericUsecase(title) {
				out = append(out, title)
			}
		case strings.HasPrefix(trim, "- "), strings.HasPrefix(trim, "* "):
			item := strings.TrimSpace(trim[2:])
			item = strings.Trim(item, "*_ ")
			// Prefer short capability phrases over long bullets.
			if len(item) >= 12 && len(item) <= 80 && !strings.HasPrefix(item, "[") {
				out = append(out, item)
			}
		}
		if len(out) >= 6 {
			break
		}
	}
	return out
}

func isGenericUsecase(s string) bool {
	l := strings.ToLower(s)
	return l == "overview" || l == "summary" || strings.HasPrefix(l, "step ")
}

func ensureUsecases(have []string, desc, vibe string, skills []SkillConfig) []string {
	out := append([]string{}, have...)
	for _, sk := range skills {
		if len(out) >= 3 {
			break
		}
		if sk.Name != "" && !isGenericUsecase(sk.Name) {
			out = append(out, sk.Name)
		}
	}
	fallbacks := []string{}
	if vibe != "" {
		fallbacks = append(fallbacks, vibe)
	}
	for _, part := range splitDescParts(desc) {
		fallbacks = append(fallbacks, part)
	}
	fallbacks = append(fallbacks,
		"Specialist work in this domain",
		"Hands-on delivery for this role",
		"Review and improve existing work",
	)
	for _, f := range fallbacks {
		if len(out) >= 3 {
			break
		}
		f = strings.TrimSpace(f)
		if len(f) >= 12 {
			out = append(out, f)
		}
	}
	return uniqStrings(out)
}

func splitDescParts(desc string) []string {
	var parts []string
	for _, p := range strings.FieldsFunc(desc, func(r rune) bool {
		return r == ',' || r == ';' || r == '.'
	}) {
		p = strings.TrimSpace(p)
		if len(p) >= 12 && len(p) <= 100 {
			parts = append(parts, p)
		}
	}
	return parts
}

func firstSentence(text string) string {
	text = strings.TrimSpace(text)
	if text == "" {
		return ""
	}
	// Skip fenced blocks / headings at the start.
	for _, line := range strings.Split(text, "\n") {
		t := strings.TrimSpace(line)
		if t == "" || strings.HasPrefix(t, "#") || strings.HasPrefix(t, "```") || strings.HasPrefix(t, "|") {
			continue
		}
		t = strings.TrimLeftFunc(t, func(r rune) bool { return r == '>' || r == '-' || r == '*' || unicode.IsSpace(r) })
		if t == "" {
			continue
		}
		if i := strings.IndexAny(t, ".!?"); i > 20 {
			return strings.TrimSpace(t[:i+1])
		}
		return t
	}
	return ""
}

func agencySlug(name string) string {
	s := strings.ToLower(strings.TrimSpace(name))
	s = slugCleaner.ReplaceAllString(s, "-")
	s = strings.Trim(s, "-")
	for strings.Contains(s, "--") {
		s = strings.ReplaceAll(s, "--", "-")
	}
	return s
}

func uniqStrings(in []string) []string {
	seen := map[string]bool{}
	out := make([]string, 0, len(in))
	for _, s := range in {
		s = strings.TrimSpace(s)
		key := strings.ToLower(s)
		if s == "" || seen[key] {
			continue
		}
		seen[key] = true
		out = append(out, s)
	}
	return out
}
