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
//   validate(tree, {mode: "app" | "widget", design: true, theme: {colors},
//                   viewport: {width, height}}) -> report
//   (viewport: the screen fixed layouts must fit; default a small phone, PHONE)

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import {
  TYPES, STYLE, COMMON_PROPS, GESTURE_EVENTS, CURVES, CSS_COLOR_NAMES, KIT_COLOR_NAMES,
  NOT_IN_WIDGET, WIDGET_MAX_NODES, HTML_DOC, CONTINUOUS_EVENTS, SWIPE_X, SWIPE_Y, TAP_CONTROLS, PHONE, SELF_GESTURING, WRAPPER_EVENTS, MOTION_EVENTS,
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
// Number props that are sizes (never negative) and list nodes whose `max` is
// how many rows to show.
const SIZE_PROPS = new Set(["width", "height", "size", "minHeight", "maxHeight", "minWidth", "maxWidth", "thickness", "elevation", "gap", "aspectRatio", "strokeWidth"]);
const COUNT_MAX = new Set(["Leaderboard", "WordCloud", "AvatarGroup", "Rating"]);
const LENGTH = /^\s*-?\d+(\.\d+)?\s*(px|%|vw|vh|vmin|vmax)?\s*$/;
const HEX = /^#([0-9a-f]{3}|[0-9a-f]{4}|[0-9a-f]{6}|[0-9a-f]{8})$/i;
const RGB = /^rgba?\(\s*\d+(\.\d+)?\s*,\s*\d+(\.\d+)?\s*,\s*\d+(\.\d+)?\s*(,\s*\d*(\.\d+)?\s*)?\)$/i;
const FORMAT = /^\+?(text|number(:\d+)?|integer|compact|percent(:\d+)?|currency(:[A-Za-z]{3}(:\d+)?)?|date|time|datetime)$/;
const EMOJI = /\p{Extended_Pictographic}/u;
// Glyphs standing in for an icon (operators such as + − × ÷ = on a keypad
// are labels, not icons).
const GLYPH_ONLY = /^\s*[✕✖✓✔›‹»«→←↑↓⋯…•·◀▶▲▼★☆⚙♥❤]\s*$/u;

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

const CONTINUOUS = new Set(CONTINUOUS_EVENTS);
const TAPS = new Set(["tap", "click", "doubletap", "longpress", "longpressstart", "tapdown", "tapup", "secondarytap", "contextmenu"]);

// ── the validator ────────────────────────────────────────────────────────────

export function validate(tree, opts = {}) {
  const mode = opts.mode || "app";
  const design = opts.design !== false;
  const themeHex = new Set(Object.values((opts.theme && opts.theme.colors) || {}).map((c) => String(c).toLowerCase()));
  const issues = [];
  const stats = { nodes: 0, depth: 0, types: {} };
  const keys = new Map(); // key -> [{at, events}]
  const tapHandlers = new Map(); // handler name -> label -> ctx

  function add(severity, code, ctx, message, fix) {
    issues.push({ severity, code, path: ctx.path, at: ctx.at, type: ctx.type, message, fix });
  }

  // --- styles -----------------------------------------------------------------
  function checkStyle(style, ctx, where = "style") {
    if (style === undefined || style === null) return;
    if (!isObj(style)) {
      add("warning", "style-not-object", ctx, `${where} must be an object of style keys; ${show(style)} (a CSS string) is ignored.`,
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
      if (typeof v !== "string") return bad(`must be a string (the current engine ignores anything else; older clients throw on it).`, `One of ${values.join(", ")}.`, "error");
      const norm = (s) => s.toLowerCase().replace(/-/g, "");
      if (!values.some((x) => norm(x) === norm(v))) bad(`not a value the engine knows, so it falls back to its default.${didYouMean(v, values)}`, `One of ${values.join(", ")}.`);
      return;
    }
    switch (kind) {
      case "string":
        if (typeof v !== "string") bad("must be a string (the current engine ignores anything else; older clients throw on it).", undefined, "error");
        return;
      case "bool":
        if (typeof v !== "boolean") bad("must be true or false (the current engine ignores anything else; older clients throw on it).", undefined, "error");
        return;
      case "length":
        if ((typeof v === "number" || (typeof v === "string" && /^\s*-\d/.test(v))) && parseFloat(v) < 0 && SIZE_PROPS.has(key)) {
          return bad("a size cannot be negative (the engine ignores it; older clients throw).", "Use 0 or more.", "error");
        }
        if (typeof v === "number") return;
        if (typeof v !== "string") return bad("must be a number or a length string.", 'e.g. 120, "120", "50%", "100vw"');
        if (v.trim() === "auto" || v.includes("calc(") || v.trim().startsWith("env(")) return;
        if (!LENGTH.test(v)) bad(`not a length the engine reads${/\d\s*(rem|em|pt|dp)\b/.test(v) ? " (rem/em/pt are not supported)" : ""}: it is ignored or misread.`, 'Use a number (logical px), "50%", or viewport units ("100vw").');
        return;
      case "number":
      case "int":
        if (typeof v === "number") {
          if (kind === "int" && !Number.isInteger(v)) bad("must be a whole number (it is truncated).");
          if (key === "opacity" && (v < 0 || v > 1)) bad("opacity must be between 0 and 1 (the engine clamps it; older clients throw).", undefined, "error");
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
            else if (Number(String(n).replace(/px$/, "")) < 0) bad("negative padding/margin is read as 0 (older clients throw).", "Use 0 or more.", "error");
          }
          return;
        }
        if (typeof v === "number") {
          if (v < 0) bad("negative padding/margin is read as 0 (older clients throw).", "Use 0 or more.", "error");
          return;
        }
        if (typeof v !== "string") return bad("must be a number, a string of 1–4 numbers, or {top, right, bottom, left}.");
        const parts = v.trim().split(/\s+/);
        if (parts.length > 4 || parts.some((p) => !/^-?\d+(\.\d+)?(px)?$/.test(p))) bad("must be 1–4 numbers (\"8\", \"8 16\", \"8 16 8 16\").", "Use plain numbers; units other than px are not read.");
        else if (parts.some((p) => parseFloat(p) < 0)) bad("negative padding/margin is read as 0 (older clients throw).", "Use 0 or more.", "error");
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
        if (typeof v !== "string") err("must be a string (the current engine ignores anything else; older clients throw on it).", `Write ${at}: ${show(String(v))}.`);
        return;
      case "number":
        if (typeof v === "number") return checkRange(s, v, ctx, at, type);
        if (typeof v === "string" && NUMERIC.test(v)) return checkRange(s, Number(v), ctx, at, type);
        warn("must be a number: other values are ignored.", "Pass a JSON number.");
        return;
      case "num":
      case "int":
        if (typeof v !== "number") {
          err(`must be a JSON number${typeof v === "string" ? " (older clients throw on a numeric string)" : ""}.`, `Write ${at}: ${NUMERIC.test(String(v)) ? Number(v) : 1}.`);
          return;
        }
        if (s.type === "int" && !Number.isInteger(v)) warn("must be a whole number (it is truncated).");
        return checkRange(s, v, ctx, at, type);
      case "bool":
        if (typeof v !== "boolean") err("must be true or false (\"true\" or 1 is read leniently now, but older clients throw on it).", `Write ${at}: ${v === "true" || v === 1}.`);
        return;
      case "flag":
        if (typeof v !== "boolean" && v !== "true" && v !== "false") warn("should be true or false; other values are ignored.");
        return;
      case "enum":
        if (typeof v !== "string") {
          if (s.strict) err(`must be a string (the current engine ignores anything else; older clients throw on it). One of ${s.values.join(", ")}.`);
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
    if (type === "Opacity" && prop === "opacity" && (v < 0 || v > 1)) add("error", "prop-range", ctx, `${at} = ${v}: opacity must be 0..1 (the engine clamps it; older clients throw).`);
    if (["Expanded", "Flexible", "Spacer"].includes(type) && prop === "flex" && v < 1) add("warning", "prop-range", ctx, `${at} = ${v}: with a flex below 1 the ${type} does not fill anything.`, "Use flex ≥ 1, or drop the wrapper.");
    if (type === "AspectRatio" && prop === "aspectRatio" && v <= 0) add("error", "prop-range", ctx, `${at} = ${v}: the aspect ratio must be positive.`);
    if (type === "GridView" && prop === "crossAxisCount" && v < 1) add("error", "prop-range", ctx, `${at} = ${v}: needs at least one column.`);
    if (SIZE_PROPS.has(prop) && v < 0) add("error", "prop-range", ctx, `${at} = ${v}: a size cannot be negative (the engine ignores it; older clients throw).`, "Use 0 or more, or leave it out for the default.");
    if (prop === "maxLines" && v < 1) add("warning", "prop-range", ctx, `${at} = ${v}: a line limit below 1 is ignored.`, "Use 1 or more, or leave it out.");
    if (prop === "max" && COUNT_MAX.has(type) && v < 0) add("warning", "prop-range", ctx, `${at} = ${v}: how many to show cannot be negative; the default is used.`);
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
    // The newer charts and tables: the fields they are told to read.
    const FIELD_PROPS = {
      Funnel: ["label", "value"], Waterfall: ["label", "value"], SegmentedBar: ["label", "value"], Gantt: ["label", "start", "end"], BoxPlot: ["label"],
      CalendarHeatmap: ["date", "value"], WordCloud: ["text", "label", "value"], Leaderboard: ["name", "label", "value"], PivotTable: ["value"],
    };
    for (const f of FIELD_PROPS[type] || []) if (typeof props[f] === "string") check(props[f], `props.${f}`);
    if (type === "PivotTable") for (const k of ["rows", "columns"]) for (const f of [].concat(props[k] || [])) check(String(f), `props.${k}`);
    if (type === "DataGrid" && Array.isArray(props.columns)) props.columns.forEach((c, i) => isObj(c) && check(c.field, `props.columns[${i}].field`));
  }

  // --- nodes ------------------------------------------------------------------
  // box: whether the node's incoming width/height is bounded (true), unbounded
  // (false) or unknown (null: under nodes whose layout is not modelled).
  function walk(node, ctx) {
    const { parentType } = ctx;
    // Holes the SDK and the engine skip (`cond && node`, `cond ? node : null`),
    // nested arrays they flatten, scalars they draw as plain Text.
    if (node === null || node === undefined || typeof node === "boolean") {
      add("info", "child-skipped", ctx, `${ctx.path} is ${show(node)}: skipped.`, "Fine for conditional children; filter them out to keep trees tidy.");
      return;
    }
    if (Array.isArray(node)) {
      add("info", "child-nested-array", ctx, `${ctx.path} is a nested array: its items are flattened into the parent's children.`);
      node.forEach((c, i) => walk(c, { ...ctx, path: `${ctx.path}[${i}]` }));
      return;
    }
    if (typeof node !== "object") {
      add("warning", "child-not-node", ctx, `${ctx.path} is ${show(node)}: drawn as plain Text with no type role.`, `Write { type: "Text", props: { text: ${show(String(node))}, variant: "bodyMedium" } }.`);
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
    if (node.props !== undefined && node.props !== null && !isObj(node.props)) add("warning", "props-not-object", ctx, `props must be an object; ${show(node.props)} is ignored, so the node draws with no props.`);
    const props = isObj(node.props) ? node.props : {};

    // Keys: event dispatch is by key, siblings must differ.
    if (node.key !== undefined && node.key !== null) {
      if (typeof node.key !== "string") add("warning", "key-type", ctx, `key should be a string; ${show(node.key)} is used as "${node.key}".`, `Write key: "${node.key}".`);
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
      if (!isObj(node.events)) add("warning", "events-not-object", ctx, `events must be an object of {event: "handlerName"}; ${show(node.events)} is ignored, so nothing responds.`);
      else {
        const allowed = html ? null : allowedEvents(type, spec);
        for (const [ev, h] of Object.entries(node.events)) {
          if (typeof h !== "string" || !h) add("error", "event-handler", ctx, `events.${ev} must name a global function (a string); got ${show(h)}. Functions do not cross into the view tree.`, `Write events: { ${ev}: app.handler("${ev}", fn) }.`);
          else {
            if (!/^[A-Za-z_$][\w$]*(\.[A-Za-z_$][\w$]*)*$/.test(h)) add("warning", "event-handler-name", ctx, `events.${ev} = ${show(h)} is not a JS identifier: older clients call handlers as code, so the tap does nothing there.`, "Use app.handler(key, fn), which makes a safe name, or a name of letters, digits, _ and $.");
            if (["tap", "click"].includes(ev)) {
              const label = String(props.text ?? props.label ?? props.title ?? props.icon ?? props.tooltip ?? "");
              if (label) (tapHandlers.get(h) || tapHandlers.set(h, new Map()).get(h)).set(label, { ...ctx });
            }
          }
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

    checkInteraction(type, spec, props, style, node, ctx);
    if (!html) checkFixedSize(type, props, style, ctx);

    // Layout: what throws in an unbounded box.
    const box = ctx.box;
    const own = (v) => v !== undefined && v !== null && v !== "" && v !== "auto";
    if (!html && spec.needsWidth && box.w === false && !own(style.width) && !own(style.maxWidth)) {
      add("error", "layout-unbounded-width", ctx, `${type} has no width bound here (${ctx.whyW}) — Flutter throws ("${type === "TextField" ? "InputDecorator cannot have an unbounded width" : "BoxConstraints forces an infinite width"}").`,
        `Wrap it in Expanded (inside the Row), or give it/its parent a style.width.`);
    }
    if (!html && spec.fallbackWidth && box.w === false && !own(style.width) && !own(style.maxWidth) && !own(props.width)) {
      add("warning", "layout-fallback-width", ctx, `${type} has no width bound here (${ctx.whyW}), so it draws at a fixed fallback width instead of filling the space.`,
        "Wrap it in Expanded (inside the Row), or give it a style.width.");
    }
    if (!html && spec.fallbackHeight && box.h === false && !own(style.height) && !own(style.maxHeight) && !own(props.height)) {
      add("warning", "layout-fallback-height", ctx, `${type} has no height bound here (${ctx.whyH}), so it draws at a fixed ${type === "Canvas" ? 300 : ""} px height instead of filling the screen.`,
        `To fill the free space, put it in an Expanded of a non-scrolling Column (Scaffold > Column > Expanded > ${type}); otherwise give it a height.`);
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
    if (type === "Stack") checkStackOverlays(list, ctx);
    if (design) designLint(type, spec, props, style, node, list, ctx);
    if (list.length > 400) add("warning", "perf-many-children", ctx, `${list.length} children drawn at once: slow on phones.`, "Page or virtualize long lists (show the first 50–100, load more on demand).");

    const wraps = typeof style.flexWrap === "string" && style.flexWrap.startsWith("wrap");
    list.forEach((c, i) => {
      const childType = isObj(c) ? c.type : undefined;
      const cb = childBox(type, spec, style, props, box, ctx, childType, wraps);
      const label = isObj(c) && typeof c.type === "string" ? c.type + (typeof c.key === "string" ? `#${c.key}` : "") : "?";
      const here = `${ctx.at.split(" > ").pop()}`;
      const scrolls = html ? null : scrollAxis(type, spec, props);
      const evs = isObj(node.events) ? Object.keys(node.events) : [];
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
        scrollV: scrolls === "vertical" ? here : ctx.scrollV,
        scrollH: scrolls === "horizontal" ? here : ctx.scrollH,
        follows: evs.some((e) => CONTINUOUS.has(e)) ? here : ctx.follows,
        tapControl: TAP_CONTROLS.includes(type) ? here : ctx.tapControl,
        noPointer: style.pointerEvents === "none" ? here : ctx.noPointer,
        fitted: ctx.fitted || type === "FittedBox",
      });
    });
  }

  // The events a node fires: its own, and what the engine's wrapper adds
  // (all gestures; to a node with its own taps, the drags, swipes and
  // scales; to one with all its own gestures, none) — plus pointer, hover
  // and focus events, which every node gets.
  function allowedEvents(type, spec) {
    if (!spec.selfEvents) return new Set([...(spec.events || []), ...GESTURE_EVENTS]);
    if (SELF_GESTURING.includes(type)) return new Set([...spec.selfEvents, ...WRAPPER_EVENTS]);
    return new Set([...spec.selfEvents, ...MOTION_EVENTS, ...WRAPPER_EVENTS]);
  }

  // The axis [type] scrolls its children on (null: it does not).
  function scrollAxis(type, spec, props) {
    if (!spec || !spec.scroll) return null;
    if (type === "ListView") return props.scrollable === false ? null : props.scrollDirection === "horizontal" ? "horizontal" : "vertical";
    if (spec.scroll === "dynamic") return props.direction === "horizontal" ? "horizontal" : "vertical";
    return spec.scroll;
  }

  // --- touch -----------------------------------------------------------------
  // How touches reach the node: a gesture that follows the finger inside a
  // scroll, swipes the scroll around it takes, handlers inside a control
  // that is tapped as a whole, nodes that can never be touched.
  function checkInteraction(type, spec, props, style, node, ctx) {
    if (mode === "widget") return;
    const evs = isObj(node.events) ? Object.keys(node.events).filter((e) => typeof node.events[e] === "string") : [];
    if (!evs.length) return;
    const follows = evs.filter((e) => CONTINUOUS.has(e));
    const taps = evs.filter((e) => TAPS.has(e));
    const num = (v) => (typeof v === "number" ? v : typeof v === "string" && /^\s*\d+(\.\d+)?(px)?\s*$/.test(v) ? parseFloat(v) : null);
    const height = num(style.height) ?? num(props.height);

    if (ctx.noPointer) {
      add("error", "events-no-pointer", ctx, `${type} has events (${evs.join(", ")}) inside ${ctx.noPointer}, whose style.pointerEvents is "none": no touch ever reaches it.`,
        `Remove pointerEvents: "none" from ${ctx.noPointer}, or move the interactive node out of it.`);
      return;
    }
    // A big surface that follows the finger, in a scroll: the page cannot
    // be scrolled from it and the surface scrolls out of view.
    const scroll = ctx.scrollV || ctx.scrollH;
    if (follows.length && scroll && (spec && spec.surface || height === null || height >= 200)) {
      add("warning", "gesture-in-scroll", ctx, `${type} follows the finger (${follows.join(", ")}) inside a scrolling ${scroll}: a touch that starts on it ${type === "Canvas" ? "draws" : "drags"} instead of scrolling, so on a phone the page can only be scrolled from around it, and the ${type === "Canvas" ? "drawing surface" : "surface"} scrolls partly out of view (older clients scroll the page instead).`,
        `Make this screen fixed, not scrolling: Scaffold (or a Column) > Expanded > ${type}, with the controls in a Row above or below it; if the screen also has long content, give that its own Expanded > ListView.`);
    }
    const swipesX = evs.filter((e) => SWIPE_X.includes(e));
    const swipesY = evs.filter((e) => SWIPE_Y.includes(e));
    if (swipesX.length && ctx.scrollH) {
      add("warning", "gesture-swipe-in-scroll", ctx, `${type} has ${swipesX.join("/")} inside the horizontally scrolling ${ctx.scrollH}: the swipe takes the horizontal drags, so ${ctx.scrollH} cannot be scrolled from it.`,
        `Use the scroll's own paging (Carousel change, Tabs), or swipe vertically here.`);
    }
    if (swipesY.length && ctx.scrollV) {
      add("warning", "gesture-swipe-in-scroll", ctx, `${type} has ${swipesY.join("/")} inside the vertically scrolling ${ctx.scrollV}: the swipe takes the vertical drags, so the page cannot be scrolled from it.`,
        `Swipe sideways (swipeleft/swiperight) on items of a vertical list, or use buttons.`);
    }
    if (follows.length && ctx.follows) {
      add("info", "gesture-nested", ctx, `${type} follows the finger inside ${ctx.follows}, which does too: drags that start on ${type} are its own and never reach ${ctx.follows}.`,
        "Fine for a draggable item on a board; otherwise put the gesture on one of them only.");
    }
    if ((taps.length || follows.length) && ctx.tapControl) {
      add("warning", "gesture-in-control", ctx, `${type} has its own ${[...taps, ...follows].join(", ")} inside the ${ctx.tapControl}, which is tapped as a whole: touches on ${type} run its handler only, never the ${ctx.tapControl}'s, so part of the control stops working.`,
        `Put the events on the ${ctx.tapControl} itself (its children are its label), or move ${type} out of it, beside it in a Row.`);
    }
    // Nothing to touch: an empty box with no size along an axis its parent
    // leaves unbounded.
    const AREA = ["Container", "SizedBox", "GestureDetector", "InkWell", "Padding", "Center", "Align", "DecoratedBox", "ClipRRect"];
    const kids = Array.isArray(node.children) ? node.children.filter((c) => isObj(c)) : [];
    if ((taps.length || follows.length) && !kids.length && AREA.includes(type)) {
      const set = (v) => v !== undefined && v !== null && v !== "" && v !== "auto" && v !== 0 && v !== "0";
      const pad = set(style.padding);
      const noH = ctx.box.h === false && !set(style.height) && !set(style.minHeight) && !set(props.height) && !pad;
      const noW = ctx.box.w === false && !set(style.width) && !set(style.minWidth) && !set(props.width) && !pad;
      if (noH || noW) {
        add("warning", "gesture-no-area", ctx, `${type} has ${evs.join(", ")} but no children and no ${noH ? "height" : "width"} here (${noH ? ctx.whyH : ctx.whyW}): it is drawn ${noH ? "0 px tall" : "0 px wide"}, so there is nothing to touch.`,
          `Give it a style.${noH ? "height" : "width"} (or padding and a child), or put it in an Expanded to fill the space.`);
      }
    }
  }

  // --- fitting the screen ------------------------------------------------------
  // Apps run on phones as well as desk windows: nothing may be wider or
  // taller than a small phone (PHONE) unless it scrolls on that axis.
  const vp = { width: (opts.viewport && opts.viewport.width) || PHONE.width, height: (opts.viewport && opts.viewport.height) || PHONE.height };
  const px = (v) => (typeof v === "number" ? v : typeof v === "string" && /^\s*\d+(\.\d+)?(px)?\s*$/.test(v) ? parseFloat(v) : null);

  function checkFixedSize(type, props, style, ctx) {
    if (mode === "widget" || ctx.fitted) return;
    const sized = ["Canvas", "Container", "SizedBox", "Scene3D", "CachedCanvas"].includes(type);
    const w = Math.max(px(style.width) ?? 0, px(style.minWidth) ?? 0, sized ? px(props.width) ?? 0 : 0);
    const h = Math.max(px(style.height) ?? 0, px(style.minHeight) ?? 0, sized ? px(props.height) ?? 0 : 0);
    if (w > vp.width && !ctx.scrollH) {
      add("warning", "layout-wider-than-screen", ctx, `${type} is ${w} px wide, wider than a phone (${vp.width} px): on a phone it is cut off at the edge.`,
        "Leave the width unset so it fills the space (cap it with style.maxWidth), use a percentage, or size it from Aseman.viewport().width.");
    }
    if (h > vp.height && !ctx.scrollV) {
      add("warning", "layout-taller-than-screen", ctx, `${type} is ${h} px tall on a screen that does not scroll, taller than a phone (${vp.height} px): its bottom is cut off.`,
        "Leave the height unset and put it in an Expanded so it takes the free height, or size it from Aseman.viewport().height.");
    }
  }

  // Line heights and font sizes of the M3 type roles (the engine's theme).
  const ROLE = {
    displayLarge: [64, 57], displayMedium: [52, 45], displaySmall: [44, 36], headlineLarge: [40, 32], headlineMedium: [36, 28], headlineSmall: [32, 24],
    titleLarge: [28, 22], titleMedium: [24, 16], titleSmall: [20, 14], bodyLarge: [24, 16], bodyMedium: [20, 14], bodySmall: [16, 12],
    labelLarge: [20, 14], labelMedium: [16, 12], labelSmall: [16, 11],
  };
  const role = (props) => ROLE[String(props.variant || "").replace(/Emphasized$/, "")] || ROLE.bodyMedium;
  const SIZE_H = { xs: 32, s: 40, m: 56, l: 96, xl: 136, small: 40, medium: 56, large: 96, sm: 40, md: 56, lg: 96 };
  const kidsOf = (n) => (Array.isArray(n.children) ? n.children.filter(isObj) : []);
  const stOf = (n) => (isObj(n.props) && isObj(n.props.style) ? n.props.style : isObj(n.style) ? n.style : {});
  const pOf = (n) => (isObj(n.props) ? n.props : {});
  function edges(v) {
    if (isObj(v)) return { t: px(v.top) || 0, r: px(v.right) || 0, b: px(v.bottom) || 0, l: px(v.left) || 0 };
    const parts = typeof v === "number" ? [v] : typeof v === "string" ? v.trim().split(/\s+/).map((x) => parseFloat(x) || 0) : [];
    const [a = 0, b = a, c = a, d = b] = parts;
    return { t: a, r: b, b: c, l: d };
  }
  const padOf = (st) => {
    const e = edges(st.padding);
    return { x: e.l + e.r + (px(st.paddingX) || 0) * 2 + (px(st.paddingLeft) || 0) + (px(st.paddingRight) || 0),
      y: e.t + e.b + (px(st.paddingY) || 0) * 2 + (px(st.paddingTop) || 0) + (px(st.paddingBottom) || 0) };
  };
  const marOf = (st) => {
    const e = edges(st.margin);
    return { x: e.l + e.r, y: e.t + e.b };
  };
  const scrollsV = (n) => {
    const spec = resolveType(n.type);
    return !!spec && scrollAxis(n.type, spec, pOf(n)) === "vertical";
  };

  // The least height [n] takes (a lower bound: only what is certain).
  // [bounded]: its parent gives it a height (an Expanded, a sized box), so a
  // scroll in it scrolls instead of growing.
  function minH(n, bounded, depth = 0) {
    if (!isObj(n) || depth > 40 || HTML.has(n.type)) return 0;
    const t = n.type, p = pOf(n), st = stOf(n), kids = kidsOf(n);
    const own = px(st.height) ?? (["Canvas", "SizedBox", "Container", "Scene3D", "CachedCanvas"].includes(t) ? px(p.height) : null);
    const mar = marOf(st).y;
    if (own !== null) return own + mar;
    const pad = padOf(st).y;
    const gap = px(st.gap) || 0;
    const sum = (list, b) => list.reduce((a, c) => a + minH(c, b, depth + 1), 0) + gap * Math.max(0, list.length - 1);
    const max = (list, b) => list.reduce((a, c) => Math.max(a, minH(c, b, depth + 1)), 0);
    let h;
    switch (t) {
      case "Text": h = role(p)[0]; break;
      case "Icon": h = px(p.size) || 24; break;
      case "Button": h = SIZE_H[p.size] || 40; break;
      case "IconButton": h = SIZE_H[p.size] || 40; break;
      case "FAB": case "FloatingActionButton": h = p.size === "small" ? 40 : p.size === "large" ? 96 : 56; break;
      case "TextField": case "SearchBar": h = 56; break;
      case "ListTile": h = (p.lines === 3 ? 88 : p.subtitle ? 72 : 56) - (p.dense === true ? 8 : 0); break;
      case "SegmentedButton": h = p.size === "m" ? 56 : 40; break;
      case "Chip": h = 32; break;
      case "Switch": case "Checkbox": case "Slider": case "Radio": h = 40; break;
      case "Divider": h = 16; break;
      case "AppBar": h = 64; break;
      case "NavigationBar": h = 80; break;
      case "LoadingIndicator": h = px(p.size) || 48; break;
      case "Avatar": h = px(p.size) || 40; break;
      case "Canvas": h = bounded ? 0 : 300; break;
      case "Spacer": h = 0; break;
      case "Column": case "Card": case "Section": case "Callout": h = sum(kids, false); break;
      case "ListGroup": h = kids.reduce((a, c) => a + minH(c, false, depth + 1), 0) + 2 * Math.max(0, kids.length - 1) + (p.title ? 28 : 0); break;
      case "Expandable": h = 56; break;
      case "Row": case "Wrap": case "Stack": case "IndexedStack": h = max(kids.filter((c) => c.type !== "Positioned"), bounded && t === "Stack"); break;
      case "Expanded": case "Flexible": h = max(kids, true); break;
      case "Tabs": h = 48 + minH(kids[Math.min(kids.length - 1, Math.max(0, Number(p.selected) || 0))], bounded, depth + 1); break;
      default:
        if (scrollsV(n)) h = bounded ? 0 : sum(kids, false);
        else if (t === "Scroll") h = 0;
        else h = max(kids, bounded);
    }
    return h + pad + mar;
  }

  // The least width [n] takes where nothing bounds it (in a Row): texts do
  // not wrap there.
  function minW(n, depth = 0) {
    if (!isObj(n) || depth > 40 || HTML.has(n.type)) return 0;
    const t = n.type, p = pOf(n), st = stOf(n), kids = kidsOf(n);
    const own = px(st.width) ?? (["Canvas", "SizedBox", "Container", "Scene3D"].includes(t) ? px(p.width) : null);
    const mar = marOf(st).x;
    if (own !== null) return own + mar;
    const pad = padOf(st).x;
    const gap = px(st.gap) || 0;
    const chars = (v) => (v === undefined || v === null ? 0 : String(v).length);
    let w;
    switch (t) {
      case "Text": w = chars(p.text ?? p.data) * role(p)[1] * 0.42; break;
      case "Icon": w = px(p.size) || 24; break;
      case "Button": {
        const label = chars(p.text ?? p.label) * 14 * 0.42;
        w = (label ? 32 + label : 0) + (p.icon ? 26 : 0) + (p.trailingIcon ? 26 : 0);
        w = Math.max(w, SIZE_H[p.size] || 40);
        break;
      }
      case "IconButton": w = SIZE_H[p.size] || 40; break;
      case "FAB": case "FloatingActionButton": w = p.label || p.text ? 80 + chars(p.label ?? p.text) * 14 * 0.42 : p.size === "small" ? 40 : p.size === "large" ? 96 : 56; break;
      case "Chip": w = 32 + chars(p.label) * 14 * 0.42 + (p.icon ? 26 : 0); break;
      case "Avatar": w = px(p.size) || 40; break;
      case "Switch": w = 52; break;
      case "Checkbox": case "Radio": w = 40; break;
      case "SegmentedButton": {
        const segs = Array.isArray(p.segments) ? p.segments : Array.isArray(p.items) ? p.items : [];
        w = segs.reduce((a, sg) => a + 24 + chars(isObj(sg) ? (sg.label ?? (sg.icon ? "" : sg.value)) : sg) * 14 * 0.42 + (isObj(sg) && sg.icon ? 26 : 0), 0);
        break;
      }
      case "Row": w = kids.reduce((a, c) => a + minW(c, depth + 1), 0) + gap * Math.max(0, kids.length - 1); break;
      case "Expanded": case "Flexible": case "Spacer": w = 0; break;
      case "Column": case "Card": case "Stack": case "Center": case "Align": case "Padding": case "Container": case "ClipRRect": case "DecoratedBox": case "Tooltip": case "Badge":
      case "AnimatedSwitcher": case "AnimatedContainer": case "AnimatedOpacity": case "AnimatedScale": case "Opacity": case "InkWell": case "GestureDetector":
        w = kids.reduce((a, c) => Math.max(a, minW(c, depth + 1)), 0); break;
      default: w = 0;
    }
    return w + pad + mar;
  }

  // Rows that need more width than the phone gives them, wherever the
  // width they get is known (from the screen, less the paddings around).
  function checkRows(n, availW, ctxPath, at, depth = 0) {
    if (!isObj(n) || depth > 60 || availW === null || HTML.has(n.type)) return;
    const t = n.type, p = pOf(n), st = stOf(n), kids = kidsOf(n);
    const spec = resolveType(t);
    if (!spec) return;
    if (t === "Row" && !(typeof st.flexWrap === "string" && st.flexWrap.startsWith("wrap"))) {
      const need = minW(n);
      if (need > availW + 1) {
        add("warning", "layout-row-overflow", { path: ctxPath, at, type: t }, `this Row needs at least ${Math.round(need)} px of width, but on a phone (${vp.width} px wide) it gets about ${Math.round(availW)} px: it overflows and its end is cut off.`,
          'Let it fit any width: wrap the texts in Expanded/Flexible (with maxLines and overflow: "ellipsis"), let the items wrap (a Wrap, or style.flexWrap: "wrap"), use icon-only IconButtons, or show fewer items when Aseman.viewport().sizeClass is "compact".');
        return;
      }
    }
    const padX = padOf(st).x + marOf(st).x;
    const own = px(st.width) ?? (["Container", "SizedBox"].includes(t) ? px(p.width) : null);
    let inner = own !== null ? Math.min(own, availW) - padX : availW - padX;
    const axis = scrollAxis(t, spec, p);
    if (axis === "horizontal" || t === "FittedBox" || t === "OverflowBox" || t === "Positioned" || t === "Wrap") return;
    kids.forEach((c, i) => {
      // A Row's children get no width bound (an Expanded's share is unknown).
      const childAvail = t === "Row" ? null : inner;
      const label = `${at} > ${c.type || "?"}${typeof c.key === "string" ? "#" + c.key : ""}`;
      checkRows(c, childAvail, `${ctxPath}.children[${i}]`, label, depth + 1);
    });
  }

  // A screen that does not scroll must fit a phone's height: its content's
  // least height against the height a phone gives it.
  function checkScreen(root, path, at) {
    if (!isObj(root) || mode === "widget" || opts.root === "scroll") return;
    let body = root, avail = vp.height, bodyAt = at, bodyPath = path;
    if (root.type === "Scaffold") {
      const kids = kidsOf(root);
      const slot = (c) => (isObj(c.props) && c.props.slot) || c.type;
      const chrome = { AppBar: 64, appBar: 64, NavigationBar: 80, bottomNavigationBar: 80, BottomNavigationBar: 80, bottomBar: 80 };
      for (const c of kids) avail -= chrome[slot(c)] || 0;
      const bodies = kids.filter((c) => !["AppBar", "appBar", "NavigationBar", "bottomNavigationBar", "BottomNavigationBar", "bottomBar", "Drawer", "drawer", "endDrawer",
        "FAB", "FloatingActionButton", "floatingActionButton", "bottomSheet", "persistentFooterButtons", "persistentFooterButton"].includes(slot(c)));
      if (bodies.length !== 1) return;
      const i = kids.indexOf(bodies[0]);
      body = bodies[0];
      bodyPath = `${path}.children[${i}]`;
      bodyAt = `${at} > ${body.type}`;
    }
    if (scrollsV(body)) return;
    const need = minH(body, true);
    if (need > avail + 1) {
      add("warning", "layout-screen-overflow", { path: bodyPath, at: bodyAt, type: body.type }, `this screen does not scroll, and its content needs at least ${Math.round(need)} px of height, but a phone (${vp.width}×${vp.height}) gives it about ${Math.round(avail)} px: the bottom is cut off on phones.`,
        "Let the part that grows scroll (Expanded > ListView inside the screen's Column), make the whole page a ListView if nothing on it needs a fixed screen, or show less when Aseman.viewport().height is small.");
    }
  }

  // A painted overlay on top in a Stack takes the touches of what it covers.
  function checkStackOverlays(list, ctx) {
    const edges = (n) => {
      const st = isObj(n.props) && isObj(n.props.style) ? n.props.style : isObj(n.style) ? n.style : {};
      return ["top", "left", "right", "bottom"].every((k) => st[k] !== undefined && st[k] !== null && st[k] !== "");
    };
    const styleOf = (n) => (isObj(n) && isObj(n.props) && isObj(n.props.style) ? n.props.style : isObj(n) && isObj(n.style) ? n.style : {});
    const paints = (n) => {
      const st = styleOf(n);
      return st.backgroundColor !== undefined || st.gradient !== undefined || st.background !== undefined || st.backgroundImage !== undefined;
    };
    const interactive = (n) => isObj(n) && ((isObj(n.events) && Object.keys(n.events).length > 0) || (Array.isArray(n.children) && n.children.some(interactive)));
    for (let j = 1; j < list.length; j++) {
      const o = list[j];
      if (!isObj(o) || o.type !== "Positioned" || !edges(o) || interactive(o)) continue;
      const inner = Array.isArray(o.children) && isObj(o.children[0]) ? o.children[0] : null;
      if (styleOf(o).pointerEvents === "none" || (inner && styleOf(inner).pointerEvents === "none")) continue;
      if (!(paints(o) || (inner && paints(inner)))) continue;
      const under = list.slice(0, j).find(interactive);
      if (!under) continue;
      add("warning", "stack-overlay-blocks", { ...ctx, path: `${ctx.path}.children[${j}]`, at: `${ctx.at} > Positioned` },
        `a painted overlay (Positioned on all four edges, with a background) lies over the Stack's ${under.type}${typeof under.key === "string" ? "#" + under.key : ""} and takes every touch on it: a painted box is hit by taps, so the ${under.type} below never responds.`,
        `Give the overlay style.pointerEvents: "none" (touches pass through it), or place it under the interactive child.`);
    }
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
    if (type === "Tabs") {
      const tabs = props.tabs ?? props.items;
      const sel = Number(props.selected);
      if (Array.isArray(tabs) && tabs.length && props.selected !== undefined && Number.isFinite(sel) && (sel < 0 || sel >= tabs.length)) {
        add("warning", "prop-value", ctx, `selected ${props.selected} is out of range (${tabs.length} tabs): the nearest tab is selected.`);
      }
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
      scrollV: opts.root === "scroll" ? "page" : null,
    });
    if (mode !== "widget") {
      checkScreen(root, roots.length > 1 ? `$[${i}]` : "$", label);
      checkRows(root, vp.width, roots.length > 1 ? `$[${i}]` : "$", label);
    }
  });

  // Keys across the tree: events are dispatched by key.
  for (const [key, uses] of keys) {
    if (uses.length < 2) continue;
    const withEvents = uses.filter((u) => u.events);
    const ctx = uses[1].ctx;
    if (withEvents.length) add("error", "key-duplicate", ctx, `key "${key}" is used by ${uses.length} nodes (${uses.map((u) => u.ctx.at.split(" > ").pop()).join(", ")}): events are dispatched by key, so a tap on one can run another's handler.`, "Give every node a unique key (append the item id).");
    else add("warning", "key-duplicate", ctx, `key "${key}" is used by ${uses.length} nodes: state (focus, scroll, animations) may jump between them.`, "Give every node a unique key.");
  }

  // One tap handler on controls with different labels: a tap carries no data
  // about which was tapped, so they all do the same thing (often a handler
  // key collision, or one shared function meant to tell them apart).
  for (const [name, labels] of tapHandlers) {
    if (labels.size < 2) continue;
    const list = [...labels.keys()];
    add("warning", "handler-shared", [...labels.values()][1], `${labels.size} controls with different labels (${list.slice(0, 6).map((l) => `"${l}"`).join(", ")}${list.length > 6 ? ", …" : ""}) share the tap handler ${name}: a tap event carries no data about which was tapped, so they all do the same thing.`,
      "Give each control its own handler: app.handler(\"key_\" + label, function () { press(label); }).");
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
// [paths] (optional) are the steps that led to each render: a finding first
// seen after some steps says so.
export function validateRenders(renders, opts = {}, paths = null, viewports = null) {
  const seen = new Set();
  const seenTrees = new Set();
  const issues = [];
  let nodes = 0;
  for (let k = 0; k < renders.length && seenTrees.size < 800; k++) {
    const tree = renders[k];
    const viewport = (viewports && viewports[k]) || opts.viewport;
    const key = JSON.stringify(tree) + JSON.stringify(viewport || null);
    if (seenTrees.has(key)) continue;
    seenTrees.add(key);
    const r = validate(tree, { ...opts, viewport });
    nodes = Math.max(nodes, r.stats.nodes);
    for (const i of r.issues) {
      const id = `${i.code}|${i.path}|${i.message}`;
      if (seen.has(id)) continue;
      seen.add(id);
      const steps = paths && paths[k];
      issues.push(steps && steps.length ? { ...i, steps, message: `${i.message} (reached after: ${steps.join(" → ")})` } : i);
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
  const layout = [spec.needsWidth && "needs a bounded width (wrap in Expanded inside a Row)", spec.fallbackWidth && "without a width bound (in a Row) it takes a fixed width: wrap in Expanded to fill", spec.needsHeight && "needs a bounded height (not inside a scroll)"].filter(Boolean);
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
    const report = validateRenders(run.trees || [], { mode: display === "compact" ? "widget" : "app", design: opts.design, theme: run.theme }, run.paths, run.viewports);
    // Runtime problems (a view or handler that throws, server errors) first.
    const runtime = (run.errors || []).map((message) => ({ severity: "error", code: "runtime", path: "$", at: "", message }));
    report.issues.unshift(...runtime);
    report.errors += runtime.length;
    report.ok = report.errors === 0;
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
