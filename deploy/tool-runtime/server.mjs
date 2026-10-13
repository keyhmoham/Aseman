#!/usr/bin/env node
// Tradera tool runtime.
//
// Backend role (default): runs one tool's backend program — on the Elpian VM
// or on QuickJS — and serves its microtools over MCP at /mcp. It is how a
// managed tool runs (a Nomad service of the tool runtime image) and how an
// installed tool runs (a process in a space's sandbox, whose image carries
// this runtime at /opt/tradera-tool-runtime).
//
//   TRADERA_TOOL_ENGINE        elpian | quickjs
//   TRADERA_TOOL_ID            the tool's runtime key
//   TRADERA_TOOL_TOKEN         the node's runtime credential for this tool
//   TRADERA_NODE_URL           the node, as the backend reaches it
//   TRADERA_TOOL_PROGRAM_FILE  the program, when written next to the runtime
//                              (installed tools); otherwise fetched from the node
//   TRADERA_TOOL_VERSION       reported by /health (installed tools)
//   PORT                       default 8790
//
// Compiler role (--compiler): compiles Elpian VM programs to bytecode for the
// node (a static Elpian frontend runs as bytecode on devices) and loads
// backend programs to report the microtools they declare.
//
//   POST /compile   {language: dart|js, source}          → {bytecode: base64}
//   POST /describe  {engine, language, source}           → {tools: [...]}

import http from 'node:http';
import { compileElpian, createElpianEngine } from './lib/elpian.mjs';
import { createFetcher } from './lib/fetch.mjs';
import { handleMcp } from './lib/mcp.mjs';
import { NodeGateway, loadProgram } from './lib/node.mjs';
import { createQuickJSEngine } from './lib/quickjs.mjs';

const MAX_BODY = 4 << 20;

export async function createEngine(program) {
  switch (program.engine) {
    case 'quickjs':
      return createQuickJSEngine(program.source);
    case 'elpian':
      return createElpianEngine(program.source, { language: program.language || 'dart' });
    default:
      throw new Error(`unknown engine ${program.engine}`);
  }
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    let size = 0;
    const chunks = [];
    req.on('data', (c) => {
      size += c.length;
      if (size > MAX_BODY) {
        reject(new Error('request too large'));
        req.destroy();
        return;
      }
      chunks.push(c);
    });
    req.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
    req.on('error', reject);
  });
}

function send(res, status, body) {
  if (body === null) {
    res.writeHead(status).end();
    return;
  }
  const raw = JSON.stringify(body);
  res.writeHead(status, { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(raw) }).end(raw);
}

/** The backend role's HTTP handler. */
export function backendHandler({ engine, tools, token, node, fetch = null, version, log = console.log }) {
  return async (req, res) => {
    try {
      if (req.method === 'GET' && req.url === '/health') {
        return send(res, 200, { ok: true, engine: engine.engine, version: version || '', tools: tools.length });
      }
      if (req.method === 'POST' && req.url.split('?')[0] === '/mcp') {
        const message = JSON.parse((await readBody(req)) || '{}');
        const [status, body] = await handleMcp({ engine, tools, token, node, fetch, headers: req.headers, message, log });
        return send(res, status, body);
      }
      send(res, 404, { error: 'not found' });
    } catch (error) {
      send(res, 400, { error: String(error?.message ?? error) });
    }
  };
}

/** The compiler role's HTTP handler. */
export function compilerHandler() {
  return async (req, res) => {
    try {
      if (req.method === 'GET' && req.url === '/health') return send(res, 200, { ok: true, role: 'compiler' });
      if (req.method !== 'POST') return send(res, 404, { error: 'not found' });
      const input = JSON.parse((await readBody(req)) || '{}');
      if (req.url === '/compile') {
        const bytecode = compileElpian(input.language === 'js' ? 'js' : 'dart', String(input.source ?? ''));
        return send(res, 200, { bytecode: Buffer.from(bytecode).toString('base64') });
      }
      if (req.url === '/describe') {
        const engine = await createEngine({ engine: input.engine, language: input.language, source: String(input.source ?? '') });
        try {
          return send(res, 200, { tools: await engine.list() });
        } finally {
          engine.dispose();
        }
      }
      send(res, 404, { error: 'not found' });
    } catch (error) {
      send(res, 422, { error: String(error?.message ?? error) });
    }
  };
}

async function main() {
  const port = Number(process.env.PORT || 8790);
  if (process.argv.includes('--compiler')) {
    http.createServer(compilerHandler()).listen(port, '0.0.0.0', () => console.log(`[runtime] compiler on :${port}`));
    return;
  }
  const gateway = new NodeGateway({ url: process.env.TRADERA_NODE_URL, toolId: process.env.TRADERA_TOOL_ID, token: process.env.TRADERA_TOOL_TOKEN });
  const program = await loadProgram({ file: process.env.TRADERA_TOOL_PROGRAM_FILE, gateway });
  const engine = await createEngine({ ...program, engine: program.engine || process.env.TRADERA_TOOL_ENGINE });
  const tools = await engine.list();
  const handler = backendHandler({
    engine, tools, token: process.env.TRADERA_TOOL_TOKEN, node: gateway,
    fetch: createFetcher(), version: process.env.TRADERA_TOOL_VERSION,
  });
  http.createServer(handler).listen(port, '0.0.0.0', () => {
    console.log(`[runtime] ${engine.engine} backend serving ${tools.length} microtool(s) on :${port}`);
  });
}

if (import.meta.url === `file://${process.argv[1]}`) {
  main().catch((error) => {
    console.error(`[runtime] ${error?.stack ?? error}`);
    process.exit(1);
  });
}
