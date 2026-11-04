#!/usr/bin/env node
// Makes a web plugin one self-contained HTML document, as the app's web
// frame requires (it allows nothing from the network or the disk): local
// <script src>, <link rel="stylesheet" href>, <img src>, CSS url(…) fonts and
// images are inlined (scripts and styles as text, the rest as data: URLs).
// Remote URLs are left alone, and plugin-check reports them.
//
//   node plugin-inline.mjs src/index.html -o dist/plugin.html
//
// Bundle the libraries first (e.g. npx esbuild src/main.js --bundle --minify
// --format=iife --outfile=src/app.js), then reference app.js from index.html.

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const TYPES = {
  ".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".gif": "image/gif", ".webp": "image/webp", ".svg": "image/svg+xml",
  ".woff": "font/woff", ".woff2": "font/woff2", ".ttf": "font/ttf", ".otf": "font/otf", ".glb": "model/gltf-binary", ".gltf": "model/gltf+json",
  ".hdr": "application/octet-stream", ".bin": "application/octet-stream", ".json": "application/json", ".wasm": "application/wasm",
  ".mp3": "audio/mpeg", ".wav": "audio/wav", ".mp4": "video/mp4", ".webm": "video/webm",
};

const remote = (url) => /^([a-z]+:)?\/\//i.test(url) || /^(data|blob):/i.test(url);

function local(base, url) {
  const clean = decodeURIComponent(String(url).split(/[?#]/)[0]);
  const file = path.resolve(base, clean);
  if (!fs.existsSync(file)) throw new Error(`${url}: not found (looked at ${file})`);
  return file;
}

function dataUrl(file) {
  const type = TYPES[path.extname(file).toLowerCase()] || "application/octet-stream";
  return `data:${type};base64,${fs.readFileSync(file).toString("base64")}`;
}

/** CSS with its local url(…) references inlined, relative to base. */
export function inlineCss(css, base) {
  return css.replace(/url\(\s*(['"]?)([^'")]+)\1\s*\)/g, (whole, _q, url) => (remote(url) || url.startsWith("#") ? whole : `url("${dataUrl(local(base, url))}")`));
}

// Inline scripts must not end their own element.
const safeScript = (js) => js.replace(/<\/script/gi, "<\\/script");

/** The document with every local reference inlined. */
export function inlineHtml(html, base) {
  let out = html.replace(/<script\b([^>]*?)\bsrc\s*=\s*(['"])([^'"]+)\2([^>]*)>\s*<\/script>/gi, (whole, pre, _q, src, post) => {
    if (remote(src)) return whole;
    const attrs = `${pre} ${post}`.replace(/\s+/g, " ").trim();
    return `<script${attrs ? " " + attrs : ""}>${safeScript(fs.readFileSync(local(base, src), "utf8"))}</script>`;
  });
  out = out.replace(/<link\b[^>]*>/gi, (tag) => {
    if (!/rel\s*=\s*(['"]?)stylesheet\1/i.test(tag)) return tag;
    const href = /href\s*=\s*(['"])([^'"]+)\1/i.exec(tag);
    if (!href || remote(href[2])) return tag;
    const file = local(base, href[2]);
    return `<style>${inlineCss(fs.readFileSync(file, "utf8"), path.dirname(file))}</style>`;
  });
  out = out.replace(/<style\b([^>]*)>([\s\S]*?)<\/style>/gi, (_w, attrs, css) => `<style${attrs}>${inlineCss(css, base)}</style>`);
  out = out.replace(/(<(?:img|source|video|audio)\b[^>]*?\b(?:src|poster)\s*=\s*)(['"])([^'"]+)\2/gi, (whole, pre, q, src) =>
    remote(src) ? whole : `${pre}${q}${dataUrl(local(base, src))}${q}`);
  return out;
}

async function main(argv) {
  const input = argv.find((a, i) => !a.startsWith("-") && argv[i - 1] !== "-o");
  const output = argv.includes("-o") ? argv[argv.indexOf("-o") + 1] : "";
  if (!input) {
    console.error("usage: plugin-inline.mjs src/index.html [-o dist/plugin.html]");
    return 2;
  }
  const html = inlineHtml(fs.readFileSync(input, "utf8"), path.dirname(path.resolve(input)));
  if (output) {
    fs.mkdirSync(path.dirname(path.resolve(output)), { recursive: true });
    fs.writeFileSync(output, html);
    console.log(`${output}: ${(Buffer.byteLength(html) / 1024).toFixed(0)} KB`);
  } else process.stdout.write(html);
  return 0;
}

// Run as a command (also through a symlink such as /usr/local/bin/aseman-plugin-check).
const invoked = (() => {
  try {
    return fs.realpathSync(process.argv[1] || "") === fs.realpathSync(fileURLToPath(import.meta.url));
  } catch {
    return false;
  }
})();
if (invoked) {
  main(process.argv.slice(2)).then((c) => process.exit(c), (e) => {
    console.error(e.message || e);
    process.exit(1);
  });
}
