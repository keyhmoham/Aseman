// A minimal MCP server over stdio (newline-delimited JSON-RPC 2.0, no
// dependencies): validate-mcp.mjs and drive-mcp.mjs serve their tools with it.
//
//   serveTools({ name, version, instructions, tools, call })
//     tools: the tools/list entries; call(name, args) -> {content, isError}
//     (null for an unknown tool). Calls are answered in the order they came,
//     so a stateful server (the driver) sees its steps one after another.

import readline from "node:readline";

export const text = (t, isError = false) => ({ content: [{ type: "text", text: t }], isError });

export function handler({ name, version, instructions, tools, call, failure = "The tool failed" }) {
  return async function handle(msg) {
    const { id, method, params } = msg;
    const reply = (result) => ({ jsonrpc: "2.0", id, result });
    const fail = (code, message) => ({ jsonrpc: "2.0", id, error: { code, message } });
    switch (method) {
      case "initialize":
        return reply({
          protocolVersion: (params && params.protocolVersion) || "2025-06-18",
          capabilities: { tools: { listChanged: false } },
          serverInfo: { name, version },
          instructions,
        });
      case "ping":
        return reply({});
      case "tools/list":
        return reply({ tools });
      case "tools/call": {
        try {
          const out = await call(params && params.name, (params && params.arguments) || {});
          if (!out) return fail(-32602, `Unknown tool: ${params && params.name}`);
          return reply(out);
        } catch (e) {
          return reply(text(`${failure}: ${e && e.message ? e.message : e}`, true));
        }
      }
      default:
        if (id === undefined || id === null) return null; // a notification
        return fail(-32601, `Method not found: ${method}`);
    }
  };
}

export async function serveTools(spec, input = process.stdin, output = process.stdout) {
  const handle = handler(spec);
  const rl = readline.createInterface({ input, crlfDelay: Infinity });
  let chain = Promise.resolve();
  for await (const line of rl) {
    if (!line.trim()) continue;
    let msg;
    try {
      msg = JSON.parse(line);
    } catch {
      output.write(JSON.stringify({ jsonrpc: "2.0", id: null, error: { code: -32700, message: "Parse error" } }) + "\n");
      continue;
    }
    const batch = Array.isArray(msg) ? msg : [msg];
    chain = chain.then(async () => {
      const replies = [];
      for (const m of batch) replies.push(await handle(m));
      const out = replies.filter(Boolean);
      if (out.length) output.write(JSON.stringify(Array.isArray(msg) ? out : out[0]) + "\n");
    });
  }
  await chain;
}
