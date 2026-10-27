#!/usr/bin/env node
// The Elpian validator and headless driver on the command line, for Aseman's
// own agents (installed as `aseman-elpian`). They are the very tools OpenCode
// gets as MCP servers (validate-mcp.mjs, drive-mcp.mjs), so an app built by
// the space's agents is designed, validated and tested end to end exactly
// like one OpenCode builds.
//
//   aseman-elpian tools [name]                 list the tools (or one, with its arguments)
//   aseman-elpian <tool> ['{json args}' | @args.json | -] [--dir DIR]
//   aseman-elpian stop [--dir DIR]              end the project's driver sessions
//
// The validator tools (elpian_validate, elpian_validate_program,
// elpian_describe, elpian_icons) run in the command. The driver tools
// (elpian_open, elpian_tap, … elpian_run_scenarios) keep sessions between
// commands: the first one starts a small driver process for the project
// directory (on a unix socket), and every later command talks to it, so a
// session opened by one command is tapped, checked and saved by the next.
// It exits by itself after ASEMAN_ELPIAN_IDLE_SECS (default 1800) unused.

import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import http from "node:http";
import crypto from "node:crypto";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";

const self = fileURLToPath(import.meta.url);
const VALIDATOR = new Set(["elpian_validate", "elpian_validate_program", "elpian_describe", "elpian_icons"]);

export function socketFor(dir) {
  const hash = crypto.createHash("sha1").update(path.resolve(dir)).digest("hex").slice(0, 16);
  return path.join(os.tmpdir(), `aseman-elpian-${hash}.sock`);
}

async function catalog() {
  const v = await import("./validate-mcp.mjs");
  const d = await import("./drive-mcp.mjs");
  return { tools: [...v.TOOLS, ...d.TOOLS], instructions: `${v.INSTRUCTIONS}\n\n${d.INSTRUCTIONS}` };
}

const out = (r) => (r && r.content ? r.content.map((c) => c.text).join("\n") : "");

// ── the driver process ──────────────────────────────────────────────────

async function daemon(socket, dir) {
  process.chdir(dir);
  const drive = await import("./drive-mcp.mjs");
  const idle = Math.max(30, Number(process.env.ASEMAN_ELPIAN_IDLE_SECS) || 1800) * 1000;
  let timer;
  const stop = () => drive.closeAll().finally(() => {
    try { fs.unlinkSync(socket); } catch {}
    process.exit(0);
  });
  const touch = () => {
    clearTimeout(timer);
    timer = setTimeout(stop, idle);
  };
  // Steps run one after another, as an MCP client sends them.
  let chain = Promise.resolve();
  const server = http.createServer((req, res) => {
    let body = "";
    req.on("data", (c) => (body += c));
    req.on("end", () => {
      touch();
      chain = chain.then(async () => {
        let reply;
        try {
          const { name, args } = JSON.parse(body || "{}");
          if (name === "__stop") {
            res.end(JSON.stringify({ content: [{ type: "text", text: "driver stopped" }] }));
            return stop();
          }
          reply = (await drive.call(name, args || {})) || { content: [{ type: "text", text: `unknown tool ${name}` }], isError: true };
        } catch (e) {
          reply = { content: [{ type: "text", text: `The driver failed: ${e && e.message ? e.message : e}` }], isError: true };
        }
        res.setHeader("content-type", "application/json");
        res.end(JSON.stringify(reply));
      });
    });
  });
  try { fs.unlinkSync(socket); } catch {}
  server.listen(socket, touch);
  process.on("SIGTERM", stop);
  process.on("SIGINT", stop);
}

// ── the client ──────────────────────────────────────────────────────────

function post(socket, payload) {
  return new Promise((resolve, reject) => {
    const req = http.request({ socketPath: socket, path: "/", method: "POST", headers: { "content-type": "application/json" } }, (res) => {
      let body = "";
      res.on("data", (c) => (body += c));
      res.on("end", () => {
        try { resolve(JSON.parse(body)); } catch (e) { reject(e); }
      });
    });
    req.on("error", reject);
    req.end(JSON.stringify(payload));
  });
}

async function driver(dir, payload, { start = true } = {}) {
  const socket = socketFor(dir);
  try {
    return await post(socket, payload);
  } catch (e) {
    if (!start || !["ECONNREFUSED", "ENOENT"].includes(e.code)) throw e;
  }
  const log = fs.openSync(path.join(os.tmpdir(), path.basename(socket, ".sock") + ".log"), "a");
  spawn(process.execPath, [self, "--serve", socket, "--dir", dir], { detached: true, stdio: ["ignore", log, log], cwd: dir }).unref();
  for (let i = 0; i < 100; i++) {
    await new Promise((r) => setTimeout(r, 100));
    try {
      return await post(socket, payload);
    } catch (e) {
      if (!["ECONNREFUSED", "ENOENT"].includes(e.code)) throw e;
    }
  }
  throw new Error(`the driver did not start (see ${path.join(os.tmpdir(), path.basename(socket, ".sock") + ".log")})`);
}

function readArgs(raw) {
  if (raw === undefined || raw === "") return {};
  if (raw === "-") raw = fs.readFileSync(0, "utf8");
  else if (raw.startsWith("@")) raw = fs.readFileSync(raw.slice(1), "utf8");
  const args = JSON.parse(raw);
  if (!args || typeof args !== "object" || Array.isArray(args)) throw new Error("the arguments are a JSON object");
  return args;
}

function usage(tools) {
  return [
    "Usage: aseman-elpian <tool> ['{json args}' | @args.json | -] [--dir DIR]",
    "       aseman-elpian tools [name]   |   aseman-elpian stop [--dir DIR]",
    "",
    "Tools (the same ones OpenCode has; driver sessions persist between commands):",
    ...tools.map((t) => `  ${t.name.padEnd(24)} ${t.description.split(". ")[0]}.`),
  ].join("\n");
}

async function main(argv) {
  if (argv[0] === "--serve") return daemon(argv[1], argv[argv.indexOf("--dir") + 1] || process.cwd());
  const di = argv.indexOf("--dir");
  const dir = path.resolve(di >= 0 ? argv[di + 1] : process.cwd());
  const free = argv.filter((a, i) => a !== "--dir" && argv[i - 1] !== "--dir");
  const [cmd, raw] = free;
  if (!cmd || cmd === "help" || cmd === "-h" || cmd === "--help") {
    console.log(usage((await catalog()).tools));
    return 0;
  }
  if (cmd === "tools") {
    const { tools, instructions } = await catalog();
    if (!raw) {
      console.log(`${instructions}\n\n${usage(tools)}`);
      return 0;
    }
    const t = tools.find((x) => x.name === raw);
    if (!t) throw new Error(`no tool ${raw}`);
    console.log(`${t.name}\n${t.description}\n\narguments (JSON schema):\n${JSON.stringify(t.inputSchema, null, 2)}`);
    return 0;
  }
  if (cmd === "stop") {
    try {
      console.log(out(await driver(dir, { name: "__stop" }, { start: false })));
    } catch {
      console.log("no driver running for this directory");
    }
    return 0;
  }
  const args = readArgs(raw);
  let reply;
  if (VALIDATOR.has(cmd)) {
    process.chdir(dir);
    const v = await import("./validate-mcp.mjs");
    reply = await v.call(cmd, args);
  } else {
    const { tools } = await catalog();
    if (!tools.some((t) => t.name === cmd)) throw new Error(`unknown tool ${cmd}: aseman-elpian tools lists them`);
    reply = await driver(dir, { name: cmd, args });
  }
  console.log(out(reply));
  return reply && reply.isError ? 1 : 0;
}

// Run as a command (also through the aseman-elpian symlink), not when imported.
const invoked = (() => {
  try { return process.argv[1] && fs.realpathSync(process.argv[1]) === fs.realpathSync(self); } catch { return false; }
})();
if (invoked) {
  main(process.argv.slice(2)).then(
    (code) => { if (typeof code === "number") process.exitCode = code; },
    (e) => {
      console.error(`aseman-elpian: ${e && e.message ? e.message : e}`);
      process.exit(2);
    },
  );
}
