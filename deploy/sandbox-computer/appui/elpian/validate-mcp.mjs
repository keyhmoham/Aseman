#!/usr/bin/env node
// The Elpian UI DSL validator as an MCP server (stdio, newline-delimited
// JSON-RPC 2.0; no dependencies), so coding agents can call it as
// tools:
//
//   elpian_validate          validate a view tree (JSON, a file, or an OpenUI tree)
//   elpian_validate_program  run a bundled program on QuickJS and validate every render (app + phone widget)
//   elpian_describe          the schema of node types (props, events, children, parents, layout)
//   elpian_icons             search the Material icon names the client draws
//
// Register it with an MCP client, e.g. "mcp": {"elpian": {"type": "local",
// "command": ["node", "/opt/aseman-appui/elpian/validate-mcp.mjs"]}}.

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { serveTools, text } from "./mcp-stdio.mjs";
import { validate, validateProgram, describe, listTypes, format, fromOpenUI } from "./validate.mjs";

const here = path.dirname(fileURLToPath(import.meta.url));
const ICONS = JSON.parse(fs.readFileSync(path.join(here, "icons.json"), "utf8")).icons;
const VERSION = "1.0.0";

const INSTRUCTIONS = `Validates Elpian UI DSL view trees (the JSON the Aseman client draws natively) against the engine's schema: node types, props (types, enums, ranges, icons, formats, data fields), styles, events, keys, child arity and slots, parent–child relations, layout constraints (what throws in an unbounded Row or scroll), the phone-widget rules and Material 3 Expressive design lint.
Use elpian_validate on any tree you write or generate (a single screen, a component, an OpenUI tree), and elpian_validate_program on the bundle (elpian/app.js, with your server running) before you finish: fix every error, then the warnings. Use elpian_describe before using a node you have not used yet, and elpian_icons to pick icon names.`;

const TOOLS = [
  {
    name: "elpian_validate",
    description: "Validate an Elpian UI DSL view tree. Pass the tree as JSON (`tree`) or a path to a JSON file (`file`). Reports errors (things that throw or never render), warnings (ignored or misread values, touches that never arrive, layouts that do not fit a phone) and design notes, each with its location in the tree and a fix. Set mode \"widget\" to check it as the phone widget, and openui: true for an OpenUI tree ({c, p, children}).",
    inputSchema: {
      type: "object",
      properties: {
        tree: { description: "The view tree: {type, props, children, events, key}, or an array of trees." },
        file: { type: "string", description: "Path to a JSON file holding the tree (instead of `tree`)." },
        mode: { type: "string", enum: ["app", "widget"], description: "app (default) or widget (the phone widget rules)." },
        openui: { type: "boolean", description: "The tree is an OpenUI tree: render it to Elpian first." },
        design: { type: "boolean", description: "Include Material 3 Expressive design notes (default true)." },
        root: { type: "string", enum: ["screen", "scroll"], description: "What the root sits in: the screen (default, bounded) or a scroll." },
        viewport: { type: "object", properties: { width: { type: "number" }, height: { type: "number" } }, description: "The screen fixed layouts must fit (default a small phone, 360×640)." },
        json: { type: "boolean", description: "Return the full JSON report instead of text." },
      },
    },
  },
  {
    name: "elpian_validate_program",
    description: "Run a bundled Elpian program (default elpian/app.js) on QuickJS, the engine the client uses, against a simulated Aseman host (and your running server with `server`), exercise its event handlers, and validate every view it renders, as the app and as its phone widget. Also reports runtime problems (exceptions, handlers that throw, missing handlers).",
    inputSchema: {
      type: "object",
      properties: {
        bundle: { type: "string", description: "Path to the bundle (default elpian/app.js; build it with node vendor/aseman-elpian/bundle.mjs .)." },
        server: { type: "string", description: "Your running server, e.g. http://127.0.0.1:8787 (Aseman.fetch goes there)." },
        apps: { type: "string", description: "Path to APPS.json (the space's apps and agents)." },
        widgetOnly: { type: "boolean", description: "The program is only a phone widget (a web app's elpian/widget.js)." },
        design: { type: "boolean", description: "Include design notes (default true)." },
        json: { type: "boolean", description: "Return the full JSON report." },
      },
    },
  },
  {
    name: "elpian_describe",
    description: "Describe Elpian node types: props with their types and values, events, children (none/one/many/slots), required parents and layout constraints. Without `types`, lists every node type by category.",
    inputSchema: { type: "object", properties: { types: { type: "array", items: { type: "string" }, description: "Node types, e.g. [\"Button\", \"ListTile\"]." } } },
  },
  {
    name: "elpian_icons",
    description: "Search the Material icon names the client draws (rounded). Returns names containing every word of the query; an empty query lists them all.",
    inputSchema: { type: "object", properties: { query: { type: "string", description: "e.g. \"calendar\", \"arrow back\", \"money\"." } } },
  },
];

const resolve = (p) => path.resolve(process.cwd(), p);

export async function call(name, args = {}) {
  switch (name) {
    case "elpian_validate": {
      let tree = args.tree;
      if (tree === undefined && args.file) tree = JSON.parse(fs.readFileSync(resolve(args.file), "utf8"));
      if (typeof tree === "string") tree = JSON.parse(tree);
      if (tree === undefined) return text("Pass `tree` (the view tree JSON) or `file` (a path to it).", true);
      if (tree && !Array.isArray(tree) && typeof tree === "object" && !tree.type && (tree.view || tree.tree)) tree = tree.view || tree.tree;
      if (args.openui) tree = await fromOpenUI(tree);
      const report = validate(tree, { mode: args.mode || "app", design: args.design !== false, root: args.root, viewport: args.viewport });
      return text(args.json ? JSON.stringify(report, null, 1) : format(report), false);
    }
    case "elpian_validate_program": {
      const file = resolve(args.bundle || "elpian/app.js");
      if (!fs.existsSync(file)) return text(`No bundle at ${file}: build it with node vendor/aseman-elpian/bundle.mjs .`, true);
      const apps = args.apps && fs.existsSync(resolve(args.apps)) ? JSON.parse(fs.readFileSync(resolve(args.apps), "utf8")) : null;
      const results = await validateProgram(fs.readFileSync(file, "utf8"), { server: args.server || "", apps, design: args.design !== false, widgetOnly: !!args.widgetOnly });
      if (args.json) return text(JSON.stringify(results.map((r) => ({ display: r.display === "compact" ? "widget" : "app", runtime: { errors: r.run.errors, warnings: r.run.warnings }, ...r.report })), null, 1));
      const parts = [];
      let ok = true;
      for (const { display, run, report } of results) {
        const where = display === "compact" ? "as the phone widget" : "as the app";
        // Runtime errors are already in the report (validateProgram); add the warnings.
        const runtime = (run.warnings || []).map((w) => `RUNTIME WARNING ${w}`);
        ok = ok && report.ok;
        parts.push(`── ${where} ──\n${runtime.length ? runtime.join("\n") + "\n" : ""}${format(report)}`);
      }
      parts.push(ok ? "Program VALID." : "Program INVALID: fix the errors above and run again.");
      return text(parts.join("\n\n"));
    }
    case "elpian_describe": {
      const types = Array.isArray(args.types) ? args.types : args.type ? [args.type] : [];
      return text(types.length ? types.map(describe).join("\n\n") : listTypes());
    }
    case "elpian_icons": {
      const words = String(args.query || "").toLowerCase().split(/[\s_-]+/).filter(Boolean);
      const hits = ICONS.filter((n) => words.every((w) => n.includes(w)));
      return text(hits.length ? hits.join(", ") : `No icon matches "${args.query}". Try a broader word.`);
    }
    default:
      return null;
  }
}

export { TOOLS, INSTRUCTIONS };

export function serve(input = process.stdin, output = process.stdout) {
  return serveTools({ name: "aseman-elpian", version: VERSION, instructions: INSTRUCTIONS, tools: TOOLS, call, failure: "The validator failed" }, input, output);
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  serve().catch((e) => {
    process.stderr.write(String(e && e.stack ? e.stack : e) + "\n");
    process.exit(1);
  });
}
