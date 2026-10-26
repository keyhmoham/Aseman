#!/usr/bin/env node
// Bundles an Elpian App UI into the one program the client runs:
//   vendor/aseman-elpian/aseman-elpian.js + openui-elpian.js + the app's files
//   -> elpian/app.js
// The app's files are elpian/manifest.json "files" (in order), else every
// .js file of elpian/src with main.js last. Elpian programs have no modules:
// the files share one global scope, in this order.
//
//   node vendor/aseman-elpian/bundle.mjs [projectDir]

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));

export function appFiles(dir) {
  const elpian = path.join(dir, "elpian");
  const manifest = path.join(elpian, "manifest.json");
  if (fs.existsSync(manifest)) {
    const m = JSON.parse(fs.readFileSync(manifest, "utf8"));
    if (!Array.isArray(m.files) || !m.files.length) throw new Error("elpian/manifest.json needs a non-empty \"files\" list");
    return m.files.map((f) => {
      const p = path.resolve(elpian, f);
      if (!p.startsWith(elpian + path.sep)) throw new Error(`${f} is outside elpian/`);
      return p;
    });
  }
  const src = path.join(elpian, "src");
  if (!fs.existsSync(src)) throw new Error("no elpian/src (or elpian/manifest.json): write the frontend there");
  const files = fs.readdirSync(src).filter((f) => f.endsWith(".js")).sort();
  files.sort((a, b) => (a === "main.js") - (b === "main.js"));
  if (!files.length) throw new Error("elpian/src has no .js files");
  return files.map((f) => path.join(src, f));
}

export function bundle(dir, { sdkDir = here } = {}) {
  const parts = [
    ["aseman-elpian.js", path.join(sdkDir, "aseman-elpian.js")],
    ["openui-elpian.js", path.join(sdkDir, "openui-elpian.js")],
    ...appFiles(dir).map((f) => [path.relative(dir, f), f]),
  ];
  let out = "// Built by aseman-appui (vendor/aseman-elpian/bundle.mjs). Do not edit: change elpian/src.\n";
  for (const [name, file] of parts) {
    out += `\n// ---- ${name} ----\n${fs.readFileSync(file, "utf8")}\n;\n`;
  }
  const target = path.join(dir, "elpian", "app.js");
  fs.writeFileSync(target, out);
  return { target, bytes: Buffer.byteLength(out), files: parts.map((p) => p[0]) };
}

if (import.meta.url === `file://${process.argv[1]}`) {
  try {
    const r = bundle(path.resolve(process.argv[2] || "."));
    console.log(`elpian bundle: ${r.target} (${r.bytes} bytes): ${r.files.join(", ")}`);
  } catch (e) {
    console.error(`elpian bundle: ${e.message}`);
    process.exit(1);
  }
}
