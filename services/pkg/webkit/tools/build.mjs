// Builds kit/aseman-ui.js from src/*.js (in name order) inside one closure.
//   node tools/build.mjs          writes it
//   node tools/build.mjs --check  fails when it is out of date
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.join(path.dirname(fileURLToPath(import.meta.url)), '..');
const src = path.join(root, 'src');
const files = fs.readdirSync(src).filter((f) => f.endsWith('.js')).sort();
const body = files.map((f) => `// ==== ${f} ====\n` + fs.readFileSync(path.join(src, f), 'utf8')).join('\n');
const out = `/*!
 * Aseman web UI kit — the app's look and components for web pages, and their
 * client for the Aseman API. Built from services/pkg/webkit/src by
 * tools/build.mjs; edit the sources, not this file.
 * Icons: Material icons (round), Apache-2.0.
 */
(function () {
'use strict';
if (window.Aseman && window.Aseman.version) return;
${body}
})();
`;
const target = path.join(root, 'kit', 'aseman-ui.js');
if (process.argv.includes('--check')) {
  if (!fs.existsSync(target) || fs.readFileSync(target, 'utf8') !== out) {
    console.error('kit/aseman-ui.js is out of date: run node services/pkg/webkit/tools/build.mjs');
    process.exit(1);
  }
} else fs.writeFileSync(target, out);
