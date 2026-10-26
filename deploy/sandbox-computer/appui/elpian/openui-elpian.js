/*
 * Aseman OpenUI for Elpian: the OpenUI component collection (the same 137
 * components and tree format as the web kit, appui/openui/catalog.js)
 * rendered as Elpian and UI-kit nodes, and agent-backed islands that live
 * inside an Elpian app. Needs aseman-elpian.js (Aseman, App) first.
 *
 *   OpenUI.render(tree, ctx)               an OpenUI tree -> an Elpian node
 *   OpenUI.fromReply(text, ctx)            an agent's reply (OpenUI JSON, fenced
 *                                          ```openui, or markdown) -> a node
 *   OpenUI.markdown(text)                  markdown -> Elpian nodes
 *   OpenUI.panel(app, key, {agent, prompt, vars, title, auto})
 *   OpenUI.action(app, key, {agent, prompt, label, vars, title})
 *   OpenUI.query(app, key, {tool, microtool, args, title, auto})
 *   OpenUI.components()                    the names it renders
 *
 * Tree format: {c: "Card", p: {...}, children: [...]} (also component/type,
 * props, items; {openui: tree}; a bare string is Text).
 */
(function (root) {
  "use strict";

  var GAPS = { none: 0, xs: 4, s: 8, m: 12, l: 16, xl: 24, "2xl": 32 };

  function str(v) {
    return v === null || v === undefined ? "" : String(v);
  }

  function gap(v, dflt) {
    if (typeof v === "number") return String(v);
    var g = GAPS[v];
    return String(g === undefined ? (dflt === undefined ? 12 : dflt) : g);
  }

  function env() {
    try {
      return (root.Aseman && root.Aseman.env()) || {};
    } catch (e) {
      return {};
    }
  }

  function color(role, fallback) {
    var c = ((env().theme || {}).colors || {})[role];
    return c || fallback;
  }

  // tone -> UI kit status (Callout severity, Tag status)
  function status(tone) {
    return { success: "good", accent: "info", info: "info", warning: "warning", danger: "critical", up: "good", down: "critical" }[tone] || "";
  }

  function severity(tone) {
    return { success: "good", warning: "warning", danger: "critical" }[tone] || "info";
  }

  function text(t, style, variant) {
    var props = { text: str(t), style: style || {} };
    if (variant) props.variant = variant;
    return { type: "Text", props: props };
  }

  function muted(t) {
    return { type: "Text", props: { text: str(t), variant: "bodyMedium", color: "muted" } };
  }

  // M3 type roles: titles take the emphasized weight of M3 Expressive.
  function title(t, size) {
    var role = { xl: "headlineMediumEmphasized", lg: "titleLargeEmphasized", md: "titleMediumEmphasized", sm: "titleSmallEmphasized" }[size || "md"] || "titleMediumEmphasized";
    return text(t, {}, role);
  }

  // A Material icon name (snake_case), as opposed to an emoji or a label.
  function isIconName(v) {
    return typeof v === "string" && /^[a-z][a-z0-9_]*$/.test(v);
  }

  // A leading glyph: a Material icon, or the emoji/text as given.
  function glyph(v, size) {
    if (!v) return null;
    if (isIconName(v)) return { type: "Icon", props: { icon: v, size: size || 22, style: { color: color("primary", "#6750A4") } } };
    return text(v, { fontSize: String(size || 22) });
  }

  // Elpian lays rows and columns out from CSS-like style: gap,
  // justifyContent, alignItems.
  function column(children, g, extra) {
    var style = { gap: gap(g), alignItems: "stretch" };
    for (var k in extra || {}) style[k] = extra[k];
    return { type: "Column", props: { style: style }, children: compact(children) };
  }

  function row(children, g, extra) {
    var style = { gap: gap(g, 8), alignItems: "center" };
    for (var k in extra || {}) style[k] = extra[k];
    return { type: "Row", props: { style: style }, children: compact(children) };
  }

  function wrap(children, g) {
    return { type: "Wrap", props: { style: { gap: gap(g, 8) } }, children: compact(children) };
  }

  // A Material 3 card: 16 padding, 10 between parts.
  function card(children, extra, variant) {
    var style = { padding: "16", gap: "10" };
    for (var k in extra || {}) style[k] = extra[k];
    var props = { style: style };
    if (variant) props.variant = variant;
    return { type: "Card", props: props, children: compact(children) };
  }

  function compact(list) {
    var out = [];
    for (var i = 0; i < (list || []).length; i++) {
      var n = list[i];
      if (n === null || n === undefined || n === false || n === "") continue;
      if (Array.isArray(n)) out = out.concat(compact(n));
      else out.push(n);
    }
    return out;
  }

  // ── tree shape (same rules as the web catalog's normalize) ───────────────

  var RESERVED = { c: 1, component: 1, type: 1, $type: 1, p: 1, props: 1, children: 1, items: 1, openui: 1, root: 1, ui: 1, tree: 1 };

  function normalize(node) {
    if (node === null || node === undefined || node === false) return null;
    if (typeof node === "string" || typeof node === "number" || typeof node === "boolean") {
      return { c: "Text", p: { text: String(node) } };
    }
    if (Array.isArray(node)) return { c: "Stack", p: {}, children: node };
    if (node.openui) return normalize(node.openui.root || node.openui);
    if (node.type === "openui" || node.$openui) return normalize(node.root || node.ui || node.tree);
    var c = node.c || node.component || node.type || node.$type;
    if (!c || c === "openui") {
      if (node.root) return normalize(node.root);
      if (node.ui) return normalize(node.ui);
      return null;
    }
    var p = {};
    var src = node.p || node.props || {};
    for (var k in src) p[k] = src[k];
    for (var key in node) {
      if (RESERVED[key]) continue;
      if (p[key] === undefined) p[key] = node[key];
    }
    return { c: String(c), p: p, children: node.children || node.items || p.children || p.items };
  }

  function kids(n, ctx) {
    var list = n.children;
    if (!Array.isArray(list)) return [];
    var out = [];
    for (var i = 0; i < list.length; i++) out.push(renderAt(list[i], ctx, i));
    return compact(out);
  }

  function propKids(arr, ctx, tag) {
    if (!arr) return [];
    if (!Array.isArray(arr)) return compact([renderAt(arr, ctx, tag || "x")]);
    var out = [];
    for (var i = 0; i < arr.length; i++) out.push(renderAt(arr[i], ctx, (tag || "x") + i));
    return compact(out);
  }

  // items given as plain objects stand for one component.
  function itemsAs(list, comp, ctx) {
    var out = [];
    for (var i = 0; i < (list || []).length; i++) {
      var it = list[i];
      var isNode = it && typeof it === "object" && (it.c || it.component);
      out.push(renderAt(isNode || typeof it !== "object" ? it : { c: comp, p: it, children: it.children }, ctx, i));
    }
    return compact(out);
  }

  // ── interaction: values, local state, actions ────────────────────────────

  function child(ctx, i) {
    var out = {};
    for (var k in ctx) out[k] = ctx[k];
    out.path = (ctx.path || "ou") + "_" + i;
    return out;
  }

  function local(ctx) {
    var store = ctx.store || (ctx.store = {});
    var id = ctx.path || "ou";
    return store[id] || (store[id] = {});
  }

  function rerender(ctx) {
    if (ctx.app) ctx.app.render();
  }

  function handler(ctx, name, fn) {
    if (!ctx.app) return undefined;
    return ctx.app.handler((ctx.key || "ou") + "_" + (ctx.path || "") + "_" + name, fn);
  }

  function valueOf(ctx, name, dflt) {
    var values = ctx.values || {};
    return name && values[name] !== undefined ? values[name] : dflt;
  }

  function setValue(ctx, name, value, render) {
    if (!name) return;
    (ctx.values || (ctx.values = {}))[name] = value;
    if (render) rerender(ctx);
  }

  // A button's action: run by the island (ask / call / submit / set), else
  // reported to the program through ctx.onAction.
  function act(ctx, action, label) {
    if (ctx.onAction) {
      ctx.onAction(action === undefined ? { type: "ask", prompt: label } : action, ctx.values || {}, label);
    }
  }

  var VARIANTS = { primary: "filled", secondary: "tonal", ghost: "text", danger: "danger", outline: "outlined" };

  // A Material 3 Expressive button (filled / tonal / outlined / text /
  // danger), with a Material icon when one is named.
  function button(ctx, label, action, variant, icon) {
    var name = handler(ctx, "tap", function () { act(ctx, action, label); });
    var props = { text: str(label), variant: VARIANTS[variant] || variant || "filled" };
    if (isIconName(icon)) props.icon = icon;
    else if (icon) props.text = icon + " " + props.text;
    var node = { type: "Button", props: props };
    if (name) node.events = { tap: name };
    return node;
  }

  function iconButton(ctx, icon, action, label, variant) {
    if (!isIconName(icon)) return button(ctx, icon || label || "•", action, "ghost");
    var name = handler(ctx, "tap", function () { act(ctx, action, label || icon); });
    var node = { type: "IconButton", props: { icon: icon, variant: variant || "standard", tooltip: label || undefined } };
    if (name) node.events = { tap: name };
    return node;
  }

  function field(ctx, p, opts) {
    var name = str(p.name);
    var value = valueOf(ctx, name, p.value === undefined ? "" : p.value);
    var props = { hint: p.placeholder || opts.hint || undefined, label: opts.bare ? undefined : (p.label || name || undefined), value: str(value) };
    if (isIconName(p.icon)) props.icon = p.icon;
    if (opts.multiline) props.multiline = true;
    if (p.type === "password") props.obscureText = true;
    if (p.type === "number") props.keyboardType = "number";
    if (p.type === "email") props.keyboardType = "email";
    if (opts.date) props.keyboardType = "date";
    var input = handler(ctx, "input", function (e) { setValue(ctx, name, e && e.value !== undefined ? e.value : (e && e.data), false); });
    var node = { type: opts.search ? "SearchBar" : "TextField", key: ctx.key + "_" + ctx.path, props: props };
    if (input) node.events = { input: input };
    return node;
  }

  function toggle(ctx, p, kind) {
    var name = str(p.name);
    var on = !!valueOf(ctx, name, !!p.value);
    var change = handler(ctx, "change", function (e) { setValue(ctx, name, !!(e && (e.value !== undefined ? e.value : e.data)), true); });
    var node = { type: kind, key: ctx.key + "_" + ctx.path, props: { value: on, label: str(p.label || name) } };
    if (change) node.events = { change: change };
    return node;
  }

  function choice(ctx, name, options, current) {
    var chips = [];
    for (var i = 0; i < options.length; i++) {
      var o = options[i] && (options[i].p || options[i]);
      if (!o) continue;
      var val = o.value !== undefined ? o.value : o.label;
      var selected = String(val) === String(current);
      (function (v, idx) {
        var pick = handler(child(ctx, "o" + idx), "pick", function () { setValue(ctx, name, v, true); });
        var chip = { type: "Chip", props: { label: str(o.label || v), selected: selected } };
        if (isIconName(o.icon)) chip.props.icon = o.icon;
        if (pick) chip.events = { change: pick };
        chips.push(chip);
      })(val, i);
    }
    return wrap(chips, "s");
  }

  // A connected button group for a few short options, chips otherwise.
  function segmented(ctx, options, current, onPick) {
    if (options.length < 2 || options.length > 5) return null;
    for (var i = 0; i < options.length; i++) if (str(options[i].label).length > 14) return null;
    var pick = handler(ctx, "segment", function (e) { onPick(e && e.value !== undefined ? e.value : (e && e.data)); });
    var node = { type: "SegmentedButton", key: ctx.key + "_" + ctx.path + "_seg", props: {
      segments: options.map(function (o) { var seg = { value: str(o.value), label: str(o.label) }; if (isIconName(o.icon)) seg.icon = o.icon; return seg; }),
      selected: str(current),
    } };
    if (pick) node.events = { change: pick };
    return node;
  }

  // ── charts and tables through the UI kit ─────────────────────────────────

  function chart(kind, p) {
    var labels = p.labels || [];
    var values = p.values || [];
    var data = [];
    for (var i = 0; i < Math.max(labels.length, values.length); i++) {
      data.push({ label: str(labels[i] === undefined ? i + 1 : labels[i]), value: Number(values[i]) || 0 });
    }
    var type = { BarChart: "bar", LineChart: "line", AreaChart: "area", PieChart: "pie", DonutChart: "donut" }[kind];
    var props = { type: type, data: data, title: p.title || undefined };
    if (type === "pie" || type === "donut") {
      props.label = "label";
      props.value = "value";
    } else {
      props.x = "label";
      props.y = "value";
    }
    return { type: "Chart", props: props };
  }

  function table(cols) {
    var columns = [];
    var rows = [];
    var len = 0;
    for (var i = 0; i < cols.length; i++) {
      var c = normalize(cols[i]);
      if (!c) continue;
      var data = (c.p && c.p.data) || [];
      columns.push({ field: "c" + columns.length, label: str(c.p.header), align: c.p.align });
      if (data.length > len) len = data.length;
      cols[i] = c;
    }
    var normal = cols.filter(function (c) { return c && c.p; });
    for (var r = 0; r < len; r++) {
      var row = {};
      for (var j = 0; j < normal.length; j++) row["c" + j] = (normal[j].p.data || [])[r];
      rows.push(row);
    }
    return { type: "DataGrid", props: { columns: columns, data: rows, dense: true } };
  }

  // ── markdown ─────────────────────────────────────────────────────────────

  function inline(s) {
    return str(s)
      .replace(/\*\*([^*]+)\*\*/g, "$1")
      .replace(/__([^_]+)__/g, "$1")
      .replace(/\*([^*]+)\*/g, "$1")
      .replace(/`([^`]+)`/g, "$1")
      .replace(/\[([^\]]+)\]\(([^)\s]+)\)/g, "$1 ($2)");
  }

  function markdown(src) {
    var lines = str(src).replace(/\r\n/g, "\n").split("\n");
    var out = [];
    var para = [];
    var list = [];
    var flushPara = function () {
      if (para.length) out.push(text(inline(para.join(" ")), { fontSize: "14" }));
      para = [];
    };
    var flushList = function () {
      if (!list.length) return;
      var items = [];
      for (var i = 0; i < list.length; i++) {
        items.push({ type: "Row", props: { style: { gap: "8", alignItems: "flex-start" } }, children: [
          text(list[i].mark, { fontSize: "14" }),
          { type: "Expanded", children: [text(inline(list[i].text), { fontSize: "14" })] },
        ] });
      }
      out.push(column(items, "xs"));
      list = [];
    };
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i];
      var fence = /^```\s*([\w-]*)\s*$/.exec(line);
      if (fence) {
        flushPara();
        flushList();
        var code = [];
        for (i++; i < lines.length && !/^```\s*$/.test(lines[i]); i++) code.push(lines[i]);
        out.push({ type: "CodeBlock", props: { code: code.join("\n"), language: fence[1] || undefined } });
        continue;
      }
      var h = /^(#{1,6})\s+(.*)$/.exec(line);
      if (h) {
        flushPara();
        flushList();
        out.push(title(inline(h[2]), h[1].length === 1 ? "lg" : h[1].length === 2 ? "md" : "sm"));
        continue;
      }
      var li = /^\s*(?:[-*+]|(\d+)[.)])\s+(.*)$/.exec(line);
      if (li) {
        flushPara();
        list.push({ mark: li[1] ? li[1] + "." : "•", text: li[2] });
        continue;
      }
      if (/^\s*(?:---|\*\*\*)\s*$/.test(line)) {
        flushPara();
        flushList();
        out.push({ type: "Divider" });
        continue;
      }
      if (/^>\s?/.test(line)) {
        flushPara();
        flushList();
        out.push({ type: "Callout", props: { severity: "info", text: inline(line.replace(/^>\s?/, "")) } });
        continue;
      }
      if (!line.trim()) {
        flushPara();
        flushList();
        continue;
      }
      flushList();
      para.push(line.trim());
    }
    flushPara();
    flushList();
    return column(out, "s");
  }

  // ── the catalog ──────────────────────────────────────────────────────────

  var R = {
    _unknown: function (n, p, ctx) {
      return card([title(n.c, "sm"), p.title ? muted(p.title) : null].concat(kids(n, ctx)));
    },
    AppShell: function (n, p, ctx) {
      return column([p.title ? title(p.title, "lg") : null, p.subtitle ? muted(p.subtitle) : null].concat(kids(n, ctx)), "l", { padding: "16" });
    },
    Page: function (n, p, ctx) {
      return column([p.title ? title(p.title, "lg") : null, p.subtitle ? muted(p.subtitle) : null].concat(kids(n, ctx)), "m");
    },
    Section: function (n, p, ctx) {
      return { type: "Section", props: { title: str(p.title), subtitle: p.description || undefined }, children: kids(n, ctx) };
    },
    Container: function (n, p, ctx) { return column(kids(n, ctx), "m"); },
    Center: function (n, p, ctx) { return { type: "Center", children: [column(kids(n, ctx), "m")] }; },
    Stack: function (n, p, ctx) {
      var ch = kids(n, ctx);
      if (p.direction === "row") {
        if (p.wrap) return wrap(ch, p.gap);
        return row(ch, p.gap, { justifyContent: { between: "space-between", around: "space-around", evenly: "space-evenly", center: "center", end: "flex-end" }[p.justify] || "flex-start", alignItems: { center: "center", end: "flex-end", start: "flex-start" }[p.align] || "center" });
      }
      return column(ch, p.gap);
    },
    Grid: function (n, p, ctx) {
      return { type: "ResponsiveGrid", props: { columns: Number(p.columns) || 2, gap: Number(gap(p.gap)) }, children: kids(n, ctx) };
    },
    Split: function (n, p, ctx) {
      var ch = n.children || [];
      return { type: "ResponsiveGrid", props: { columns: 2, gap: 12 }, children: compact([
        column(propKids(p.left || ch[0], child(ctx, "l")), "m"),
        column(propKids(p.right || ch[1], child(ctx, "r")), "m"),
      ]) };
    },
    Sidebar: function (n, p, ctx) {
      return { type: "ResponsiveGrid", props: { minColumnWidth: 220, maxColumns: 2, gap: 12 }, children: [
        column(propKids(p.side, child(ctx, "s")), "s"), column(propKids(p.main, child(ctx, "m")), "m"),
      ] };
    },
    Tabs: function (n, p, ctx) {
      var items = p.items || n.children || [];
      var state = local(ctx);
      var tabs = [];
      for (var i = 0; i < items.length; i++) {
        var x = normalize(items[i]) || { p: {} };
        tabs.push({ value: str(x.p.value || i), label: str(x.p.trigger || x.p.label || x.p.value || "Tab " + (i + 1)), node: x });
      }
      if (!tabs.length) return null;
      var active = state.tab !== undefined ? state.tab : str(p.defaultValue || tabs[0].value);
      var triggers = [];
      var panel = null;
      var seg = segmented(ctx, tabs, active, function (v) { state.tab = str(v); rerender(ctx); });
      for (var t = 0; t < tabs.length; t++) {
        (function (tab, idx) {
          var tap = handler(child(ctx, "t" + idx), "tab", function () { state.tab = tab.value; rerender(ctx); });
          var chip = { type: "Chip", props: { label: tab.label, selected: tab.value === active } };
          if (tap) chip.events = { change: tap };
          triggers.push(chip);
          if (tab.value === active) panel = column(propKids(tab.node.p.content || tab.node.children, child(ctx, "p" + idx)), "m");
        })(tabs[t], t);
      }
      return column([seg || wrap(triggers, "s"), panel], "m");
    },
    TabItem: function (n, p, ctx) { return column(propKids(p.content || n.children, ctx), "m"); },
    Accordion: function (n, p, ctx) {
      var items = p.items || n.children || [];
      var out = [];
      for (var i = 0; i < items.length; i++) {
        var x = normalize(items[i]) || { c: "AccordionItem", p: items[i] };
        out.push(R.AccordionItem(x, x.p || {}, child(ctx, i)));
      }
      return column(out, "s");
    },
    AccordionItem: function (n, p, ctx) {
      return { type: "Expandable", props: { title: str(p.title), expanded: !!p.defaultOpen }, children: propKids(p.content || n.children, ctx) };
    },
    Divider: function (n, p) { return p.label ? row([{ type: "Expanded", children: [{ type: "Divider" }] }, muted(p.label), { type: "Expanded", children: [{ type: "Divider" }] }]) : { type: "Divider" }; },
    Spacer: function (n, p) { return p.grow ? { type: "Spacer" } : { type: "SizedBox", props: { style: { height: gap(p.size) } } }; },
    ScrollArea: function (n, p, ctx) { return { type: "Scroll", props: { maxHeight: Number(p.maxHeight) || 320 }, children: kids(n, ctx) }; },
    Frame: function (n, p, ctx) { return card(kids(n, ctx)); },
    Overlay: function (n, p, ctx) { return column(kids(n, ctx), "m"); },
    Sheet: function (n, p, ctx) { return card([p.title ? title(p.title, "sm") : null].concat(kids(n, ctx))); },
    AppBar: function (n, p, ctx) {
      return row(compact(propKids(p.leading, child(ctx, "l")).concat([{ type: "Expanded", children: [title(p.title, "lg")] }]).concat(propKids(p.actions, child(ctx, "a")))), "s", { padding: "4" });
    },
    NavBar: function (n, p, ctx) { return wrap([p.brand ? title(p.brand, "sm") : null].concat(itemsAs(p.items || n.children, "NavItem", ctx)), "s"); },
    NavItem: function (n, p, ctx) { return button(ctx, str(p.label), p.action, p.active ? "secondary" : "ghost", p.icon); },
    Drawer: function (n, p, ctx) {
      return card([p.title ? title(p.title, "sm") : null, R.Sidebar(n, p, ctx)]);
    },
    BottomNav: function (n, p, ctx) {
      var items = (p.items || n.children || []).map(function (it) { var x = normalize(it && (it.c || it.component) ? it : { c: "BottomNavItem", p: it }); return (x && x.p) || {}; });
      if (items.length < 2 || items.length > 5) return wrap(itemsAs(p.items || n.children, "BottomNavItem", ctx), "s");
      var state = local(ctx);
      var active = state.nav !== undefined ? state.nav : Math.max(0, items.map(function (x) { return !!x.active; }).indexOf(true));
      var change = handler(ctx, "nav", function (e) {
        var i = Number(e && e.value !== undefined ? e.value : (e && e.data));
        state.nav = i;
        act(ctx, items[i].action === undefined ? { type: "ask", prompt: str(items[i].label) } : items[i].action, items[i].label);
        rerender(ctx);
      });
      var node = { type: "NavigationBar", props: { selected: active, items: items.map(function (x) {
        return { icon: isIconName(x.icon) ? x.icon : "circle", label: str(x.label), badge: x.badge };
      }) } };
      if (change) node.events = { change: change };
      return node;
    },
    BottomNavItem: function (n, p, ctx) { return button(ctx, str(p.label), p.action, p.active ? "secondary" : "ghost", p.icon); },
    Masthead: function (n, p, ctx) { return row([{ type: "Expanded", children: [title(p.brand, "md")] }].concat(kids(n, ctx))); },
    Hero: function (n, p, ctx) {
      return { type: "Card", props: { tone: "primary", style: { padding: "24", gap: "12" } }, children: compact([
        p.media ? { type: "ClipRRect", props: { style: { borderRadius: "20" } }, children: [{ type: "Image", props: { src: p.media, fit: "cover", style: { height: "180" } } }] } : null,
        text(p.headline, {}, "headlineLargeEmphasized"),
        p.subcopy ? text(p.subcopy, {}, "bodyLarge") : null,
        p.actions ? wrap(propKids(p.actions, child(ctx, "a")), "s") : null,
      ]) };
    },
    Dock: function (n, p, ctx) { return wrap([p.note ? muted(p.note) : null].concat(kids(n, ctx)), "s"); },
    Breadcrumb: function (n, p, ctx) {
      var items = itemsAs(p.items || n.children, "BreadcrumbItem", ctx);
      var out = [];
      for (var i = 0; i < items.length; i++) {
        if (i) out.push(muted("/"));
        out.push(items[i]);
      }
      return wrap(out, "xs");
    },
    BreadcrumbItem: function (n, p) { return text(p.label); },
    Segmented: function (n, p, ctx) {
      var items = p.items || n.children || [];
      var options = items.map(function (it) { var x = normalize(it) || { p: it }; return { label: x.p.label, value: x.p.value || x.p.label, icon: x.p.icon }; });
      var name = p.name || "segment";
      var current = valueOf(ctx, name, (options.filter(function (o, i) { var x = normalize(items[i]); return x && x.p.active; })[0] || options[0] || {}).value);
      return segmented(ctx, options, current, function (v) { setValue(ctx, name, v, true); }) || choice(ctx, name, options, current);
    },
    Segment: function (n, p) { return { type: "Chip", props: { label: str(p.label), selected: !!p.active } }; },
    CommandBar: function (n, p, ctx) { return wrap([p.label ? muted(p.label) : null].concat(kids(n, ctx)), "s"); },
    StatusBar: function (n, p, ctx) { return row([{ type: "Expanded", children: [muted(p.text)] }].concat(kids(n, ctx))); },
    Pagination: function (n, p, ctx) {
      var page = Number(valueOf(ctx, p.name || "page", p.page || 1));
      var pages = Number(p.pages) || 1;
      var go = function (d) {
        return handler(child(ctx, d > 0 ? "n" : "p"), "page", function () {
          setValue(ctx, p.name || "page", Math.max(1, Math.min(pages, page + d)), true);
          act(ctx, { type: "page", page: Math.max(1, Math.min(pages, page + d)) }, "page");
        });
      };
      return row([
        { type: "IconButton", props: { icon: "chevron_left", variant: "tonal", tooltip: "Previous", disabled: page <= 1 }, events: ctx.app ? { tap: go(-1) } : undefined },
        text(page + " / " + pages, {}, "labelLarge"),
        { type: "IconButton", props: { icon: "chevron_right", variant: "tonal", tooltip: "Next", disabled: page >= pages }, events: ctx.app ? { tap: go(1) } : undefined },
      ], "s", { justifyContent: "center" });
    },
    Fab: function (n, p, ctx) {
      var name = handler(ctx, "tap", function () { act(ctx, p.action, p.label || p.icon); });
      var node = { type: "FAB", props: { icon: isIconName(p.icon) ? p.icon : "add", label: p.label || undefined } };
      if (name) node.events = { tap: name };
      return node;
    },
    WizardRail: function (n, p, ctx) { return wrap(itemsAs(p.steps || n.children, "WizardRailStep", ctx), "s"); },
    WizardRailStep: function (n, p) {
      return { type: "Tag", props: { text: str(p.label), status: { done: "good", current: "info", error: "critical" }[p.state] || "", variant: p.state === "current" ? "filled" : "tonal" } };
    },
    Footer: function (n, p, ctx) { return column([{ type: "Divider" }, p.brand ? title(p.brand, "sm") : null].concat(kids(n, ctx)).concat([p.note ? muted(p.note) : null]), "s"); },
    Card: function (n, p, ctx) {
      var body = [p.media ? { type: "ClipRRect", props: { style: { borderRadius: "16" } }, children: [{ type: "Image", props: { src: p.media, fit: "cover", style: { height: "160" } } }] } : null, p.title ? title(p.title, "md") : null, p.description ? muted(p.description) : null]
        .concat(kids(n, ctx)).concat(p.footer ? [wrap(propKids(p.footer, child(ctx, "f")), "s")] : []);
      if (p.tone && p.tone !== "neutral") return { type: "Callout", props: { severity: severity(p.tone), title: str(p.title), text: p.description || undefined }, children: kids(n, ctx) };
      return card(body);
    },
    Tile: function (n, p) { return { type: "Stat", props: { label: str(p.label), value: str(p.value), deltaLabel: p.hint || undefined, status: status(p.tone) || undefined, size: "compact" } }; },
    Quote: function (n, p) { return { type: "Callout", props: { severity: "info", text: "“" + str(p.text) + "”" + (p.by ? " — " + p.by : "") } }; },
    Figure: function (n, p) { return column([{ type: "Image", props: { src: str(p.src), fit: "contain" } }, p.caption ? muted(p.caption) : null], "xs"); },
    Feature: function (n, p) { return card([glyph(p.icon, 26), title(p.title, "sm"), p.body ? muted(p.body) : null], null, "filled"); },
    FeatureGrid: function (n, p, ctx) { return { type: "ResponsiveGrid", props: { columns: Number(p.columns) || 3, gap: 12 }, children: itemsAs(p.items || n.children, "Feature", ctx) }; },
    ProsCons: function (n, p) {
      var list = function (head, items) { return card([title(head, "sm")].concat((items || []).map(function (x) { return text("• " + str(x)); }))); };
      return { type: "ResponsiveGrid", props: { columns: 2, gap: 12 }, children: [list("Pros", p.pros), list("Cons", p.cons)] };
    },
    LogoStrip: function (n, p) { return wrap([p.label ? muted(p.label) : null].concat((p.items || []).map(function (x) { return { type: "Tag", props: { text: str(x), variant: "outline" } }; })), "s"); },
    Title: function (n, p) { return title(p.text, p.size || "lg"); },
    Text: function (n, p) {
      var style = {};
      if (p.mono) style.fontFamily = "monospace";
      var node = text(p.text, style, { sm: "bodySmall", md: "bodyMedium", lg: "bodyLarge" }[p.size || "md"] || "bodyMedium");
      if (p.tone === "secondary" || p.tone === "muted") node.props.color = "muted";
      return node;
    },
    Markdown: function (n, p) { return markdown(p.content || p.text); },
    Callout: function (n, p, ctx) { return { type: "Callout", props: { severity: severity(p.tone), title: str(p.title), text: p.body || undefined }, children: kids(n, ctx) }; },
    Badge: function (n, p) { return { type: "Tag", props: { text: str(p.label), status: status(p.tone) || undefined, variant: "tonal" } }; },
    Avatar: function (n, p) { return { type: "Avatar", props: { name: str(p.name || "?"), url: p.src || undefined, size: { sm: 28, md: 36, lg: 48 }[p.size || "md"] || 36 } }; },
    AvatarGroup: function (n, p) {
      var names = p.names || [];
      var max = p.max || names.length;
      var out = names.slice(0, max).map(function (name) { return { type: "Avatar", props: { name: str(name), size: 28 } }; });
      if (names.length > max) out.push({ type: "Tag", props: { text: "+" + (names.length - max) } });
      return wrap(out, "xs");
    },
    Image: function (n, p) { return { type: "Image", props: { src: str(p.src), fit: "contain" } }; },
    CodeBlock: function (n, p) { return { type: "CodeBlock", props: { code: str(p.code), language: p.language || undefined } }; },
    JsonBlock: function (n, p) {
      var v = p.value;
      if (typeof v === "string") {
        try { v = JSON.parse(v); } catch (e) { /* show as text */ }
      }
      return column([p.title ? muted(p.title) : null, { type: "JsonView", props: { value: v, expanded: 1 } }], "xs");
    },
    EmptyState: function (n, p) {
      return { type: "Center", children: [column([
        { type: "Container", props: { style: { width: "72", height: "72", borderRadius: "28", backgroundColor: color("secondaryContainer", color("primaryContainer", "#e8def8")) } },
          children: [{ type: "Center", children: [{ type: "Icon", props: { icon: isIconName(p.icon) ? p.icon : "inbox", size: 32 } }] }] },
        title(p.title, "md"), p.description ? muted(p.description) : null,
      ], "s", { padding: "24", alignItems: "center" })] };
    },
    Skeleton: function () { return { type: "Shimmer", children: [{ type: "Container", props: { style: { height: "16", borderRadius: "8", backgroundColor: color("surfaceContainerHighest", "#e3e3e8") } } }] }; },
    Stat: function (n, p) {
      return { type: "Stat", props: { label: str(p.label), value: str(p.value), deltaLabel: p.delta !== undefined ? str(p.delta) : undefined, status: { up: "good", down: "critical" }[p.deltaTone] || undefined } };
    },
    StatRow: function (n, p, ctx) { return { type: "ResponsiveGrid", props: { minColumnWidth: 160, gap: 12 }, children: kids(n, ctx) }; },
    KPIStrip: function (n, p, ctx) { return { type: "ResponsiveGrid", props: { minColumnWidth: 140, gap: 8 }, children: kids(n, ctx) }; },
    Progress: function (n, p) { return { type: "Progress", props: { value: Math.max(0, Math.min(100, Number(p.value) || 0)), max: 100, label: p.label || undefined, showValue: true } }; },
    Meter: function (n, p) { return { type: "Progress", props: { value: Number(p.value) || 0, max: Number(p.max) || 100, label: p.label || undefined, showValue: true } }; },
    Sparkline: function (n, p) { return { type: "Sparkline", props: { values: (p.values || []).map(Number) } }; },
    Table: function (n, p) { return table((p.columns || n.children || []).slice()); },
    Col: function () { return null; },
    DataList: function (n, p) { return { type: "KeyValue", props: { items: (p.items || []).map(function (it) { return { label: str(it.label), value: str(it.value) }; }) } }; },
    KeyValue: function (n, p) { return { type: "KeyValue", props: { items: [{ label: str(p.keyLabel || p.key), value: str(p.value) }] } }; },
    List: function (n, p, ctx) { return { type: "ListGroup", children: itemsAs(p.items || n.children, "ListItem", ctx) }; },
    ListItem: function (n, p, ctx) {
      var props = { title: str(p.label || p.title), subtitle: p.subtitle || undefined, trailingText: p.meta || p.trailing || undefined };
      if (isIconName(p.icon)) props.leading = p.icon;
      else if (p.avatar) props.leadingAvatar = str(p.avatar);
      var node = { type: "ListTile", props: props };
      if (p.action !== undefined) {
        var tap = handler(ctx, "tap", function () { act(ctx, p.action, p.label); });
        if (tap) { node.events = { tap: tap }; if (!props.trailingText) props.trailing = "chevron_right"; }
      }
      return node;
    },
    Chip: function (n, p) { var c = { type: "Chip", props: { label: str(p.label) } }; if (p.active !== undefined) c.props.selected = !!p.active; if (isIconName(p.icon)) c.props.icon = p.icon; return c; },
    TagGroup: function (n, p, ctx) { return wrap(kids(n, ctx), "s"); },
    Timeline: function (n, p, ctx) {
      var items = p.items || n.children || [];
      var rows = [];
      for (var i = 0; i < items.length; i++) {
        var x = normalize(items[i] && (items[i].c || items[i].component) ? items[i] : { c: "TimelineItem", p: items[i] });
        if (x) rows.push({ title: str(x.p.title), description: x.p.body || undefined, time: x.p.time || undefined, status: x.p.status || undefined });
      }
      return { type: "Timeline", props: { data: rows } };
    },
    TimelineItem: function (n, p) { return R.Timeline({ children: [] }, { items: [p] }); },
    Alert: function (n, p) { return { type: "Callout", props: { severity: severity(p.tone), title: str(p.title), text: p.body || undefined } }; },
    Toast: function (n, p) { return { type: "Callout", props: { severity: severity(p.tone), text: str(p.message) } }; },
    Banner: function (n, p) { return { type: "Callout", props: { severity: "info", text: str(p.text) } }; },
    Spinner: function (n, p) { return row([{ type: "LoadingIndicator", props: { size: 36 } }, muted(p.label || "Loading…")], "m"); },
    StatusDot: function (n, p) { return { type: "Tag", props: { text: str(p.label || p.status), status: { ok: "good", online: "good", busy: "warning", error: "critical", offline: "critical" }[p.status] || undefined, variant: "tonal" } }; },
    Result: function (n, p) { return { type: "Callout", props: { severity: severity(p.tone || "success"), title: str(p.title), text: p.description || undefined } }; },
    Input: function (n, p, ctx) { return field(ctx, p, {}); },
    TextArea: function (n, p, ctx) { return field(ctx, p, { multiline: true }); },
    SearchField: function (n, p, ctx) { return field(ctx, p, { hint: "Search", bare: true, search: true }); },
    DateField: function (n, p, ctx) { return field(ctx, p, { date: true, hint: "YYYY-MM-DD" }); },
    Select: function (n, p, ctx) {
      var name = str(p.name);
      return column([name ? muted(name) : null, choice(ctx, name, p.items || n.children || [], valueOf(ctx, name, p.value))], "xs");
    },
    SelectItem: function () { return null; },
    RadioGroup: function (n, p, ctx) {
      var name = str(p.name);
      return column([name ? muted(name) : null, choice(ctx, name, p.options || [], valueOf(ctx, name, p.value))], "xs");
    },
    Radio: function (n, p) { return { type: "Tag", props: { text: str(p.label || p.value), variant: "outline" } }; },
    Checkbox: function (n, p, ctx) { return toggle(ctx, p, "Checkbox"); },
    Switch: function (n, p, ctx) { return toggle(ctx, p, "Switch"); },
    Slider: function (n, p, ctx) {
      var name = str(p.name);
      var min = Number(p.min === undefined ? 0 : p.min);
      var max = Number(p.max === undefined ? 100 : p.max);
      var value = Number(valueOf(ctx, name, p.value === undefined ? min : p.value));
      var change = handler(ctx, "slide", function (e) { setValue(ctx, name, Number(e && (e.value !== undefined ? e.value : e.data)), true); });
      var node = { type: "Slider", key: ctx.key + "_" + ctx.path, props: { value: value, min: min, max: max } };
      if (change) node.events = { change: change };
      node.props.label = true;
      return column([row([{ type: "Expanded", children: [muted(p.label || name)] }, text(String(value), {}, "labelLarge")]), node], "xs");
    },
    FormControl: function (n, p, ctx) { return column([p.label ? muted(p.label) : null].concat(propKids(p.field, ctx)).concat([p.hint ? muted(p.hint) : null]), "xs"); },
    FieldRow: function (n, p, ctx) { return { type: "ResponsiveGrid", props: { minColumnWidth: 180, gap: 12 }, children: kids(n, ctx) }; },
    Form: function (n, p, ctx) {
      var form = child(ctx, "form");
      var outer = ctx.onAction;
      // A button inside a form submits its values (with the form's name).
      form.onAction = function (action, values, label) {
        var a = action && typeof action === "object" ? action : { type: "submit", prompt: action || label };
        if (!a.form) a.form = p.name;
        if (outer) outer(a, values, label);
      };
      return card(propKids(p.fields || n.children, form, "f").concat([wrap(propKids(p.buttons, form, "b"), "s")]));
    },
    Button: function (n, p, ctx) { return button(ctx, p.label, p.action, { secondary: "secondary", ghost: "ghost", danger: "danger", outline: "outline", tonal: "tonal" }[p.variant] || "primary", p.icon); },
    ButtonGroup: function (n, p, ctx) { return wrap(kids(n, ctx), "s"); },
    IconButton: function (n, p, ctx) { return iconButton(ctx, p.icon, p.action, p.label); },
    LinkButton: function (n, p, ctx) { return button(ctx, p.label, p.action, "ghost", p.icon); },
    Menu: function (n, p, ctx) { return column(itemsAs(p.items || n.children, "MenuItem", ctx), "xs"); },
    MenuItem: function (n, p, ctx) { return button(ctx, p.label, p.action, "ghost", p.icon); },
    Toolbar: function (n, p, ctx) { return wrap(kids(n, ctx), "s"); },
    BarChart: function (n, p) { return chart("BarChart", p); },
    LineChart: function (n, p) { return chart("LineChart", p); },
    AreaChart: function (n, p) { return chart("AreaChart", p); },
    PieChart: function (n, p) { return chart("PieChart", p); },
    DonutChart: function (n, p) { return chart("DonutChart", p); },
    MessageBubble: function (n, p) {
      var mine = p.role === "user";
      return row([{ type: "Container", props: { style: {
        padding: "12", borderRadius: "20", maxWidth: "520",
        backgroundColor: mine ? color("primaryContainer", "#dfe3ff") : color("surfaceContainerHighest", "#ececf1"),
      } }, children: [text(p.text)] }], "s", { justifyContent: mine ? "flex-end" : "flex-start" });
    },
    FollowUpChips: function (n, p, ctx) {
      return wrap((p.suggestions || []).map(function (s, i) { return button(child(ctx, i), s, { type: "ask", prompt: s }, "secondary"); }), "s");
    },
    Step: function (n, p) {
      return row([
        { type: "Tag", props: { text: { done: "✓", active: "…", error: "!" }[p.status] || "○", status: { done: "good", active: "info", error: "critical" }[p.status] || undefined } },
        { type: "Expanded", children: [column([text(p.title, { fontWeight: "bold" }), p.description ? muted(p.description) : null], "xs")] },
      ]);
    },
    StepList: function (n, p, ctx) { return column(itemsAs(p.steps || n.children, "Step", ctx), "s"); },
    ChatCard: function (n, p, ctx) { return card([p.title ? title(p.title, "sm") : null].concat(kids(n, ctx))); },
    Rating: function (n, p) { return row(compact([{ type: "Rating", props: { value: Number(p.value) || 0, max: 5 } }, p.count != null ? muted("(" + p.count + ")") : null])); },
    Price: function (n, p) {
      return row(compact([title(p.amount, "md"), p.compareAt ? muted("was " + p.compareAt) : null, p.period ? muted("/" + p.period) : null]));
    },
    MediaCard: function (n, p) { return card([p.src ? { type: "Image", props: { src: p.src, fit: "cover", style: { height: "140", borderRadius: "16" } } } : null, title(p.title, "sm"), p.meta ? muted(p.meta) : null]); },
    ProductCard: function (n, p, ctx) {
      return card([p.image ? { type: "Image", props: { src: p.image, fit: "cover", style: { height: "140", borderRadius: "16" } } } : null, p.badge ? { type: "Tag", props: { text: str(p.badge), status: "info" } } : null,
        title(p.title, "sm"), text(p.price, { fontWeight: "bold" }), p.rating != null ? R.Rating(n, { value: p.rating }, ctx) : null]);
    },
    Gallery: function (n, p) {
      return { type: "ResponsiveGrid", props: { columns: Number(p.columns) || 3, gap: 8 }, children: (p.images || []).map(function (src) { return { type: "Image", props: { src: str(src), fit: "cover", style: { height: "120", borderRadius: "16" } } }; }) };
    },
    Carousel: function (n, p, ctx) {
      var slides = p.slides || n.children || [];
      var state = local(ctx);
      var i = Math.min(state.slide || 0, Math.max(0, slides.length - 1));
      var s = slides[i];
      var step = function (d) { return handler(child(ctx, d > 0 ? "n" : "p"), "slide", function () { state.slide = (i + d + slides.length) % slides.length; rerender(ctx); }); };
      return column([
        typeof s === "string" ? { type: "Image", props: { src: s, fit: "cover", style: { height: "200", borderRadius: "16" } } } : renderAt(s, ctx, "s" + i),
        slides.length > 1 ? { type: "Row", props: { style: { gap: "8", justifyContent: "center", alignItems: "center" } }, children: [
          { type: "IconButton", props: { icon: "chevron_left", variant: "tonal", tooltip: "Previous" }, events: ctx.app ? { tap: step(-1) } : undefined },
          muted(i + 1 + " / " + slides.length),
          { type: "IconButton", props: { icon: "chevron_right", variant: "tonal", tooltip: "Next" }, events: ctx.app ? { tap: step(1) } : undefined },
        ] } : null,
      ], "s");
    },
    Feed: function (n, p, ctx) { return column(itemsAs(p.items || n.children, "FeedItem", ctx), "s"); },
    FeedItem: function (n, p) {
      return card([{ type: "ListTile", props: { title: str(p.author), leadingAvatar: str(p.author || "?"), trailingText: p.time || undefined } }, text(p.body, {}, "bodyMedium")]);
    },
    Comment: function (n, p) { return column([text(str(p.author) + (p.time ? "  " + p.time : ""), { fontWeight: "bold", fontSize: "13" }), text(p.body)], "xs"); },
    NotificationItem: function (n, p) {
      return { type: "ListTile", props: { title: str(p.title), subtitle: p.body || undefined, leading: p.unread ? "notifications_active" : "notifications_none", selected: !!p.unread, lines: p.body && String(p.body).length > 60 ? 3 : undefined } };
    },
    FileRow: function (n, p) { return { type: "ListTile", props: { title: str(p.name), leading: isIconName(p.icon) ? p.icon : "description", trailingText: p.meta || undefined } }; },
    CheckItem: function (n, p, ctx) { return toggle(ctx, { name: p.name || ("check_" + ctx.path), label: p.label, value: p.done }, "Checkbox"); },
    Checklist: function (n, p, ctx) { return column(itemsAs(p.items || n.children, "CheckItem", ctx), "xs"); },
    Kanban: function (n, p, ctx) {
      var cols = p.columns || n.children || [];
      return { type: "ResponsiveGrid", props: { minColumnWidth: 200, gap: 12 }, children: itemsAs(cols, "KanbanColumn", ctx) };
    },
    KanbanColumn: function (n, p, ctx) {
      var cards = itemsAs(n.children || p.cards, "KanbanCard", ctx);
      return { type: "Container", props: { style: { padding: "12", borderRadius: "24", backgroundColor: color("surfaceContainer", "#f3edf7") } }, children: [column([
        row([{ type: "Expanded", children: [title(p.title, "sm")] }, { type: "Tag", props: { text: String(cards.length) } }]),
      ].concat(cards), "s")] };
    },
    KanbanCard: function (n, p) { return card([text(p.title, {}, "titleSmall"), p.meta ? muted(p.meta) : null], { padding: "12", gap: "4" }); },
    Tree: function (n, p) {
      var conv = function (it) {
        var x = normalize(it && (it.c || it.component) ? it : { c: "TreeItem", p: it, children: it && it.children });
        return x ? { label: str(x.p.label), children: (x.children || []).map(conv) } : null;
      };
      return { type: "TreeView", props: { data: compact((p.items || n.children || []).map(conv)), expanded: 1 } };
    },
    TreeItem: function (n, p, ctx) { return R.Tree({ children: [] }, { items: [{ c: "TreeItem", p: p, children: n.children }] }, ctx); },
    CalendarGrid: function (n, p) {
      var days = p.days || [];
      var hi = {};
      (p.highlights || []).forEach(function (h) { hi[String(h)] = true; });
      return column([p.label ? title(p.label, "sm") : null, { type: "ResponsiveGrid", props: { columns: 7, gap: 4 }, children: days.map(function (d, i) {
        return { type: "Tag", props: { text: str(d), variant: hi[String(i)] || hi[String(d)] ? "filled" : "outline" } };
      }) }], "s");
    },
    MapPlaceholder: function (n, p) { return { type: "ListTile", props: { title: str(p.pin || "Map"), subtitle: p.subtitle || undefined, leading: "place" } }; },
    Compare: function (n, p) {
      var headers = p.headers || [];
      var columns = [{ field: "feature", label: "" }].concat(headers.map(function (h, i) { return { field: "v" + i, label: str(h) }; }));
      var data = (p.rows || []).map(function (r) {
        var x = r.p || r;
        var row = { feature: str(x.feature) };
        (x.values || []).forEach(function (v, i) { row["v" + i] = v; });
        return row;
      });
      return { type: "DataGrid", props: { columns: columns, data: data, dense: true } };
    },
    CompareRow: function () { return null; },
    ToolHeader: function (n, p) { return row([{ type: "Avatar", props: { name: str(p.name), url: p.avatar || undefined } }, { type: "Expanded", children: [column([title(p.name, "md"), p.subtitle ? muted(p.subtitle) : null], "xs")] }]); },
    MicrotoolResult: function (n, p) {
      var d = p.data;
      return column([p.label ? muted(p.label) : null, typeof d === "object" && d !== null ? { type: "JsonView", props: { value: d, expanded: 1 } } : { type: "CodeBlock", props: { code: str(d) } }], "xs");
    },
    BindingHint: function (n, p) { return row([{ type: "Tag", props: { text: str(p.name), variant: "outline" } }, muted(p.hint)]); },
  };

  function renderAt(raw, ctx, i) {
    return renderNode(raw, child(ctx || {}, i));
  }

  function renderNode(raw, ctx) {
    var node = normalize(raw);
    if (!node) return null;
    var fn = R[node.c] || R._unknown;
    try {
      return fn(node, node.p || {}, ctx || {});
    } catch (e) {
      return { type: "Callout", props: { severity: "warning", title: node.c, text: "Could not show this part: " + ((e && e.message) || e) } };
    }
  }

  function render(tree, ctx) {
    ctx = ctx || {};
    if (!ctx.path) ctx.path = "ou";
    if (!ctx.key) ctx.key = "ou";
    return renderNode(tree, ctx) || { type: "SizedBox" };
  }

  // OpenUI JSON in a reply: an object, ```openui / ```json fenced, or bare.
  function tryParse(t) {
    if (t === null || t === undefined) return null;
    if (typeof t === "object") return t.openui || t.type === "openui" || t.c || t.component || t.root ? t : null;
    var s = String(t).trim();
    var fence = /```(?:openui|json)?\s*([\s\S]*?)```/i.exec(s);
    var raw = fence ? fence[1].trim() : s;
    if (!(raw.charAt(0) === "{" || raw.charAt(0) === "[")) return null;
    try {
      var j = JSON.parse(raw);
      if (j && (j.openui || j.type === "openui" || j.c || j.component || j.root || Array.isArray(j))) return j;
    } catch (e) {
      return null;
    }
    return null;
  }

  function fromReply(reply, ctx) {
    var tree = tryParse(reply);
    if (tree) return render(tree, ctx);
    if (reply && typeof reply === "object") return { type: "JsonView", props: { value: reply, expanded: 1 } };
    return markdown(reply);
  }

  // ── islands ──────────────────────────────────────────────────────────────

  function fill(prompt, vars) {
    return str(prompt).replace(/\{\{\s*([\w.-]+)\s*\}\}/g, function (m, k) {
      return vars && vars[k] !== undefined ? String(vars[k]) : m;
    });
  }

  function island(app, key) {
    var all = app.state.__openui || (app.state.__openui = {});
    return all[key] || (all[key] = { status: "idle", values: {}, store: {}, history: [] });
  }

  function islandCtx(app, key, s, onAction) {
    return { app: app, key: key, path: "ou", values: s.values, store: s.store, onAction: onAction };
  }

  // Runs an island's agent ask (prompt + the form values it was given).
  function askInto(app, key, s, agent, prompt, values) {
    var body = prompt;
    if (values && Object.keys(values).length) body += "\n\nValues (JSON):\n" + JSON.stringify(values);
    body += "\n\nAnswer with an OpenUI JSON tree (fenced ```openui, components from the Aseman OpenUI catalog) when a visual answer helps, else markdown.";
    s.status = "loading";
    s.error = "";
    app.render();
    return root.Aseman.ask(agent, body, { history: s.history }).then(function (r) {
      var reply = (r && r.reply) || "";
      s.history = s.history.concat([{ role: "user", content: prompt }, { role: "assistant", content: reply }]).slice(-12);
      s.reply = reply;
      s.status = "done";
      app.render();
    }, function (e) {
      s.status = "error";
      s.error = (e && e.message) || String(e);
      app.render();
    });
  }

  function callInto(app, s, tool, microtool, args) {
    s.status = "loading";
    s.error = "";
    app.render();
    return root.Aseman.call(tool, microtool, args || {}).then(function (result) {
      s.reply = result;
      s.status = "done";
      app.render();
    }, function (e) {
      s.status = "error";
      s.error = (e && e.message) || String(e);
      app.render();
    });
  }

  // What a button inside an island's answer does.
  function islandAction(app, key, s, agent) {
    return function (action, values, label) {
      var a = action && typeof action === "object" ? action : { type: "ask", prompt: action || label };
      var type = a.type || (a.call ? "call" : a.ask || a.prompt ? "ask" : a.set ? "set" : "ask");
      if (type === "call" || a.call) {
        var c = a.call || a;
        return callInto(app, s, c.tool, c.microtool, c.args);
      }
      if (type === "set") {
        for (var k in a.set || {}) s.values[k] = a.set[k];
        return app.render();
      }
      if (!agent) return undefined;
      var prompt = a.ask || a.prompt || label || "Continue";
      if (type === "submit" && a.form) prompt = "Form \"" + a.form + "\" submitted: " + prompt;
      return askInto(app, key, s, a.agent || agent, prompt, values);
    };
  }

  function islandBody(app, key, s, agent, opts) {
    var head = opts.title ? title(opts.title, "sm") : null;
    if (s.status === "loading") return card([head, R.Spinner(null, { label: opts.loadingText || "Working on it…" })]);
    if (s.status === "error") {
      var retry = app.handler(key + "_retry", function () { s.status = "idle"; if (opts.run) opts.run(); });
      return card([head, { type: "Callout", props: { severity: "critical", text: s.error } }, { type: "Button", props: { text: "Try again", variant: "tonal", icon: "refresh" }, events: { tap: retry } }]);
    }
    if (s.status === "done") {
      var ctx = islandCtx(app, key, s, islandAction(app, key, s, agent));
      return card([head, fromReply(s.reply, ctx)]);
    }
    return null;
  }

  // An agent-backed section: asks [agent] on first render (auto, default)
  // or when run() is called, and shows the answer (OpenUI or markdown).
  function panel(app, key, opts) {
    opts = opts || {};
    var s = island(app, key);
    var prompt = fill(opts.prompt, opts.vars);
    var run = function () { return askInto(app, key, s, opts.agent, prompt, opts.values); };
    if (s.status === "idle" && opts.auto !== false) {
      s.status = "loading";
      // Ask after this render is out.
      root.Aseman.Task.resolve(null).then(run);
    }
    var body = islandBody(app, key, s, opts.agent, { title: opts.title, run: run, loadingText: opts.loadingText });
    if (body) return body;
    var start = app.handler(key + "_start", run);
    return card([opts.title ? title(opts.title, "sm") : null, { type: "Button", props: { text: opts.label || "Ask " + opts.agent, variant: "tonal", icon: "auto_awesome" }, events: { tap: start } }]);
  }

  // A button that asks an agent and shows its answer below it.
  function action(app, key, opts) {
    opts = opts || {};
    var s = island(app, key);
    var run = function () { return askInto(app, key, s, opts.agent, fill(opts.prompt, opts.vars), opts.values); };
    var tap = app.handler(key + "_run", run);
    var body = islandBody(app, key, s, opts.agent, { title: opts.title, run: run });
    return column([{ type: "Button", props: { text: opts.label || "Ask " + opts.agent, variant: VARIANTS[opts.variant] || opts.variant || "tonal", icon: opts.icon || "auto_awesome", loading: s.status === "loading" }, events: { tap: tap } }, body], "s");
  }

  // A section filled by a space app's microtool (programmed data).
  function query(app, key, opts) {
    opts = opts || {};
    var s = island(app, key);
    var run = function () { return callInto(app, s, opts.tool, opts.microtool, opts.args); };
    if (s.status === "idle" && opts.auto !== false) {
      s.status = "loading";
      root.Aseman.Task.resolve(null).then(run);
    }
    return islandBody(app, key, s, opts.agent, { title: opts.title, run: run }) || card([opts.title ? title(opts.title, "sm") : null]);
  }

  function components() {
    return Object.keys(R).filter(function (k) { return k !== "_unknown"; }).sort();
  }

  root.OpenUI = {
    render: render,
    fromReply: fromReply,
    tryParse: tryParse,
    markdown: markdown,
    normalize: normalize,
    panel: panel,
    action: action,
    query: query,
    components: components,
    version: "1.2.0-elpian",
  };
})(typeof globalThis !== "undefined" ? globalThis : this);
