#!/usr/bin/env node
// Validates Elpian UI DSL view trees against the engine's schema
// (schema.mjs): node shape, node types, props (types, enums, ranges, icons,
// formats, data fields), styles, events, keys, child arity and slots,
// parent–child relations, layout constraints (what throws in an unbounded
// Row or scroll), the phone-widget rules and Material 3 Expressive design
// lint. Every issue names where it is, why it matters and how to fix it.
//
//   node validate.mjs tree.json                 a tree (or an array of trees) in a JSON file; "-" reads stdin
//   node validate.mjs --program elpian/app.js   runs the program on QuickJS and validates every render
//        [--server http://127.0.0.1:8787] [--apps APPS.json]   (as the app and as its phone widget)
//   node validate.mjs --openui tree.json        an OpenUI tree, rendered to Elpian first
//   node validate.mjs --describe Button         the schema of a node type (--list: every type)
//   options: --widget (validate as the phone widget), --json, --strict (warnings fail too),
//            --no-design (skip design lint), --quiet (errors only)
//
// As a library: import { validate } from "./validate.mjs";
//   validate(tree, {mode: "app" | "widget", design: true, theme: {colors}}) -> report

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import {
  TYPES, STYLE, COMMON_PROPS, GESTURE_EVENTS, CURVES, CSS_COLOR_NAMES, KIT_COLOR_NAMES,
  NOT_IN_WIDGET, WIDGET_MAX_NODES, HTML_DOC,
} from "./schema.mjs";

const here = path.dirname(fileURLToPath(import.meta.url));
const NODES = JSON.parse(fs.readFileSync(path.join(here, "nodes.json"), "utf8"));
const ICONS = new Set(JSON.parse(fs.readFileSync(path.join(here, "icons.json"), "utf8")).icons);
const HTML = new Set(NODES.html);
const ALL_TYPES = [...Object.keys(TYPES), ...NODES.html];

// ── helpers ──────────────────────────────────────────────────────────────────

const isObj = (v) => v !== null && typeof v === "object" && !Array.isArray(v);
const isScalar = (v) => typeof v === "string" || typeof v === "number" || typeof v === "boolean";
const show = (v) => {
  const s = JSON.stringify(v);
  return s === undefined ? String(v) : s.length > 60 ? s.slice(0, 57) + "…" : s;
};

function distance(a, b) {
  a = a.toLowerCase();
  b = b.toLowerCase();
  const d = Array.from({ length: a.length + 1 }, (_, i) => [i]);
  for (let j = 1; j <= b.length; j++) d[0][j] = j;
  for (let i = 1; i <= a.length; i++) {
    for (let j = 1; j <= b.length; j++) {
      d[i][j] = Math.min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + (a[i - 1] === b[j - 1] ? 0 : 1));
    }
  }
  return d[a.length][b.length];
}

// The closest names to [name] (by edit distance, or a shared prefix/substring).
function suggest(name, candidates, max = 3) {
  const n = String(name).toLowerCase().replace(/[-_]/g, "");
  return [...new Set(candidates)]
    .map((c) => {
      const k = c.toLowerCase().replace(/[-_]/g, "");
      const sub = k.includes(n) || n.includes(k) ? -1 : 0;
      return { c, d: distance(n, k) + sub };
    })
    .filter((x) => x.d <= Math.max(2, Math.floor(n.length / 3)))
    .sort((a, b) => a.d - b.d)
    .slice(0, max)
    .map((x) => x.c);
}
const didYouMean = (name, candidates) => {
  const s = suggest(name, candidates);
  return s.length ? ` Did you mean ${s.map((x) => "`" + x + "`").join(", ")}?` : "";
};

const camel = (k) => k.replace(/-([a-z])/g, (_, c) => c.toUpperCase());

function resolveType(type) {
  const spec = TYPES[type];
  if (spec && spec.alias) return { ...TYPES[spec.alias], ...spec };
  return spec;
}

const NUMERIC = /^\s*-?\d+(\.\d+)?\s*$/;
const LENGTH = /^\s*-?\d+(\.\d+)?\s*(px|%|vw|vh|vmin|vmax)?\s*$/;
const HEX = /^#([0-9a-f]{3}|[0-9a-f]{4}|[0-9a-f]{6}|[0-9a-f]{8})$/i;
const RGB = /^rgba?\(\s*\d+(\.\d+)?\s*,\s*\d+(\.\d+)?\s*,\s*\d+(\.\d+)?\s*(,\s*\d*(\.\d+)?\s*)?\)$/i;
const FORMAT = /^\+?(text|number(:\d+)?|integer|compact|percent(:\d+)?|currency(:[A-Za-z]{3}(:\d+)?)?|date|time|datetime)$/;
const EMOJI = /\p{Extended_Pictographic}/u;
const GLYPH_ONLY = /^\s*[+\-×✕✖✓✔›‹»«→←↑↓⋯…•·◀▶▲▼★☆⚙♥❤]\s*$/u;

function cssColor(v) {
  if (typeof v !== "string") return false;
  const s = v.trim();
  return HEX.test(s) || RGB.test(s) || CSS_COLOR_NAMES.includes(s.toLowerCase());
}
function kitColor(v) {
  if (typeof v !== "string") return false;
  const s = v.trim();
  return HEX.test(s) || KIT_COLOR_NAMES.includes(s) || /^(series-)?\d+$/.test(s);
}

// ── the validator ────────────────────────────────────────────────────────────

export function validate(tree, opts = {}) {
  const mode = opts.mode || "app";
  const design = opts.design !== false;
  const themeHex = new Set(Object.values((opts.theme && opts.theme.colors) || {}).map((c) => String(c).toLowerCase()));
  const issues = [];
  const stats = { nodes: 0, depth: 0, types: {} };
  const keys = new Map(); // key -> [{at, events}]

  function add(severity, code, ctx, message, fix) {
    issues.push({ severity, code, path: ctx.path, at: ctx.at, type: ctx.type, message, fix });
  }

  // --- styles -----------------------------------------------------------------
  function checkStyle(style, ctx, where = "style") {
    if (style === undefined || style === null) return;
    if (!isObj(style)) {
      add("error", "style-not-object", ctx, `${where} must be an object of style keys, not ${show(style)} (a CSS string is not parsed; the builder casts it and throws).`,
        `Write ${where}: { padding: "16", gap: "8" }.`);
      return;
    }
    for (const [rawKey, v] of Object.entries(style)) {
      if (v === null || v === undefined) continue;
      const key = camel(rawKey);
      const kind = STYLE[key];
      const at = `${where}.${rawKey}`;
      if (!kind) {
        const hints = {
          paddingHorizontal: "paddingX", paddingVertical: "paddingY", marginHorizontal: "marginX", marginVertical: "marginY",
          elevation: "boxShadow (or the Card `elevation` prop)", borderTopLeftRadius: "borderRadius (one radius for all corners) inside a ClipRRect",
          borderTopRightRadius: "borderRadius", borderBottomLeftRadius: "borderRadius", borderBottomRightRadius: "borderRadius",
          fontColor: "color", textColor: "color", background_color: "backgroundColor", size: "width / height",
        };
        add("warning", "style-unknown", ctx, `${at} is not a style key the engine reads: it is ignored.${hints[key] ? ` Use \`${hints[key]}\`.` : didYouMean(key, Object.keys(STYLE))}`);
        continue;
      }
      checkStyleValue(key, kind, v, ctx, at);
    }
  }

  function checkStyleValue(key, kind, v, ctx, at) {
    const bad = (msg, fix, severity = "warning") => add(severity, "style-value", ctx, `${at} = ${show(v)}: ${msg}`, fix);
    if (kind === "any") return;
    if (kind.startsWith("enum:")) {
      const values = kind.slice(5).split("|");
      if (typeof v !== "string") return bad(`must be a string (the engine casts it; anything else throws).`, `One of ${values.join(", ")}.`, "error");
      const norm = (s) => s.toLowerCase().replace(/-/g, "");
      if (!values.some((x) => norm(x) === norm(v))) bad(`not a value the engine knows, so it falls back to its default.${didYouMean(v, values)}`, `One of ${values.join(", ")}.`);
      return;
    }
    switch (kind) {
      case "string":
        if (typeof v !== "string") bad("must be a string (the engine casts it; anything else throws).", undefined, "error");
        return;
      case "bool":
        if (typeof v !== "boolean") bad("must be true or false (the engine casts it; anything else throws).", undefined, "error");
        return;
      case "length":
        if (typeof v === "number") return;
        if (typeof v !== "string") return bad("must be a number or a length string.", 'e.g. 120, "120", "50%", "100vw"');
        if (v.trim() === "auto" || v.includes("calc(") || v.trim().startsWith("env(")) return;
        if (!LENGTH.test(v)) bad(`not a length the engine reads${/\d\s*(rem|em|pt|dp)\b/.test(v) ? " (rem/em/pt are not supported)" : ""}: it is ignored or misread.`, 'Use a number (logical px), "50%", or viewport units ("100vw").');
        return;
      case "number":
      case "int":
        if (typeof v === "number") {
          if (kind === "int" && !Number.isInteger(v)) bad("must be a whole number (it is truncated).");
          if (key === "opacity" && (v < 0 || v > 1)) bad("opacity must be between 0 and 1 (out of range throws).", undefined, "error");
          if ((key === "fontSize" || key === "borderWidth") && v < 0) bad("must not be negative.", undefined, "error");
          return;
        }
        if (typeof v !== "string") return bad("must be a number.", undefined, kind === "int" ? "warning" : "warning");
        if (!NUMERIC.test(v)) {
          const px = /^\s*-?\d+(\.\d+)?px\s*$/.test(v);
          if (!px) bad(`not a plain number: the engine strips every non-digit (${show(v)} reads as ${show(String(v).replace(/[^0-9.\-]/g, "") || "nothing")}).`, "Use a number, e.g. 16.");
        }
        if (key === "opacity" && NUMERIC.test(v) && (Number(v) < 0 || Number(v) > 1)) bad("opacity must be between 0 and 1.", undefined, "error");
        return;
      case "color":
        if (!cssColor(v)) bad("not a color the engine parses: it is ignored.", 'Use #RRGGBB, #RGB, #AARRGGBB, rgb()/rgba() or a name like "white" — better, a role from Aseman.env().theme.colors.');
        else if (design && typeof v === "string" && HEX.test(v.trim()) && themeHex.size && !themeHex.has(v.trim().toLowerCase()) && !/^#(fff|ffffff|000|000000)$/i.test(v.trim())) {
          add("info", "design-hardcoded-color", ctx, `${at} = ${v} is a hard-coded color, not one of the person's theme roles: it will not follow their light/dark mode and accent.`,
            "Leave it unset, or take it from Aseman.env().theme.colors (primaryContainer, surfaceContainer, …), or use node roles (Card tone, Text color, Tag status).");
        }
        return;
      case "radius":
        if (typeof v === "number") {
          if (v < 0) bad("must not be negative.", undefined, "error");
          return;
        }
        if (typeof v === "string" && /\d\s+\d/.test(v.trim())) {
          return bad(`only one radius is supported; the engine strips non-digits, so this reads as ${String(v).replace(/[^0-9.\-]/g, "")}.`, 'Use one number (e.g. "16"); for different corners, clip with ClipRRect or restructure.', "error");
        }
        if (typeof v !== "string" || !/^\s*\d+(\.\d+)?(px)?\s*$/.test(v)) bad("must be one number.", 'e.g. 16 or "16".');
        return;
      case "edges": {
        if (isObj(v)) {
          for (const [side, n] of Object.entries(v)) {
            if (!["top", "right", "bottom", "left"].includes(side)) bad(`unknown side "${side}".`, "Use top, right, bottom, left.");
            else if (!(typeof n === "number" || (typeof n === "string" && NUMERIC.test(n.replace(/px$/, ""))))) bad(`side ${side} must be a number.`);
            else if (Number(String(n).replace(/px$/, "")) < 0) bad("negative padding/margin throws.", "Use 0 or more.", "error");
          }
          return;
        }
        if (typeof v === "number") {
          if (v < 0) bad("negative padding/margin throws.", "Use 0 or more.", "error");
          return;
        }
        if (typeof v !== "string") return bad("must be a number, a string of 1–4 numbers, or {top, right, bottom, left}.");
        const parts = v.trim().split(/\s+/);
        if (parts.length > 4 || parts.some((p) => !/^-?\d+(\.\d+)?(px)?$/.test(p))) bad("must be 1–4 numbers (\"8\", \"8 16\", \"8 16 8 16\").", "Use plain numbers; units other than px are not read.");
        else if (parts.some((p) => parseFloat(p) < 0)) bad("negative padding/margin throws.", "Use 0 or more.", "error");
        return;
      }
      case "duration":
        if (typeof v === "number") return;
        if (typeof v !== "string" || !/^\s*\d+(\.\d+)?\s*(ms|s)?\s*$/i.test(v)) bad("not a duration.", 'Use milliseconds (300) or "300ms" / "0.3s".');
        return;
      case "curve": {
        const norm = (s) => String(s).toLowerCase().replace(/-/g, "");
        if (typeof v !== "string" || !CURVES.some((c) => norm(c) === norm(v))) bad(`not a known curve.${didYouMean(String(v), CURVES)}`, `One of ${CURVES.slice(0, 8).join(", ")}, …`);
        return;
      }
      case "border":
        if (!isObj(v)) bad("border must be an object of sides ({top: {width, color}, …}); a CSS string is ignored.", "For an even border use borderWidth + borderColor.");
        return;
      default:
        return;
    }
  }

  // --- props ------------------------------------------------------------------
  function checkValue(spec, v, ctx, at, type) {
    const s = typeof spec === "string" ? { type: spec } : spec;
    const err = (msg, fix) => add("error", "prop-type", ctx, `${at} = ${show(v)}: ${msg}`, fix);
    const warn = (msg, fix, code = "prop-value") => add("warning", code, ctx, `${at} = ${show(v)}: ${msg}`, fix);
    switch (s.type) {
      case "any":
        return;
      case "dart":
        warn(`is only read from Dart code; in a JSON tree it is ignored.`, s.doc ? s.doc[0].toUpperCase() + s.doc.slice(1) + "." : undefined, "prop-dart-only");
        return;
      case "text":
        if (!isScalar(v)) warn("should be text (a string or number); objects show as their JSON.");
        return;
      case "string":
        if (typeof v !== "string") err("must be a string (the builder casts it; anything else throws).", `Write ${at}: ${show(String(v))}.`);
        return;
      case "number":
        if (typeof v === "number") return checkRange(s, v, ctx, at, type);
        if (typeof v === "string" && NUMERIC.test(v)) return checkRange(s, Number(v), ctx, at, type);
        warn("must be a number: other values are ignored.", "Pass a JSON number.");
        return;
      case "num":
      case "int":
        if (typeof v !== "number") {
          err(`must be a JSON number${typeof v === "string" ? " (a numeric string throws: the builder casts it)" : ""}.`, `Write ${at}: ${NUMERIC.test(String(v)) ? Number(v) : 1}.`);
          return;
        }
        if (s.type === "int" && !Number.isInteger(v)) warn("must be a whole number (it is truncated).");
        return checkRange(s, v, ctx, at, type);
      case "bool":
        if (typeof v !== "boolean") err("must be true or false (the builder casts it; \"true\" or 1 throws).", `Write ${at}: ${v === "true" || v === 1}.`);
        return;
      case "flag":
        if (typeof v !== "boolean" && v !== "true" && v !== "false") warn("should be true or false; other values are ignored.");
        return;
      case "enum":
        if (typeof v !== "string") {
          if (s.strict) err(`must be a string (the builder casts it; anything else throws). One of ${s.values.join(", ")}.`);
          else warn(`must be one of ${s.values.join(", ")}.`);
          return;
        }
        if (!s.values.includes(v)) warn(`unknown value, so the default is used.${didYouMean(v, s.values)}`, `One of ${s.values.join(", ")}.`, "prop-enum");
        return;
      case "icon":
        if (typeof v !== "string") return err("an icon is a Material icon name string.");
        if (!iconKnown(v)) warn(`not an icon the client draws (it shows a placeholder).${didYouMean(v.toLowerCase(), [...ICONS])}`, "Use a Material Symbols name from icons.json (snake_case), e.g. home, search, add, insights, payments.", "icon-unknown");
        else if (design && EMOJI.test(v)) warn("is an emoji, not an icon name.", "Use a Material icon name.", "design-emoji-icon");
        return;
      case "color":
        if (!(cssColor(v) || kitColor(v))) warn("not a color this node reads: it is ignored.", "Use #RRGGBB, or a theme/status name (primary, muted, good, warning, critical).");
        return;
      case "format":
        if (typeof v !== "string" || !FORMAT.test(v)) warn("not a value format.", "number[:decimals], integer, compact, percent[:decimals] (fractions), currency[:CODE[:decimals]], date, time, datetime; a leading + signs positives.");
        return;
      case "field":
        if (typeof v !== "string") err("a field name is a string.");
        return;
      case "rows":
        if (!Array.isArray(v)) err("must be an array of rows (objects) or numbers.");
        else if (v.length > 5000) add("warning", "perf-large-data", ctx, `${at} has ${v.length} rows: drawing that many is slow on phones.`, "Page, aggregate or limit the rows on your server.");
        return;
      case "object":
        if (!isObj(v)) err("must be an object.");
        return;
      case "array":
        if (!Array.isArray(v)) return err("must be an array.");
        if (s.min !== undefined && v.length < s.min) warn(`needs at least ${s.min} items (it draws nothing with fewer).`);
        if (s.max !== undefined && v.length > s.max) warn(`takes at most ${s.max} items.`);
        if (s.of) {
          v.forEach((item, i) => {
            if (isScalar(item) && s.scalars) return;
            if (!isObj(item)) return warn(`item ${i} must be an object of ${Object.keys(s.of).join(", ")}.`);
            for (const [f, fv] of Object.entries(item)) {
              if (fv === null || fv === undefined) continue;
              if (!s.of[f]) add("warning", "prop-unknown", ctx, `${at}[${i}].${f} is not read.${didYouMean(f, Object.keys(s.of))}`);
              else checkValue(s.of[f], fv, ctx, `${at}[${i}].${f}`, type);
            }
          });
        }
        return;
      default:
        return;
    }
  }

  function checkRange(s, v, ctx, at, type) {
    const prop = at.split(".").pop();
    if (type === "Opacity" && prop === "opacity" && (v < 0 || v > 1)) add("error", "prop-range", ctx, `${at} = ${v}: opacity must be 0..1 (out of range throws).`);
    if (["Expanded", "Flexible", "Spacer"].includes(type) && prop === "flex" && v < 1) add("warning", "prop-range", ctx, `${at} = ${v}: with a flex below 1 the ${type} does not fill anything.`, "Use flex ≥ 1, or drop the wrapper.");
    if (type === "AspectRatio" && prop === "aspectRatio" && v <= 0) add("error", "prop-range", ctx, `${at} = ${v}: the aspect ratio must be positive.`);
    if (type === "GridView" && prop === "crossAxisCount" && v < 1) add("error", "prop-range", ctx, `${at} = ${v}: needs at least one column.`);
  }

  function iconKnown(name) {
    const snake = String(name).trim().replace(/(?<=[a-z0-9])[A-Z]/g, (m) => "_" + m).replace(/[\s-]+/g, "_").toLowerCase();
    return ICONS.has(snake) || ICONS.has(snake.replace(/_(rounded|outlined|outline|sharp|filled)$/, ""));
  }

  // Data fields named by props must exist on the rows.
  function checkFields(type, props, ctx) {
    const rows = Array.isArray(props.data) ? props.data.filter(isObj) : [];
    if (!rows.length) return;
    const has = (f) => rows.slice(0, 20).some((r) => f.split(".").reduce((o, k) => (isObj(o) ? o[k] : undefined), r) !== undefined);
    const keysOf = Object.keys(rows[0]).slice(0, 12).join(", ");
    const check = (f, at) => {
      if (typeof f === "string" && f && !has(f)) add("warning", "field-missing", ctx, `${at} names field "${f}", which the data rows do not have (they have: ${keysOf}).`, "Name a field of each row, or reshape the rows on your server.");
    };
    for (const f of ["x", "y", "open", "high", "low", "close", "titleField", "descriptionField", "timeField"]) if (props[f] !== undefined) check(props[f], `props.${f}`);
    if (type === "Chart" && ["pie", "donut"].includes(props.type)) {
      check(props.label || "label", "props.label");
      check(props.value || "value", "props.value");
    }
    if (type === "Treemap") {
      check(props.label || "label", "props.label");
      check(props.value || "value", "props.value");
    }
    if (Array.isArray(props.series)) props.series.forEach((s, i) => check(typeof s === "string" ? s : s && s.field, `props.series[${i}]`));
    if (type === "DataGrid" && Array.isArray(props.columns)) props.columns.forEach((c, i) => isObj(c) && check(c.field, `props.columns[${i}].field`));
  }

  // --- nodes ------------------------------------------------------------------
  // box: whether the node's incoming width/height is bounded (true), unbounded
  // (false) or unknown (null: under nodes whose layout is not modelled).
  function walk(node, ctx) {
    const { parentType } = ctx;
    if (node === null || node === undefined || node === false || typeof node !== "object" || Array.isArray(node)) {
      add("error", "child-not-node", ctx, `${ctx.path} is ${show(node)}, not a node object: the engine throws on it.`,
        Array.isArray(node) ? "Spread nested arrays into children." : "Filter null/false/strings out of children (a string must be a Text node).");
      return;
    }
    stats.nodes++;
    stats.depth = Math.max(stats.depth, ctx.depth);
    const type = node.type;
    ctx.type = typeof type === "string" ? type : "?";
    if (typeof type !== "string" || !type) {
      add("error", "type-missing", ctx, `a node needs a string \`type\`; got ${show(type)}.`, `e.g. { type: "Text", props: { text: "Hi" } }.`);
      return;
    }
    stats.types[type] = (stats.types[type] || 0) + 1;
    const html = HTML.has(type);
    const spec = resolveType(type);
    if (!spec && !html) {
      add("error", "type-unknown", ctx, `"${type}" is not a node type the engine draws (it shows a red "Unknown widget" box).${didYouMean(type, ALL_TYPES)}`, "See nodes.json / `validate.mjs --list`.");
      return;
    }

    // Shape: only these keys belong on a node.
    for (const k of Object.keys(node)) {
      if (["type", "props", "children", "events", "key", "style"].includes(k)) continue;
      if (k === "child") add("error", "shape-child", ctx, "`child` is not read: children are a list.", "Write children: [ … ].");
      else if (/^on[A-Z]/.test(k)) add("error", "shape-handler", ctx, `\`${k}\` is not read: events are declared in \`events\`, by name.`, `Write events: { ${k.slice(2).toLowerCase()}: "handlerName" } (a global function, or app.handler(key, fn)).`);
      else if (spec && (spec.props || {})[k] !== undefined) add("error", "shape-prop", ctx, `\`${k}\` must be inside props.`, `Write props: { ${k}: ${show(node[k])} }.`);
      else add("warning", "shape-unknown", ctx, `top-level \`${k}\` is not read.`, "Only type, props, children, events, key and style belong on a node.");
    }
    if (node.props !== undefined && !isObj(node.props)) add("error", "props-not-object", ctx, `props must be an object, not ${show(node.props)}.`);
    const props = isObj(node.props) ? node.props : {};

    // Keys: event dispatch is by key, siblings must differ.
    if (node.key !== undefined && node.key !== null) {
      if (typeof node.key !== "string") add("error", "key-type", ctx, `key must be a string (the engine casts it); got ${show(node.key)}.`, `Write key: "${node.key}".`);
      else {
        if (!keys.has(node.key)) keys.set(node.key, []);
        keys.get(node.key).push({ ctx: { ...ctx }, events: isObj(node.events) && Object.keys(node.events).length > 0 });
      }
    }

    // Style (top-level style is accepted and moved into props).
    checkStyle(props.style !== undefined ? props.style : node.style, ctx);
    const style = isObj(props.style) ? props.style : isObj(node.style) ? node.style : {};

    // Props.
    if (html) {
      if (design) add("info", "design-html", ctx, `"${type}" is an HTML-named node: it renders, but does not get the Material 3 Expressive look.`, "Use the Flutter/M3E nodes (Column, Text with variant, Button, Card, ListTile, …).");
    } else {
      const known = { ...COMMON_PROPS, ...(spec.props || {}) };
      for (const [k, v] of Object.entries(props)) {
        if (v === undefined || v === null) continue;
        if (k === "style" || k === "className" || k === "class") continue;
        if (!known[k]) {
          if (/^on[A-Z]/.test(k)) add("error", "prop-handler", ctx, `props.${k} is not read: events are declared in \`events\`.`, `Write events: { ${k.slice(2).toLowerCase()}: "handlerName" }.`);
          else if (k === "child" || k === "children") add("error", "prop-children", ctx, `props.${k} is not read: children are the node's \`children\` list.`, "Move them to children: [ … ].");
          else add("warning", "prop-unknown", ctx, `props.${k} is not a prop of ${type}: it is ignored.${didYouMean(k, Object.keys(known))}`, spec.props ? `${type} takes: ${Object.keys(spec.props).join(", ")}.` : `${type} takes no props of its own (style only).`);
          continue;
        }
        checkValue(known[k], v, ctx, `props.${k}`, type);
      }
      for (const req of spec.requires || []) {
        const any = req.split("|");
        if (!any.some((k) => props[k] !== undefined && props[k] !== null && props[k] !== "")) {
          add("warning", "prop-missing", ctx, `${type} without ${any.map((k) => "`" + k + "`").join(" or ")} draws ${type === "Text" ? "nothing" : "empty or a placeholder"}.`);
        }
      }
      checkFields(type, props, ctx);
      checkSemantics(type, spec, props, style, node, ctx);
    }

    // Events.
    if (node.events !== undefined && node.events !== null) {
      if (!isObj(node.events)) add("error", "events-not-object", ctx, `events must be an object of {event: "handlerName"}, not ${show(node.events)}.`);
      else {
        const allowed = html ? null : new Set(spec.selfEvents || [...(spec.events || []), ...GESTURE_EVENTS]);
        for (const [ev, h] of Object.entries(node.events)) {
          if (typeof h !== "string" || !h) add("error", "event-handler", ctx, `events.${ev} must name a global function (a string); got ${show(h)}. Functions do not cross into the view tree.`, `Write events: { ${ev}: app.handler("${ev}", fn) }.`);
          if (allowed && !allowed.has(ev)) add("warning", "event-unknown", ctx, `${type} never fires "${ev}".${didYouMean(ev, [...allowed])}`, `${type} fires: ${[...allowed].slice(0, 10).join(", ")}${allowed.size > 10 ? ", …" : ""}.`);
        }
        if (mode === "widget" && Object.keys(node.events).length) add("error", "widget-events", ctx, "the phone widget takes no interaction: a tap opens the app.", "Remove events from the widget view.");
      }
    }
    if (!html && spec.needsKey && (node.key === undefined || node.key === null) && isObj(node.events) && Object.keys(node.events).length) {
      add("warning", "key-missing", ctx, `an interactive ${type} without a stable key loses focus/state when the view re-renders.`, `Give it key: "${type.toLowerCase()}-<what it edits>".`);
    }

    // Parent relations.
    if (!html && spec.parents && !spec.parents.includes(parentType)) {
      add("error", "parent-invalid", ctx, `${type} must be a direct child of ${spec.parents.join(" or ")}, but its parent is ${parentType || "the root"} (Flutter throws "Incorrect use of ParentDataWidget").`,
        spec.flexChild ? `Put the ${type} directly in a Row or Column, or drop it.` : `Put the ${type} directly in a Stack.`);
    }
    if (!html && (spec.flexChild || (spec.parents && spec.parents.includes("Stack"))) && isObj(node.events) && Object.keys(node.events).length) {
      add("error", "parent-data-events", ctx, `events on a ${type} wrap it in a gesture detector, which separates it from its ${spec.parents.join("/")} (Flutter throws "Incorrect use of ParentDataWidget").`, `Put the events on the ${type}'s child.`);
    }
    if (!html && spec.flexChild && parentType && ["Row", "Column"].includes(parentType) && ctx.parentWraps) {
      add("error", "flex-in-wrap", ctx, `${type} in a ${parentType} with style.flexWrap "wrap" (a Wrap) throws "Incorrect use of ParentDataWidget".`, "Remove flexWrap, or remove the Expanded.");
    }
    if (!html && spec.scaffoldSlot && !ctx.inScaffold && design) {
      add("info", "design-scaffold-slot", ctx, `${type} outside a Scaffold draws inline, not in its app position.`, `Make the screen a Scaffold with the ${type} as a child.`);
    }
    if (type === "Scaffold" && ctx.inScaffold) add("warning", "scaffold-nested", ctx, "a Scaffold inside a Scaffold: the inner one fights for the same app chrome.", "Keep one Scaffold per screen.");
    if (ctx.parentSpec && ctx.parentSpec.childTypes && !ctx.parentSpec.childTypes.includes(type) && design) {
      add("info", "child-type", ctx, `${parentType} is made for ${ctx.parentSpec.childTypes.join("/")} children; a ${type} there loses the grouped look.`);
    }

    // Layout: what throws in an unbounded box.
    const box = ctx.box;
    const own = (v) => v !== undefined && v !== null && v !== "" && v !== "auto";
    if (!html && spec.needsWidth && box.w === false && !own(style.width) && !own(style.maxWidth)) {
      add("error", "layout-unbounded-width", ctx, `${type} has no width bound here (${ctx.whyW}) — Flutter throws ("${type === "TextField" ? "InputDecorator cannot have an unbounded width" : "BoxConstraints forces an infinite width"}").`,
        `Wrap it in Expanded (inside the Row), or give it/its parent a style.width.`);
    }
    if (!html && spec.needsHeight && box.h === false && !own(style.height) && !own(style.maxHeight)) {
      add("error", "layout-unbounded-height", ctx, `${type} has no height bound here (${ctx.whyH}) — Flutter throws.`, `Do not put a ${type} inside a scrolling list${type === "Scaffold" ? "; make the Scaffold the screen's root" : ", or give it a style.height"}.`);
    }
    if (!html && spec.flexChild && ["Row", "Column"].includes(parentType)) {
      const main = parentType === "Row" ? "w" : "h";
      // A flex child's own box is its Row/Column's (see childBox).
      if (box[main] === false) {
        add("error", "layout-flex-unbounded", ctx, `${type} in a ${parentType} that has no ${main === "w" ? "width" : "height"} bound (${main === "w" ? ctx.whyW : ctx.whyH}) — Flutter throws "RenderFlex children have non-zero flex but incoming ${main === "w" ? "width" : "height"} constraints are unbounded".`,
          main === "h" ? "Inside a scrolling list there is no free height to fill: remove the Expanded/Spacer, or give the Column a style.height." : `Wrap the ${parentType} in Expanded (in its own Row), or give it a style.width.`);
      }
    }

    // Children.
    const children = node.children;
    if (children !== undefined && children !== null && !Array.isArray(children)) {
      add("error", "children-not-array", ctx, `children must be an array, not ${show(children)}.`, "Write children: [ … ].");
      return;
    }
    const list = Array.isArray(children) ? children : [];
    if (!html) {
      if (spec.children === "none" && list.length) add("warning", "children-ignored", ctx, `${type} draws no children: ${list.length} ignored.`, type === "Text" ? "Put the words in props.text; compose texts in a Row/Column." : `Wrap ${type} and the others in a Row/Column.`);
      if (spec.children === "one" && list.length > 1) add("warning", "children-dropped", ctx, `${type} draws only its first child: ${list.length - 1} more dropped.`, "Wrap them in a Column or Row.");
      if (spec.children === "slots") {
        for (const [i, c] of list.entries()) {
          const slot = isObj(c) && isObj(c.props) ? c.props.slot : undefined;
          if (slot !== undefined && !spec.slots.includes(slot)) add("warning", "slot-unknown", { ...ctx, path: `${ctx.path}.children[${i}]` }, `slot "${slot}" is not a slot of ${type}.${didYouMean(String(slot), spec.slots)}`, `${type} slots: ${spec.slots.join(", ")}.`);
        }
      }
    }
    // Sibling keys must be unique (Flutter throws on duplicate keys).
    const seen = new Map();
    list.forEach((c, i) => {
      if (isObj(c) && typeof c.key === "string") {
        if (seen.has(c.key)) add("error", "key-duplicate-sibling", { ...ctx, path: `${ctx.path}.children[${i}]` }, `two children of this ${type} share key "${c.key}" (children ${seen.get(c.key)} and ${i}): Flutter throws on duplicate keys.`, "Make keys unique, e.g. append the item id.");
        else seen.set(c.key, i);
      }
    });
    if (design) designLint(type, spec, props, style, node, list, ctx);
    if (list.length > 400) add("warning", "perf-many-children", ctx, `${list.length} children drawn at once: slow on phones.`, "Page or virtualize long lists (show the first 50–100, load more on demand).");

    const wraps = typeof style.flexWrap === "string" && style.flexWrap.startsWith("wrap");
    list.forEach((c, i) => {
      const childType = isObj(c) ? c.type : undefined;
      const cb = childBox(type, spec, style, props, box, ctx, childType, wraps);
      const label = isObj(c) && typeof c.type === "string" ? c.type + (typeof c.key === "string" ? `#${c.key}` : "") : "?";
      walk(c, {
        path: `${ctx.path}.children[${i}]`,
        at: `${ctx.at} > ${label}`,
        depth: ctx.depth + 1,
        parentType: type,
        parentSpec: spec,
        parentWraps: wraps,
        parentBox: box,
        parentWhyW: ctx.whyW,
        parentWhyH: ctx.whyH,
        box: { w: cb.w, h: cb.h },
        whyW: cb.whyW,
        whyH: cb.whyH,
        inScaffold: ctx.inScaffold || type === "Scaffold",
        inCard: ctx.inCard || type === "Card",
      });
    });
  }

  // The constraints a child of [type] gets.
  function childBox(type, spec, style, props, box, ctx, childType, wraps) {
    let w = box.w, h = box.h, whyW = ctx.whyW, whyH = ctx.whyH;
    const sized = (v) => v !== undefined && v !== null && v !== "auto" && v !== "";
    if (sized(style.width) || sized(style.maxWidth) || (type === "Container" && sized(props.width))) { w = true; whyW = ""; }
    if (sized(style.height) || sized(style.maxHeight) || (type === "Container" && sized(props.height))) { h = true; whyH = ""; }
    const html = HTML.has(type);
    if (html || !spec) return { w: null, h: null, whyW: "", whyH: "" };
    const flex = childType && resolveType(childType) && resolveType(childType).flexChild;
    switch (type) {
      case "Row":
        if (wraps) return { w, h: false, whyW, whyH: "a wrapping Row" };
        if (flex) return { w, h, whyW, whyH };
        return { w: false, h, whyW: "it is directly in a Row, which lets children be as wide as they like", whyH };
      case "Column":
        if (wraps) return { w: false, h, whyW: "a wrapping Column", whyH };
        if (flex) return { w, h, whyW, whyH };
        return { w, h: false, whyW, whyH: "it is in a Column, whose children may be as tall as they like" };
      case "ListView":
        if (props.scrollDirection === "horizontal") return { w: false, h, whyW: "it is in a horizontal ListView", whyH };
        return { w, h: false, whyW, whyH: "it is in a ListView (a vertical scroll)" };
      case "GridView":
        return { w: true, h: true, whyW: "", whyH: "" };
      case "Scroll":
        if (props.direction === "horizontal") return { w: false, h, whyW: "it is in a horizontal Scroll", whyH };
        return { w, h: false, whyW, whyH: "it is in a Scroll" };
      case "Wrap":
        return { w, h: false, whyW, whyH: "it is in a Wrap" };
      case "ResponsiveGrid":
        return { w: true, h: false, whyW: "", whyH: "it is in a ResponsiveGrid cell" };
      case "Scaffold":
        return { w: true, h: true, whyW: "", whyH: "" };
      case "FittedBox":
      case "OverflowBox":
        return { w: false, h: false, whyW: `it is in a ${type}, which lets its child be any size`, whyH: `it is in a ${type}` };
      case "Expanded":
      case "Flexible":
        return { w: ctx.parentType === "Row" ? true : w, h: ctx.parentType === "Column" ? true : h, whyW, whyH };
      case "Card":
      case "ListGroup":
      case "Section":
      case "Expandable":
      case "Callout":
      case "Drawer":
      case "StaggeredAnimation":
        return { w, h: false, whyW, whyH: `it is in a ${type}, which stacks its children in a column` };
      case "AppBar":
      case "ListTile":
      case "Button":
      case "IconButton":
      case "FAB":
      case "FloatingActionButton":
      case "Dismissible":
      case "Draggable":
      case "Badge":
        return { w: null, h: null, whyW: "", whyH: "" };
      default:
        return { w, h, whyW, whyH };
    }
  }

  // Values that are valid in isolation but wrong for the node.
  function checkSemantics(type, spec, props, style, node, ctx) {
    if (type === "SegmentedButton") {
      const segs = (props.segments || props.items || []).map((s) => String(isObj(s) ? (s.value ?? s.label) : s));
      const sel = props.selected ?? props.value;
      const selList = sel === undefined || sel === null ? [] : Array.isArray(sel) ? sel.map(String) : [String(sel)];
      for (const v of selList) if (segs.length && !segs.includes(v)) add("warning", "prop-value", ctx, `selected "${v}" is not one of the segments' values (${segs.join(", ")}).`);
      if (segs.length > 5) add("info", "design-segments", ctx, `${segs.length} segments are too many for a connected group.`, "Use Chips with `selected` in a Wrap for many options.");
      if (Array.isArray(sel) && props.multi !== true) add("warning", "prop-value", ctx, "selected is a list but multi is not true.");
    }
    if (type === "NavigationBar") {
      const items = props.items || props.destinations || [];
      const sel = Number(props.selected ?? props.value ?? 0);
      if (Array.isArray(items) && items.length && (sel < 0 || sel >= items.length)) add("warning", "prop-value", ctx, `selected ${sel} is out of range (0..${items.length - 1}).`);
    }
    if (type === "IndexedStack") {
      const n = Array.isArray(node.children) ? node.children.length : 0;
      if (typeof props.index === "number" && (props.index < 0 || props.index >= n)) add("warning", "prop-value", ctx, `index ${props.index} is out of range (${n} children): nothing shows.`);
    }
    if (type === "Slider") {
      const min = Number(props.min ?? 0), max = Number(props.max ?? 1), v = Number(props.value ?? min);
      if (max <= min) add("error", "prop-value", ctx, `max (${max}) must be greater than min (${min}).`);
      else if (v < min || v > max) add("warning", "prop-value", ctx, `value ${v} is outside ${min}..${max} (it is clamped).`, "With no min/max the range is 0..1.");
    }
    if (type === "Image" && typeof props.src === "string" && !/^(https?:|data:|\/|[\w.-]+\/|[\w.-]+\.(png|jpe?g|gif|webp|svg))/i.test(props.src)) {
      add("warning", "prop-value", ctx, `src ${show(props.src)} is not a URL, a /v1/files/ path, a project file path or a data URI.`);
    }
    if (type === "AnimatedSwitcher" && Array.isArray(node.children) && node.children[0] && isObj(node.children[0]) && node.children[0].key === undefined) {
      add("info", "animation-key", ctx, "AnimatedSwitcher animates only when its child's key changes; this child has no key.", "Give the child a key that changes with the content (e.g. the filter or screen name).");
    }
    if (type === "Text" && typeof (props.text ?? props.data) === "string" && /\{\{\s*\w+\s*\}\}|\$\{\w+\}|undefined|NaN|\[object Object\]/.test(props.text ?? props.data)) {
      add("warning", "text-placeholder", ctx, `the text ${show(props.text ?? props.data)} looks like an unfilled template or a bad value.`, "Build the string in JS before rendering; guard undefined values.");
    }
  }

  function designLint(type, spec, props, style, node, list, ctx) {
    if (type === "Text" && !props.variant && (style.fontSize !== undefined || style.fontWeight !== undefined) && !props.color) {
      add("info", "design-type-role", ctx, "a Text sized/weighted by style instead of an M3 type role.", 'Use variant: "titleMediumEmphasized", "bodyMedium", "headlineSmall", … (style only for figures).');
    }
    const label = (props.text ?? props.label);
    if (["Button", "Chip", "Tag"].includes(type) && typeof label === "string" && (EMOJI.test(label) || GLYPH_ONLY.test(label))) {
      add("warning", "design-emoji-icon", ctx, `the ${type} label ${show(label)} uses an emoji or glyph as an icon.`, 'Use the `icon` prop with a Material icon name (e.g. icon: "add").');
    }
    if (type === "Text" && typeof props.text === "string" && GLYPH_ONLY.test(props.text)) {
      add("info", "design-emoji-icon", ctx, `a Text ${show(props.text)} used as an icon.`, "Use an Icon node.");
    }
    if (type === "IconButton" && !props.tooltip) add("info", "a11y-tooltip", ctx, "an IconButton without a tooltip has no accessible name.", 'Add tooltip: "<what it does>".');
    if (type === "Image" && props.alt === undefined) add("info", "a11y-alt", ctx, "an Image without alt text.", 'Add alt: "<what it shows>".');
    if (type === "Card" && ctx.inCard) add("info", "design-nested-card", ctx, "a Card inside a Card: nested surfaces look heavy.", "Use spacing, a Divider, or a tonal Container inside instead.");
    const filled = list.filter((c) => isObj(c) && c.type === "Button" && isObj(c.props) && (c.props.variant === undefined || c.props.variant === "filled") && c.props.selected === undefined && !c.props.className);
    if (filled.length > 1 && ["Row", "Wrap"].includes(type)) add("info", "design-filled-buttons", ctx, `${filled.length} filled Buttons side by side compete for attention.`, "Keep one filled (the main action); make the others tonal, outlined or text.");
    if (type === "Container" && style.border !== undefined && style.boxShadow !== undefined) add("info", "design-border-shadow", ctx, "a border and a shadow together.", "M3 Expressive separates with tonal surfaces: drop both and use a filled Card or surfaceContainer color.");
  }

  // Run.
  const roots = Array.isArray(tree) ? tree : [tree];
  roots.forEach((root, i) => {
    const label = isObj(root) && typeof root.type === "string" ? root.type : "?";
    const rootBox = opts.root === "scroll" ? { w: true, h: false } : { w: true, h: true };
    walk(root, {
      path: roots.length > 1 ? `$[${i}]` : "$",
      at: label,
      depth: 1,
      parentType: null,
      parentSpec: null,
      parentBox: rootBox,
      box: rootBox,
      whyW: "",
      whyH: opts.root === "scroll" ? "the root scrolls" : "",
      inScaffold: false,
      inCard: false,
    });
  });

  // Keys across the tree: events are dispatched by key.
  for (const [key, uses] of keys) {
    if (uses.length < 2) continue;
    const withEvents = uses.filter((u) => u.events);
    const ctx = uses[1].ctx;
    if (withEvents.length) add("error", "key-duplicate", ctx, `key "${key}" is used by ${uses.length} nodes (${uses.map((u) => u.ctx.at.split(" > ").pop()).join(", ")}): events are dispatched by key, so a tap on one can run another's handler.`, "Give every node a unique key (append the item id).");
    else add("warning", "key-duplicate", ctx, `key "${key}" is used by ${uses.length} nodes: state (focus, scroll, animations) may jump between them.`, "Give every node a unique key.");
  }

  // Phone widget.
  if (mode === "widget") {
    for (const [t, n] of Object.entries(stats.types)) {
      if (NOT_IN_WIDGET.includes(t)) issues.push({ severity: "error", code: "widget-node", path: "$", at: t, type: t, message: `the phone widget uses ${t} (${n}×): widgets are glanceable — no tables, lists, inputs or app chrome.`, fix: "Show one key value (Stat) and at most two supporting facts (Tag, Sparkline, Progress, Gauge, short Text)." });
    }
    if (stats.nodes > WIDGET_MAX_NODES) issues.push({ severity: "error", code: "widget-size", path: "$", at: "", type: "", message: `the phone widget draws ${stats.nodes} nodes (max ${WIDGET_MAX_NODES}).`, fix: "Show less: one value and a fact or trend." });
  }
  if (stats.nodes > 3000) issues.push({ severity: "warning", code: "perf-tree-size", path: "$", at: "", type: "", message: `the tree has ${stats.nodes} nodes: rebuilding it on every change is slow on phones.`, fix: "Page long lists, collapse sections, draw summaries." });
  if (stats.depth > 60) issues.push({ severity: "warning", code: "perf-depth", path: "$", at: "", type: "", message: `the tree is ${stats.depth} levels deep.`, fix: "Flatten wrappers: style padding/margin/background on the node itself instead of extra Container/Padding layers." });

  const count = (s) => issues.filter((i) => i.severity === s).length;
  return { ok: count("error") === 0, errors: count("error"), warnings: count("warning"), infos: count("info"), issues, stats };
}

// Validates every render a program made (check.mjs collects them).
export function validateRenders(renders, opts = {}) {
  const seen = new Set();
  const issues = [];
  let nodes = 0;
  for (const tree of renders) {
    const r = validate(tree, opts);
    nodes = Math.max(nodes, r.stats.nodes);
    for (const i of r.issues) {
      const id = `${i.code}|${i.path}|${i.message}`;
      if (seen.has(id)) continue;
      seen.add(id);
      issues.push(i);
    }
  }
  const count = (s) => issues.filter((i) => i.severity === s).length;
  return { ok: count("error") === 0, errors: count("error"), warnings: count("warning"), infos: count("info"), issues, stats: { renders: renders.length, nodes } };
}

// ── describing the schema ────────────────────────────────────────────────────

function specText(v) {
  const s = typeof v === "string" ? { type: v } : v;
  if (s.type === "enum") return s.values.slice(0, 12).join(" | ") + (s.values.length > 12 ? " | …" : "");
  if (s.type === "array" && s.of) return `[{${Object.keys(s.of).join(", ")}}]`;
  return s.type;
}

export function describe(type) {
  const spec = resolveType(type);
  if (!spec) {
    if (HTML.has(type)) return `${type}: ${HTML_DOC}`;
    return `Unknown node type "${type}".${didYouMean(type, ALL_TYPES)}`;
  }
  const lines = [`${type} — ${spec.summary || ""} [${spec.category}]`];
  lines.push(`  children: ${spec.children}${spec.slots ? ` (slots: ${spec.slots.join(", ")})` : ""}${spec.childTypes ? ` (made for ${spec.childTypes.join("/")})` : ""}`);
  if (spec.parents) lines.push(`  must be a direct child of: ${spec.parents.join(" or ")}`);
  const layout = [spec.needsWidth && "needs a bounded width (wrap in Expanded inside a Row)", spec.needsHeight && "needs a bounded height (not inside a scroll)"].filter(Boolean);
  if (layout.length) lines.push(`  layout: ${layout.join("; ")}`);
  const props = spec.props || {};
  if (Object.keys(props).length) {
    lines.push("  props:");
    for (const [k, v] of Object.entries(props)) lines.push(`    ${k}: ${specText(v)}${v.doc ? ` — ${v.doc}` : ""}`);
  } else lines.push("  props: none of its own (style only)");
  if (spec.requires) lines.push(`  needs: ${spec.requires.map((r) => r.split("|").join(" or ")).join("; ")}`);
  lines.push(`  events: ${(spec.selfEvents || [...(spec.events || []), "tap", "longpress", "doubletap", "… (gestures)"]).join(", ")}`);
  if (spec.needsKey) lines.push("  give it a stable key (it keeps focus/state across renders)");
  return lines.join("\n");
}

export function listTypes() {
  const by = {};
  for (const [t, s] of Object.entries(TYPES)) (by[s.category] = by[s.category] || []).push(t);
  return Object.entries(by).map(([c, ts]) => `${c}: ${ts.sort().join(", ")}`).join("\n") + `\nhtml (avoid): ${NODES.html.join(", ")}`;
}

// ── reporting ────────────────────────────────────────────────────────────────

export function format(report, { quiet = false } = {}) {
  const order = { error: 0, warning: 1, info: 2 };
  const shown = report.issues.filter((i) => !quiet || i.severity === "error").sort((a, b) => order[a.severity] - order[b.severity]);
  const lines = [];
  for (const i of shown) {
    lines.push(`${i.severity.toUpperCase()} [${i.code}] ${i.at || i.path}`);
    lines.push(`  ${i.message}`);
    if (i.fix) lines.push(`  fix: ${i.fix}`);
    if (i.path && i.at) lines.push(`  at: ${i.path}`);
  }
  const s = report.stats || {};
  lines.push(`${report.ok ? "VALID" : "INVALID"}: ${report.errors} error(s), ${report.warnings} warning(s), ${report.infos} note(s)` +
    (s.nodes !== undefined ? ` · ${s.renders !== undefined ? `${s.renders} render(s), up to ` : ""}${s.nodes} nodes${s.depth ? `, depth ${s.depth}` : ""}` : ""));
  return lines.join("\n");
}

// Renders an OpenUI tree to Elpian nodes (with the kit's renderer).
export async function fromOpenUI(tree) {
  const vm = await import("node:vm");
  const ctx = { console };
  ctx.globalThis = ctx;
  ctx.askHost = () => JSON.stringify({ type: "object", data: { value: {} } });
  vm.createContext(ctx);
  for (const f of ["aseman-elpian.js", "openui-elpian.js"]) vm.runInContext(fs.readFileSync(path.join(here, f), "utf8"), ctx);
  return JSON.parse(JSON.stringify(ctx.OpenUI.render(tree)));
}

// Runs a program (check.mjs) and validates each render, as the app and as
// its phone widget.
export async function validateProgram(source, opts = {}) {
  const { check } = await import("./check.mjs");
  const out = [];
  for (const display of opts.widgetOnly ? ["compact"] : ["full", "compact"]) {
    const run = await check(source, { ...opts, widget: false, widgetOnly: display === "compact", collect: true, validate: false });
    const report = validateRenders(run.trees || [], { mode: display === "compact" ? "widget" : "app", design: opts.design, theme: run.theme });
    out.push({ display, run, report });
  }
  return out;
}

// ── CLI ──────────────────────────────────────────────────────────────────────

async function main(argv) {
  const flag = (n) => argv.includes(n);
  const val = (n) => (argv.includes(n) ? argv[argv.indexOf(n) + 1] : undefined);
  const json = flag("--json");
  const opts = { design: !flag("--no-design"), mode: flag("--widget") ? "widget" : "app" };
  if (flag("--list")) return console.log(listTypes()), 0;
  if (val("--describe")) return console.log(val("--describe").split(",").map(describe).join("\n\n")), 0;
  const fail = (r) => (r.errors > 0 || (flag("--strict") && r.warnings > 0) ? 1 : 0);

  if (val("--program")) {
    const source = fs.readFileSync(val("--program"), "utf8");
    const apps = val("--apps") ? JSON.parse(fs.readFileSync(val("--apps"), "utf8")) : null;
    const results = await validateProgram(source, { server: val("--server") || "", apps, design: opts.design, widgetOnly: flag("--widget-only") });
    let code = 0;
    const all = [];
    for (const { display, run, report } of results) {
      if (!run.trees || !run.trees.length) report.issues.unshift({ severity: "error", code: "no-render", path: "$", at: display, message: `the program never rendered as ${display === "compact" ? "the widget" : "the app"}${run.errors.length ? ": " + run.errors[0] : ""}.` }), report.errors++, report.ok = false;
      code = Math.max(code, fail(report));
      all.push({ display: display === "compact" ? "widget" : "app", ...report });
      if (!json) console.log(`── ${display === "compact" ? "as the phone widget" : "as the app"} ──\n${format(report, { quiet: flag("--quiet") })}\n`);
    }
    if (json) console.log(JSON.stringify(all, null, 1));
    return code;
  }

  const file = argv.find((a, i) => !a.startsWith("--") && !(i > 0 && ["--describe", "--program", "--server", "--apps"].includes(argv[i - 1])));
  if (!file) {
    console.error("usage: node validate.mjs <tree.json | -> [--widget] [--openui] [--json] [--strict] [--no-design]\n       node validate.mjs --program elpian/app.js [--server URL] [--apps APPS.json]\n       node validate.mjs --describe <Type> | --list");
    return 2;
  }
  let tree;
  try {
    tree = JSON.parse(file === "-" ? fs.readFileSync(0, "utf8") : fs.readFileSync(file, "utf8"));
  } catch (e) {
    console.error(`could not read a JSON tree from ${file}: ${e.message}`);
    return 2;
  }
  if (isObj(tree) && (tree.view || tree.tree) && !tree.type) tree = tree.view || tree.tree;
  if (flag("--openui")) tree = await fromOpenUI(tree);
  const report = validate(tree, opts);
  console.log(json ? JSON.stringify(report, null, 1) : format(report, { quiet: flag("--quiet") }));
  return fail(report);
}

if (import.meta.url === pathToFileURL(process.argv[1] || "").href) {
  main(process.argv.slice(2)).then((code) => process.exit(code), (e) => {
    console.error(e && e.stack ? e.stack : String(e));
    process.exit(2);
  });
}
