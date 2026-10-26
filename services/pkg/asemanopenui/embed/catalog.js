/**
 * Aseman OpenUI catalog renderer — full component collection (parity with the
 * archived generative library names), themed via --md-sys-color-* / --aseman-*.
 * Tree format: { c: "Card", p: { title: "…" }, children: […] }
 * Also accepts component/type/$type and props.
 */
(function (root) {
  "use strict";

  const GAPS = { none: 0, xs: 4, s: 8, m: 12, l: 16, xl: 24, "2xl": 32 };
  const toneClass = (t) => (t ? `ou-tone-${t}` : "");

  function esc(s) {
    return String(s ?? "")
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;");
  }

  function md(src) {
    if (src == null) return "";
    let s = esc(String(src));
    s = s.replace(/```([\s\S]*?)```/g, (_, c) => `<pre><code>${c}</code></pre>`);
    s = s.replace(/`([^`]+)`/g, "<code>$1</code>");
    s = s.replace(/^### (.+)$/gm, "<h3>$1</h3>");
    s = s.replace(/^## (.+)$/gm, "<h2>$1</h2>");
    s = s.replace(/^# (.+)$/gm, "<h1>$1</h1>");
    s = s.replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>");
    s = s.replace(/\*([^*]+)\*/g, "<em>$1</em>");
    s = s.replace(/\[([^\]]+)\]\((https?:[^)\s]+)\)/g, '<a href="$2" target="_blank" rel="noopener">$1</a>');
    s = s.replace(/^(?:- |\* )(.+)(?:\n(?:- |\* ).+)*/gm, (block) => {
      const items = block.split(/\n/).map((l) => `<li>${l.replace(/^(- |\* )/, "")}</li>`).join("");
      return `<ul>${items}</ul>`;
    });
    s = s.replace(/\n\n+/g, "</p><p>");
    if (!/^</.test(s.trim())) s = `<p>${s}</p>`;
    return s;
  }

  function kids(node, ctx) {
    const list = node.children || node.items || [];
    if (!Array.isArray(list)) return "";
    return list.map((n) => renderNode(n, ctx)).join("");
  }

  function propKids(arr, ctx) {
    if (!arr) return "";
    if (!Array.isArray(arr)) return renderNode(arr, ctx);
    return arr.map((n) => renderNode(n, ctx)).join("");
  }

  function el(tag, cls, attrs, html) {
    const a = Object.entries(attrs || {})
      .filter(([, v]) => v != null && v !== false)
      .map(([k, v]) => (v === true ? k : `${k}="${esc(v)}"`))
      .join(" ");
    return `<${tag}${cls ? ` class="${cls}"` : ""}${a ? " " + a : ""}>${html ?? ""}</${tag}>`;
  }

  function chartSVG(kind, labels, values, title) {
    const labs = labels || [];
    const vals = (values || []).map(Number);
    const max = Math.max(1, ...vals);
    const w = 320, h = 140, pad = 24;
    let inner = "";
    if (kind === "BarChart") {
      const bw = (w - pad * 2) / Math.max(1, vals.length);
      inner = vals
        .map((v, i) => {
          const bh = ((v / max) * (h - pad * 2)) | 0;
          const x = pad + i * bw + 2;
          const y = h - pad - bh;
          return `<rect x="${x}" y="${y}" width="${Math.max(4, bw - 4)}" height="${bh}" rx="4" fill="var(--ou-primary)"/>`;
        })
        .join("");
    } else if (kind === "LineChart" || kind === "AreaChart" || kind === "Sparkline") {
      const n = Math.max(1, vals.length - 1);
      const pts = vals.map((v, i) => {
        const x = pad + (i / n) * (w - pad * 2);
        const y = h - pad - (v / max) * (h - pad * 2);
        return `${x},${y}`;
      });
      const line = pts.join(" ");
      if (kind === "AreaChart") {
        const base = `${pad},${h - pad} ${line} ${w - pad},${h - pad}`;
        inner = `<polygon points="${base}" fill="color-mix(in srgb, var(--ou-primary) 25%, transparent)"/><polyline points="${line}" fill="none" stroke="var(--ou-primary)" stroke-width="2"/>`;
      } else {
        inner = `<polyline points="${line}" fill="none" stroke="var(--ou-primary)" stroke-width="2"/>`;
      }
    } else if (kind === "PieChart" || kind === "DonutChart") {
      const sum = vals.reduce((a, b) => a + b, 0) || 1;
      let a0 = -Math.PI / 2;
      const cx = w / 2, cy = h / 2, r = 48, r0 = kind === "DonutChart" ? 28 : 0;
      inner = vals
        .map((v, i) => {
          const a1 = a0 + (v / sum) * Math.PI * 2;
          const x0 = cx + Math.cos(a0) * r, y0 = cy + Math.sin(a0) * r;
          const x1 = cx + Math.cos(a1) * r, y1 = cy + Math.sin(a1) * r;
          const large = a1 - a0 > Math.PI ? 1 : 0;
          const hue = (i * 47) % 360;
          const d = `M ${cx} ${cy} L ${x0} ${y0} A ${r} ${r} 0 ${large} 1 ${x1} ${y1} Z`;
          a0 = a1;
          return `<path d="${d}" fill="hsl(${hue} 55% 55%)" opacity="0.9"/>`;
        })
        .join("");
      if (r0) inner += `<circle cx="${cx}" cy="${cy}" r="${r0}" fill="var(--ou-container)"/>`;
    }
    const legend = labs.length
      ? `<div class="ou-chart-legend">${labs.map((l, i) => `<span><i style="background:hsl(${(i * 47) % 360} 55% 55%)"></i>${esc(l)}${vals[i] != null ? `: ${esc(vals[i])}` : ""}</span>`).join("")}</div>`
      : "";
    return `<div class="ou-chart">${title ? `<div class="ou-chart-title">${esc(title)}</div>` : ""}<svg viewBox="0 0 ${w} ${h}" width="100%" height="${h}">${inner}</svg>${legend}</div>`;
  }

  function normalize(node) {
    if (node == null || node === false) return null;
    if (typeof node === "string" || typeof node === "number" || typeof node === "boolean") {
      return { c: "Text", p: { text: String(node) } };
    }
    if (Array.isArray(node)) return { c: "Stack", children: node };
    if (node.openui) return normalize(node.openui.root || node.openui);
    if (node.type === "openui" || node.$openui) return normalize(node.root || node.ui || node.tree);
    const c = node.c || node.component || node.type || node.$type;
    if (!c || c === "openui") {
      if (node.root) return normalize(node.root);
      if (node.ui) return normalize(node.ui);
      return null;
    }
    const p = { ...(node.p || node.props || {}) };
    // hoist common fields onto props if not nested
    for (const k of Object.keys(node)) {
      if (["c", "component", "type", "$type", "p", "props", "children", "items", "openui", "root", "ui", "tree"].includes(k)) continue;
      if (p[k] === undefined) p[k] = node[k];
    }
    return {
      c: String(c),
      p,
      children: node.children || node.items || p.children || p.items,
    };
  }

  function renderNode(raw, ctx) {
    const node = normalize(raw);
    if (!node) return "";
    const { c, p } = node;
    const R = renderers[c] || renderers._unknown;
    return R(node, p || {}, ctx || {});
  }

  const renderers = {
    _unknown(node, p) {
      return el("div", "ou-unknown", { "data-c": node.c }, `<strong>${esc(node.c)}</strong>${kids(node)}`);
    },
    AppShell(n, p) {
      return el(
        "div",
        "ou-appshell",
        {},
        `${p.title || p.subtitle ? `<header class="ou-appshell-head"><div class="ou-title-lg">${esc(p.title || "")}</div>${p.subtitle ? `<div class="ou-muted">${esc(p.subtitle)}</div>` : ""}</header>` : ""}${kids(n)}`,
      );
    },
    Page(n, p) {
      return el("section", "ou-page", {}, `${p.title ? `<h1 class="ou-title-lg">${esc(p.title)}</h1>` : ""}${p.subtitle ? `<p class="ou-muted">${esc(p.subtitle)}</p>` : ""}${kids(n)}`);
    },
    Section(n, p) {
      return el("section", `ou-section${p.glass ? " ou-glass" : ""}`, {}, `<h2 class="ou-title-md">${esc(p.title || "")}</h2>${p.description ? `<p class="ou-muted">${esc(p.description)}</p>` : ""}${kids(n)}`);
    },
    Container(n, p) {
      return el("div", `ou-container ou-size-${p.size || "md"}${p.center ? " ou-center" : ""}`, {}, kids(n));
    },
    Center(n, p) {
      return el("div", "ou-center-box", { style: p.minHeight ? `min-height:${p.minHeight}px` : null }, kids(n));
    },
    Stack(n, p) {
      const gap = GAPS[p.gap] ?? GAPS.m;
      return el(
        "div",
        `ou-stack ou-dir-${p.direction || "column"}`,
        {
          style: `gap:${gap}px;align-items:${p.align || "stretch"};justify-content:${({ between: "space-between", around: "space-around", evenly: "space-evenly" }[p.justify] || p.justify || "flex-start")};flex-wrap:${p.wrap ? "wrap" : "nowrap"}`,
        },
        kids(n),
      );
    },
    Grid(n, p) {
      const gap = GAPS[p.gap] ?? GAPS.m;
      return el("div", "ou-grid", { style: `grid-template-columns:repeat(${p.columns || 2},minmax(0,1fr));gap:${gap}px` }, kids(n));
    },
    Split(n, p) {
      const ratio = p.ratio || "50";
      const left = propKids(p.left || (n.children && n.children[0]), {});
      const right = propKids(p.right || (n.children && n.children[1]), {});
      return `<div class="ou-split ou-ratio-${ratio}"><div class="ou-split-pane">${left}</div><div class="ou-split-pane">${right}</div></div>`;
    },
    Sidebar(n, p) {
      return `<div class="ou-sidebar-layout"><aside class="ou-sidebar">${propKids(p.side, {})}</aside><main class="ou-sidebar-main">${propKids(p.main, {})}</main></div>`;
    },
    Tabs(n, p) {
      const items = p.items || n.children || [];
      const def = p.defaultValue || (items[0] && (items[0].p || items[0]).value) || "0";
      const triggers = items
        .map((it, i) => {
          const x = normalize(it) || {};
          const pp = x.p || {};
          const val = pp.value || String(i);
          return `<button type="button" class="ou-tab${val === def ? " is-active" : ""}" data-tab="${esc(val)}">${esc(pp.trigger || pp.label || val)}</button>`;
        })
        .join("");
      const panels = items
        .map((it, i) => {
          const x = normalize(it) || {};
          const pp = x.p || {};
          const val = pp.value || String(i);
          const body = propKids(pp.content || x.children, {});
          return `<div class="ou-tab-panel${val === def ? " is-active" : ""}" data-tab-panel="${esc(val)}">${body}</div>`;
        })
        .join("");
      return `<div class="ou-tabs" data-ou-tabs><div class="ou-tablist">${triggers}</div>${panels}</div>`;
    },
    TabItem(n, p) {
      return propKids(p.content || n.children, {});
    },
    Accordion(n, p) {
      const items = p.items || n.children || [];
      return el(
        "div",
        "ou-accordion",
        {},
        items
          .map((it) => {
            const x = normalize(it) || { p: it };
            const pp = x.p || {};
            return `<details class="ou-acc-item"${pp.defaultOpen ? " open" : ""}><summary>${esc(pp.title || "")}</summary><div class="ou-acc-body">${propKids(pp.content || x.children, {})}</div></details>`;
          })
          .join(""),
      );
    },
    AccordionItem(n, p) {
      return `<details class="ou-acc-item"${p.defaultOpen ? " open" : ""}><summary>${esc(p.title || "")}</summary><div class="ou-acc-body">${propKids(p.content || n.children, {})}</div></details>`;
    },
    Divider(n, p) {
      return p.label ? `<div class="ou-divider has-label"><span>${esc(p.label)}</span></div>` : `<hr class="ou-divider"/>`;
    },
    Spacer(n, p) {
      const gap = GAPS[p.size] ?? 12;
      return `<div class="ou-spacer"${p.grow ? ' style="flex:1"' : ` style="height:${gap}px"`}></div>`;
    },
    ScrollArea(n, p) {
      return el("div", "ou-scroll", { style: p.maxHeight ? `max-height:${p.maxHeight}px;overflow:auto` : "overflow:auto" }, kids(n));
    },
    Frame(n, p) {
      return el("div", `ou-frame ou-frame-${p.variant || "plain"} ou-pad-${p.pad || "md"}`, {}, kids(n));
    },
    Overlay(n) {
      return el("div", "ou-overlay", {}, kids(n));
    },
    Sheet(n, p) {
      return el("div", `ou-sheet ou-sheet-${p.side || "center"}`, {}, `${p.title ? `<div class="ou-sheet-title">${esc(p.title)}</div>` : ""}${kids(n)}`);
    },
    AppBar(n, p) {
      return `<header class="ou-appbar${p.dense ? " is-dense" : ""}"><div class="ou-appbar-leading">${propKids(p.leading, {})}</div><div class="ou-appbar-title">${esc(p.title || "")}</div><div class="ou-appbar-actions">${propKids(p.actions, {})}</div></header>`;
    },
    NavBar(n, p) {
      const items = p.items || n.children || [];
      return `<nav class="ou-navbar">${p.brand ? `<strong class="ou-brand">${esc(p.brand)}</strong>` : ""}${items.map((it) => renderNode(it)).join("")}</nav>`;
    },
    NavItem(n, p) {
      return `<button type="button" class="ou-navitem${p.active ? " is-active" : ""}">${p.icon ? `<span class="ou-icon">${esc(p.icon)}</span>` : ""}${esc(p.label || "")}</button>`;
    },
    Drawer(n, p) {
      return `<div class="ou-drawer ou-drawer-${p.variant || "panel"}">${p.title ? `<div class="ou-drawer-title">${esc(p.title)}</div>` : ""}<div class="ou-drawer-body"><aside>${propKids(p.side, {})}</aside><main>${propKids(p.main, {})}</main></div></div>`;
    },
    BottomNav(n, p) {
      const items = p.items || n.children || [];
      return el("nav", "ou-bottomnav", {}, items.map((it) => renderNode(it)).join(""));
    },
    BottomNavItem(n, p) {
      return `<button type="button" class="ou-bottomnav-item${p.active ? " is-active" : ""}">${p.icon ? `<span>${esc(p.icon)}</span>` : ""}<span>${esc(p.label || "")}</span></button>`;
    },
    Masthead(n, p) {
      return `<div class="ou-masthead"><strong>${esc(p.brand || "")}</strong><div class="ou-masthead-actions">${kids(n)}</div></div>`;
    },
    Hero(n, p) {
      return `<section class="ou-hero ou-align-${p.align || "start"}">${p.media ? `<img class="ou-hero-media" src="${esc(p.media)}" alt=""/>` : ""}<div><h1 class="ou-title-xl">${esc(p.headline || "")}</h1>${p.subcopy ? `<p class="ou-muted">${esc(p.subcopy)}</p>` : ""}<div class="ou-hero-actions">${propKids(p.actions, {})}</div></div></section>`;
    },
    Dock(n, p) {
      return `<div class="ou-dock">${p.note ? `<span class="ou-muted">${esc(p.note)}</span>` : ""}${kids(n)}</div>`;
    },
    Breadcrumb(n, p) {
      const items = p.items || n.children || [];
      return el("nav", "ou-breadcrumb", {}, items.map((it, i) => `${i ? '<span class="ou-bc-sep">/</span>' : ""}${renderNode(it)}`).join(""));
    },
    BreadcrumbItem(n, p) {
      return `<span class="ou-bc-item">${esc(p.label || "")}</span>`;
    },
    Segmented(n, p) {
      const items = p.items || n.children || [];
      return el("div", "ou-segmented", {}, items.map((it) => renderNode(it)).join(""));
    },
    Segment(n, p) {
      return `<button type="button" class="ou-segment${p.active ? " is-active" : ""}">${esc(p.label || "")}</button>`;
    },
    CommandBar(n, p) {
      return `<div class="ou-commandbar">${p.label ? `<span class="ou-muted">${esc(p.label)}</span>` : ""}${kids(n)}</div>`;
    },
    StatusBar(n, p) {
      return `<div class="ou-statusbar"><span>${esc(p.text || "")}</span><div>${kids(n)}</div></div>`;
    },
    Pagination(n, p) {
      return `<div class="ou-pagination"><button type="button" class="ou-btn ou-btn-ghost">Prev</button><span>${esc(p.page || 1)} / ${esc(p.pages || 1)}</span><button type="button" class="ou-btn ou-btn-ghost">Next</button></div>`;
    },
    Fab(n, p) {
      return `<button type="button" class="ou-fab">${p.icon ? esc(p.icon) + " " : ""}${esc(p.label || "")}</button>`;
    },
    WizardRail(n, p) {
      const steps = p.steps || n.children || [];
      return el("ol", "ou-wizard", {}, steps.map((it) => renderNode(it)).join(""));
    },
    WizardRailStep(n, p) {
      return `<li class="ou-wizard-step ou-state-${p.state || "todo"}">${esc(p.label || "")}</li>`;
    },
    Footer(n, p) {
      return `<footer class="ou-footer">${p.brand ? `<strong>${esc(p.brand)}</strong>` : ""}${kids(n)}${p.note ? `<div class="ou-muted">${esc(p.note)}</div>` : ""}</footer>`;
    },
    Card(n, p) {
      return `<article class="ou-card ${toneClass(p.tone)}">${p.media ? `<img class="ou-card-media" src="${esc(p.media)}" alt=""/>` : ""}${p.title ? `<h3 class="ou-title-md">${esc(p.title)}</h3>` : ""}${p.description ? `<p class="ou-muted">${esc(p.description)}</p>` : ""}${kids(n)}${p.footer ? `<div class="ou-card-footer">${propKids(p.footer, {})}</div>` : ""}</article>`;
    },
    Tile(n, p) {
      return `<div class="ou-tile ${toneClass(p.tone)}"><div class="ou-muted">${esc(p.label || "")}</div><div class="ou-title-md">${esc(p.value || "")}</div>${p.hint ? `<div class="ou-muted">${esc(p.hint)}</div>` : ""}</div>`;
    },
    Quote(n, p) {
      return `<blockquote class="ou-quote"><p>${esc(p.text || "")}</p>${p.by ? `<cite>${esc(p.by)}</cite>` : ""}</blockquote>`;
    },
    Figure(n, p) {
      return `<figure class="ou-figure"><img src="${esc(p.src || "")}" alt="${esc(p.alt || "")}"/>${p.caption ? `<figcaption>${esc(p.caption)}</figcaption>` : ""}</figure>`;
    },
    Feature(n, p) {
      return `<div class="ou-feature">${p.icon ? `<div class="ou-feature-icon">${esc(p.icon)}</div>` : ""}<h3>${esc(p.title || "")}</h3>${p.body ? `<p class="ou-muted">${esc(p.body)}</p>` : ""}</div>`;
    },
    FeatureGrid(n, p) {
      const items = p.items || n.children || [];
      return el("div", "ou-feature-grid", { style: `grid-template-columns:repeat(${p.columns || 3},minmax(0,1fr))` }, items.map((it) => renderNode(typeof it === "object" && !it.c ? { c: "Feature", p: it } : it)).join(""));
    },
    ProsCons(n, p) {
      const pros = (p.pros || []).map((x) => `<li>${esc(x)}</li>`).join("");
      const cons = (p.cons || []).map((x) => `<li>${esc(x)}</li>`).join("");
      return `<div class="ou-proscons"><div><h4>Pros</h4><ul>${pros}</ul></div><div><h4>Cons</h4><ul>${cons}</ul></div></div>`;
    },
    LogoStrip(n, p) {
      return `<div class="ou-logostrip">${p.label ? `<span class="ou-muted">${esc(p.label)}</span>` : ""}${(p.items || []).map((x) => `<span class="ou-logo">${esc(x)}</span>`).join("")}</div>`;
    },
    Title(n, p) {
      return `<div class="ou-title-${p.size || "lg"}">${esc(p.text || "")}</div>`;
    },
    Text(n, p) {
      return `<p class="ou-text ou-tone-text-${p.tone || "primary"} ou-size-${p.size || "md"}${p.mono ? " ou-mono" : ""}">${esc(p.text || "")}</p>`;
    },
    Markdown(n, p) {
      return `<div class="ou-md">${md(p.content || p.text || "")}</div>`;
    },
    Callout(n, p) {
      return `<aside class="ou-callout ${toneClass(p.tone)}"><strong>${esc(p.title || "")}</strong>${p.body ? `<div>${esc(p.body)}</div>` : ""}</aside>`;
    },
    Badge(n, p) {
      return `<span class="ou-badge-pill ${toneClass(p.tone)}">${esc(p.label || "")}</span>`;
    },
    Avatar(n, p) {
      const name = p.name || "?";
      const ini = name.trim().slice(0, 1).toUpperCase();
      return p.src
        ? `<img class="ou-avatar ou-avatar-${p.size || "md"}" src="${esc(p.src)}" alt="${esc(name)}"/>`
        : `<span class="ou-avatar ou-avatar-${p.size || "md"}" title="${esc(name)}">${esc(ini)}</span>`;
    },
    AvatarGroup(n, p) {
      const names = p.names || [];
      const max = p.max || names.length;
      return el("div", "ou-avatar-group", {}, names.slice(0, max).map((name) => renderNode({ c: "Avatar", p: { name, size: "sm" } })).join("") + (names.length > max ? `<span class="ou-avatar ou-avatar-sm">+${names.length - max}</span>` : ""));
    },
    Image(n, p) {
      return `<img class="ou-image" src="${esc(p.src || "")}" alt="${esc(p.alt || "")}"/>`;
    },
    CodeBlock(n, p) {
      return `<pre class="ou-code">${p.language ? `<span class="ou-code-lang">${esc(p.language)}</span>` : ""}<code>${esc(p.code || "")}</code></pre>`;
    },
    JsonBlock(n, p) {
      let v = p.value;
      try {
        v = typeof v === "string" ? v : JSON.stringify(v, null, 2);
      } catch {
        v = String(v);
      }
      return `<div class="ou-json">${p.title ? `<div class="ou-muted">${esc(p.title)}</div>` : ""}<pre><code>${esc(v)}</code></pre></div>`;
    },
    EmptyState(n, p) {
      return `<div class="ou-empty-state"><strong>${esc(p.title || "")}</strong>${p.description ? `<p class="ou-muted">${esc(p.description)}</p>` : ""}</div>`;
    },
    Skeleton(n, p) {
      return `<div class="ou-skeleton" style="width:${esc(p.width || "100%")};height:${esc(p.height || "16px")}"></div>`;
    },
    Stat(n, p) {
      return `<div class="ou-stat${p.glass ? " ou-glass" : ""}"><div class="ou-muted">${esc(p.label || "")}</div><div class="ou-title-md">${esc(p.value || "")}</div>${p.delta != null ? `<div class="ou-delta ou-delta-${p.deltaTone || "neutral"}">${esc(p.delta)}</div>` : ""}</div>`;
    },
    StatRow(n) {
      return el("div", "ou-statrow", {}, kids(n));
    },
    KPIStrip(n) {
      return el("div", "ou-kpistrip", {}, kids(n));
    },
    Progress(n, p) {
      const v = Math.max(0, Math.min(100, Number(p.value) || 0));
      return `<div class="ou-progress">${p.label ? `<div class="ou-muted">${esc(p.label)}</div>` : ""}<div class="ou-progress-track"><div class="ou-progress-fill" style="width:${v}%"></div></div></div>`;
    },
    Meter(n, p) {
      const min = Number(p.min) || 0, max = Number(p.max) || 100, value = Number(p.value) || 0;
      const pct = ((value - min) / Math.max(1, max - min)) * 100;
      return `<div class="ou-meter">${p.label ? `<div class="ou-muted">${esc(p.label)} (${esc(value)})</div>` : ""}<div class="ou-progress-track"><div class="ou-progress-fill" style="width:${pct}%"></div></div></div>`;
    },
    Sparkline(n, p) {
      return chartSVG("Sparkline", [], p.values || [], "");
    },
    Table(n, p) {
      const cols = p.columns || n.children || [];
      const normalized = cols.map((c) => normalize(c)).filter(Boolean);
      const headers = normalized.map((c) => (c.p && c.p.header) || "");
      const rows = [];
      const len = Math.max(0, ...normalized.map((c) => ((c.p && c.p.data) || []).length));
      for (let r = 0; r < len; r++) {
        rows.push(normalized.map((c) => ((c.p && c.p.data) || [])[r]));
      }
      return `<div class="ou-table-wrap"><table class="ou-table"><thead><tr>${headers.map((h) => `<th>${esc(h)}</th>`).join("")}</tr></thead><tbody>${rows.map((row) => `<tr>${row.map((cell) => `<td>${esc(cell)}</td>`).join("")}</tr>`).join("")}</tbody></table></div>`;
    },
    Col() {
      return "";
    },
    DataList(n, p) {
      const items = p.items || [];
      return el("dl", "ou-datalist", {}, items.map((it) => `<div><dt>${esc(it.label)}</dt><dd>${esc(it.value)}</dd></div>`).join(""));
    },
    KeyValue(n, p) {
      return `<div class="ou-kv"><span class="ou-muted">${esc(p.keyLabel || p.key || "")}</span><span>${esc(p.value || "")}</span></div>`;
    },
    List(n, p) {
      const items = p.items || n.children || [];
      return el("ul", "ou-list", {}, items.map((it) => renderNode(typeof it === "object" && !(it.c || it.component) ? { c: "ListItem", p: it } : it)).join(""));
    },
    ListItem(n, p) {
      return `<li class="ou-listitem"><div>${esc(p.label || "")}</div>${p.subtitle ? `<div class="ou-muted">${esc(p.subtitle)}</div>` : ""}</li>`;
    },
    Chip(n, p) {
      return `<span class="ou-chip${p.active ? " is-active" : ""}">${esc(p.label || "")}</span>`;
    },
    TagGroup(n) {
      return el("div", "ou-taggroup", {}, kids(n));
    },
    Timeline(n, p) {
      const items = p.items || n.children || [];
      return el("ol", "ou-timeline", {}, items.map((it) => renderNode(typeof it === "object" && !(it.c || it.component) ? { c: "TimelineItem", p: it } : it)).join(""));
    },
    TimelineItem(n, p) {
      return `<li><div class="ou-title-sm">${esc(p.title || "")}</div>${p.time ? `<div class="ou-muted">${esc(p.time)}</div>` : ""}${p.body ? `<div>${esc(p.body)}</div>` : ""}</li>`;
    },
    Alert(n, p) {
      return `<div class="ou-alert ${toneClass(p.tone)}"><strong>${esc(p.title || "")}</strong>${p.body ? `<div>${esc(p.body)}</div>` : ""}</div>`;
    },
    Toast(n, p) {
      return `<div class="ou-toast ${toneClass(p.tone)}">${esc(p.message || "")}</div>`;
    },
    Banner(n, p) {
      return `<div class="ou-banner">${esc(p.text || "")}</div>`;
    },
    Spinner(n, p) {
      return `<div class="ou-spinner">${p.label ? esc(p.label) : "Loading…"}</div>`;
    },
    StatusDot(n, p) {
      return `<span class="ou-statusdot ou-status-${p.status || "idle"}">${p.label ? esc(p.label) : ""}</span>`;
    },
    Result(n, p) {
      return `<div class="ou-result ${toneClass(p.tone)}"><div class="ou-title-md">${esc(p.title || "")}</div>${p.description ? `<p class="ou-muted">${esc(p.description)}</p>` : ""}</div>`;
    },
    Input(n, p) {
      return `<label class="ou-field"><span class="ou-muted">${esc(p.name || "")}</span><input class="ou-input" name="${esc(p.name || "")}" type="${esc(p.type || "text")}" value="${esc(p.value || "")}" placeholder="${esc(p.placeholder || "")}"/></label>`;
    },
    TextArea(n, p) {
      return `<label class="ou-field"><span class="ou-muted">${esc(p.name || "")}</span><textarea class="ou-input" name="${esc(p.name || "")}" placeholder="${esc(p.placeholder || "")}">${esc(p.value || "")}</textarea></label>`;
    },
    Select(n, p) {
      const items = p.items || [];
      return `<label class="ou-field"><span class="ou-muted">${esc(p.name || "")}</span><select class="ou-input" name="${esc(p.name || "")}">${p.placeholder ? `<option value="">${esc(p.placeholder)}</option>` : ""}${items.map((it) => {
        const x = it.p || it;
        return `<option value="${esc(x.value)}"${String(x.value) === String(p.value) ? " selected" : ""}>${esc(x.label || x.value)}</option>`;
      }).join("")}</select></label>`;
    },
    SelectItem() {
      return "";
    },
    Checkbox(n, p) {
      return `<label class="ou-check"><input type="checkbox" name="${esc(p.name || "")}"${p.value ? " checked" : ""}/> ${esc(p.label || "")}</label>`;
    },
    Switch(n, p) {
      return `<label class="ou-switch"><input type="checkbox" role="switch" name="${esc(p.name || "")}"${p.value ? " checked" : ""}/> ${esc(p.label || "")}</label>`;
    },
    Slider(n, p) {
      return `<label class="ou-field"><span class="ou-muted">${esc(p.name || "")}</span><input type="range" name="${esc(p.name || "")}" min="${esc(p.min ?? 0)}" max="${esc(p.max ?? 100)}" step="${esc(p.step ?? 1)}" value="${esc(p.value ?? 0)}"/></label>`;
    },
    Radio(n, p) {
      return `<label class="ou-check"><input type="radio" value="${esc(p.value || "")}"/> ${esc(p.label || "")}</label>`;
    },
    RadioGroup(n, p) {
      const options = p.options || [];
      return `<fieldset class="ou-radiogroup"><legend class="ou-muted">${esc(p.name || "")}</legend>${options.map((o) => {
        const x = o.p || o;
        return `<label class="ou-check"><input type="radio" name="${esc(p.name || "")}" value="${esc(x.value)}"${String(x.value) === String(p.value) ? " checked" : ""}/> ${esc(x.label || x.value)}</label>`;
      }).join("")}</fieldset>`;
    },
    DateField(n, p) {
      return `<label class="ou-field"><span class="ou-muted">${esc(p.name || "")}</span><input class="ou-input" type="date" name="${esc(p.name || "")}" value="${esc(p.value || "")}"/></label>`;
    },
    SearchField(n, p) {
      return `<label class="ou-field ou-search"><input class="ou-input" type="search" name="${esc(p.name || "")}" value="${esc(p.value || "")}" placeholder="${esc(p.placeholder || "Search")}"/></label>`;
    },
    FormControl(n, p) {
      return `<div class="ou-formcontrol"><label class="ou-muted">${esc(p.label || "")}</label>${propKids(p.field, {})}${p.hint ? `<div class="ou-muted">${esc(p.hint)}</div>` : ""}</div>`;
    },
    FieldRow(n) {
      return el("div", "ou-fieldrow", {}, kids(n));
    },
    Form(n, p) {
      return `<form class="ou-form" data-name="${esc(p.name || "")}">${propKids(p.fields || n.children, {})}${propKids(p.buttons, {})}</form>`;
    },
    Button(n, p) {
      return `<button type="button" class="ou-btn ou-btn-${p.variant || "primary"}">${esc(p.label || "")}</button>`;
    },
    ButtonGroup(n) {
      return el("div", "ou-btngroup", {}, kids(n));
    },
    IconButton(n, p) {
      return `<button type="button" class="ou-iconbtn" aria-label="${esc(p.label || p.icon || "")}">${esc(p.icon || "•")}</button>`;
    },
    LinkButton(n, p) {
      return `<button type="button" class="ou-btn ou-btn-ghost">${esc(p.label || "")}</button>`;
    },
    Menu(n, p) {
      const items = p.items || n.children || [];
      return el("div", "ou-menu", {}, items.map((it) => renderNode(it)).join(""));
    },
    MenuItem(n, p) {
      return `<button type="button" class="ou-menuitem">${esc(p.label || "")}</button>`;
    },
    Toolbar(n) {
      return el("div", "ou-toolbar", {}, kids(n));
    },
    BarChart(n, p) {
      return chartSVG("BarChart", p.labels, p.values, p.title);
    },
    LineChart(n, p) {
      return chartSVG("LineChart", p.labels, p.values, p.title);
    },
    AreaChart(n, p) {
      return chartSVG("AreaChart", p.labels, p.values, p.title);
    },
    PieChart(n, p) {
      return chartSVG("PieChart", p.labels, p.values, p.title);
    },
    DonutChart(n, p) {
      return chartSVG("DonutChart", p.labels, p.values, p.title);
    },
    MessageBubble(n, p) {
      return `<div class="ou-bubble ou-role-${p.role || "assistant"}">${esc(p.text || "")}</div>`;
    },
    FollowUpChips(n, p) {
      return el("div", "ou-followups", {}, (p.suggestions || []).map((s) => `<button type="button" class="ou-chip">${esc(s)}</button>`).join(""));
    },
    Step(n, p) {
      return `<div class="ou-step ou-step-${p.status || "pending"}"><strong>${esc(p.title || "")}</strong>${p.description ? `<div class="ou-muted">${esc(p.description)}</div>` : ""}</div>`;
    },
    StepList(n, p) {
      const steps = p.steps || n.children || [];
      return el("div", "ou-steplist", {}, steps.map((it) => renderNode(typeof it === "object" && !(it.c || it.component) ? { c: "Step", p: it } : it)).join(""));
    },
    ChatCard(n, p) {
      return `<div class="ou-chatcard">${p.title ? `<div class="ou-title-sm">${esc(p.title)}</div>` : ""}${kids(n)}</div>`;
    },
    Rating(n, p) {
      const v = Math.round(Number(p.value) || 0);
      return `<span class="ou-rating">${"★".repeat(Math.max(0, Math.min(5, v)))}${"☆".repeat(Math.max(0, 5 - v))}${p.count != null ? ` <span class="ou-muted">(${esc(p.count)})</span>` : ""}</span>`;
    },
    Price(n, p) {
      return `<div class="ou-price"><span class="ou-title-md">${esc(p.amount || "")}</span>${p.compareAt ? `<s class="ou-muted">${esc(p.compareAt)}</s>` : ""}${p.period ? `<span class="ou-muted">/${esc(p.period)}</span>` : ""}</div>`;
    },
    MediaCard(n, p) {
      return `<article class="ou-mediacard">${p.src ? `<img src="${esc(p.src)}" alt=""/>` : ""}<div><h3>${esc(p.title || "")}</h3>${p.meta ? `<div class="ou-muted">${esc(p.meta)}</div>` : ""}</div></article>`;
    },
    ProductCard(n, p) {
      return `<article class="ou-productcard">${p.image ? `<img src="${esc(p.image)}" alt=""/>` : ""}${p.badge ? `<span class="ou-badge-pill ou-tone-accent">${esc(p.badge)}</span>` : ""}<h3>${esc(p.title || "")}</h3><div class="ou-title-sm">${esc(p.price || "")}</div>${p.rating != null ? renderNode({ c: "Rating", p: { value: p.rating } }) : ""}</article>`;
    },
    Gallery(n, p) {
      return el("div", "ou-gallery", { style: `grid-template-columns:repeat(${p.columns || 3},minmax(0,1fr))` }, (p.images || []).map((src) => `<img src="${esc(src)}" alt=""/>`).join(""));
    },
    Carousel(n, p) {
      const slides = p.slides || n.children || [];
      return el("div", "ou-carousel", {}, slides.map((s) => `<div class="ou-carousel-slide">${typeof s === "string" ? `<img src="${esc(s)}" alt=""/>` : renderNode(s)}</div>`).join(""));
    },
    Feed(n, p) {
      const items = p.items || n.children || [];
      return el("div", "ou-feed", {}, items.map((it) => renderNode(typeof it === "object" && !(it.c || it.component) ? { c: "FeedItem", p: it } : it)).join(""));
    },
    FeedItem(n, p) {
      return `<article class="ou-feeditem"><strong>${esc(p.author || "")}</strong>${p.time ? `<span class="ou-muted"> · ${esc(p.time)}</span>` : ""}<div>${esc(p.body || "")}</div></article>`;
    },
    Comment(n, p) {
      return `<div class="ou-comment"><strong>${esc(p.author || "")}</strong>${p.time ? `<span class="ou-muted"> ${esc(p.time)}</span>` : ""}<div>${esc(p.body || "")}</div></div>`;
    },
    NotificationItem(n, p) {
      return `<div class="ou-notification${p.unread ? " is-unread" : ""}"><strong>${esc(p.title || "")}</strong>${p.body ? `<div class="ou-muted">${esc(p.body)}</div>` : ""}</div>`;
    },
    FileRow(n, p) {
      return `<div class="ou-filerow"><span>${esc(p.name || "")}</span>${p.meta ? `<span class="ou-muted">${esc(p.meta)}</span>` : ""}</div>`;
    },
    CheckItem(n, p) {
      return `<label class="ou-check"><input type="checkbox"${p.done ? " checked" : ""}/> ${esc(p.label || "")}</label>`;
    },
    Checklist(n, p) {
      const items = p.items || n.children || [];
      return el("div", "ou-checklist", {}, items.map((it) => renderNode(typeof it === "object" && !(it.c || it.component) ? { c: "CheckItem", p: it } : it)).join(""));
    },
    Kanban(n, p) {
      const columns = p.columns || n.children || [];
      return el("div", "ou-kanban", {}, columns.map((it) => renderNode(typeof it === "object" && !(it.c || it.component) ? { c: "KanbanColumn", p: it, children: it.children } : it)).join(""));
    },
    KanbanColumn(n, p) {
      return `<div class="ou-kanban-col"><div class="ou-title-sm">${esc(p.title || "")}</div><div class="ou-kanban-cards">${kids(n)}</div></div>`;
    },
    KanbanCard(n, p) {
      return `<div class="ou-kanban-card"><strong>${esc(p.title || "")}</strong>${p.meta ? `<div class="ou-muted">${esc(p.meta)}</div>` : ""}</div>`;
    },
    Tree(n, p) {
      const items = p.items || n.children || [];
      return el("ul", "ou-tree", {}, items.map((it) => renderNode(typeof it === "object" && !(it.c || it.component) ? { c: "TreeItem", p: it, children: it.children } : it)).join(""));
    },
    TreeItem(n, p) {
      const child = kids(n);
      return `<li><span>${esc(p.label || "")}</span>${child ? `<ul>${child}</ul>` : ""}</li>`;
    },
    CalendarGrid(n, p) {
      const days = p.days || [];
      const hi = new Set(p.highlights || []);
      return `<div class="ou-cal">${p.label ? `<div class="ou-title-sm">${esc(p.label)}</div>` : ""}<div class="ou-cal-grid">${days.map((d, i) => `<div class="ou-cal-day${hi.has(i) || hi.has(d) ? " is-hi" : ""}">${esc(d)}</div>`).join("")}</div></div>`;
    },
    MapPlaceholder(n, p) {
      return `<div class="ou-map"><div class="ou-title-sm">📍 ${esc(p.pin || "Map")}</div>${p.subtitle ? `<div class="ou-muted">${esc(p.subtitle)}</div>` : ""}</div>`;
    },
    Compare(n, p) {
      const headers = p.headers || [];
      const rows = p.rows || [];
      return `<div class="ou-table-wrap"><table class="ou-table"><thead><tr><th></th>${headers.map((h) => `<th>${esc(h)}</th>`).join("")}</tr></thead><tbody>${rows.map((r) => {
        const x = r.p || r;
        return `<tr><th>${esc(x.feature || "")}</th>${(x.values || []).map((v) => `<td>${esc(v)}</td>`).join("")}</tr>`;
      }).join("")}</tbody></table></div>`;
    },
    CompareRow() {
      return "";
    },
    ToolHeader(n, p) {
      return `<div class="ou-toolheader">${p.avatar ? renderNode({ c: "Avatar", p: { name: p.name, src: p.avatar } }) : ""}<div><div class="ou-title-md">${esc(p.name || "")}</div>${p.subtitle ? `<div class="ou-muted">${esc(p.subtitle)}</div>` : ""}</div></div>`;
    },
    MicrotoolResult(n, p) {
      return `<div class="ou-microresult">${p.label ? `<div class="ou-muted">${esc(p.label)}</div>` : ""}<pre><code>${esc(p.data || "")}</code></pre></div>`;
    },
    BindingHint(n, p) {
      return `<div class="ou-binding"><code>${esc(p.name || "")}</code>${p.hint ? `<span class="ou-muted">${esc(p.hint)}</span>` : ""}</div>`;
    },
  };

  function enhance(root) {
    if (!root || !root.querySelectorAll) return;
    root.querySelectorAll("[data-ou-tabs]").forEach((tabs) => {
      tabs.addEventListener("click", (e) => {
        const btn = e.target.closest("[data-tab]");
        if (!btn || !tabs.contains(btn)) return;
        const id = btn.getAttribute("data-tab");
        tabs.querySelectorAll("[data-tab]").forEach((b) => b.classList.toggle("is-active", b === btn));
        tabs.querySelectorAll("[data-tab-panel]").forEach((p) => p.classList.toggle("is-active", p.getAttribute("data-tab-panel") === id));
      });
    });
  }

  function render(tree) {
    return renderNode(tree, {});
  }

  function mount(el, tree) {
    if (typeof el === "string") el = document.querySelector(el);
    if (!el) throw new Error("mount target not found");
    el.innerHTML = render(tree);
    enhance(el);
    return el;
  }

  function tryParseOpenUI(text) {
    if (text == null) return null;
    if (typeof text === "object") {
      if (text.openui || text.type === "openui" || text.c || text.component || text.root) return text;
      return null;
    }
    const s = String(text).trim();
    const fence = s.match(/```(?:openui|json)?\s*([\s\S]*?)```/i);
    const raw = fence ? fence[1].trim() : s;
    if (!(raw.startsWith("{") || raw.startsWith("["))) return null;
    try {
      const j = JSON.parse(raw);
      if (j && (j.openui || j.type === "openui" || j.c || j.component || j.root || Array.isArray(j))) return j;
    } catch {
      return null;
    }
    return null;
  }

  function componentNames() {
    return Object.keys(renderers).filter((k) => k !== "_unknown").sort();
  }

  const api = { render, mount, enhance, tryParseOpenUI, componentNames, normalize, version: "1.1.0" };
  root.AsemanOpenUICatalog = api;
  if (typeof module === "object" && module.exports) module.exports = api;
})(typeof globalThis !== "undefined" ? globalThis : this);
