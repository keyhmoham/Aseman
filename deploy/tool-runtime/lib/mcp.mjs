// MCP over HTTP (JSON-RPC 2.0, the subset the node's MCP client speaks):
// initialize, notifications/initialized, tools/list and tools/call.

import { timingSafeEqual } from 'node:crypto';
import { hostApis } from './contract.mjs';

export const PROTOCOL_VERSION = '2025-06-18';

function sameSecret(a, b) {
  const x = Buffer.from(String(a ?? ''));
  const y = Buffer.from(String(b ?? ''));
  return x.length === y.length && x.length > 0 && timingSafeEqual(x, y);
}

/** The execution scope the node sent with a call. */
export function scopeOf(headers) {
  const h = (name) => String(headers[name] ?? '');
  return {
    tool: h('x-aseman-tool'), actor: h('x-aseman-actor'), space: h('x-aseman-space'),
    room: h('x-aseman-room'), agent: h('x-aseman-agent'), token: h('x-aseman-scope'),
  };
}

/** What a microtool returned, as an MCP tool result. */
export function toolResult(value) {
  const text = typeof value === 'string' ? value : JSON.stringify(value ?? null);
  const result = { content: [{ type: 'text', text }], isError: false };
  if (value !== null && typeof value === 'object' && !Array.isArray(value)) result.structuredContent = value;
  return result;
}

/**
 * Handles one JSON-RPC request. Returns [status, body|null].
 * [token] is the node's runtime credential: only the node may call. [tools]
 * is what the program's tools() declared when it was loaded.
 */
export async function handleMcp({ engine, tools, token, node, fetch = null, headers, message, log = console.log }) {
  if (token && !sameSecret(headers['x-aseman-token'], token)) {
    return [401, { jsonrpc: '2.0', id: message?.id ?? null, error: { code: -32001, message: 'unauthorized' } }];
  }
  const id = message?.id ?? null;
  const reply = (result) => [200, { jsonrpc: '2.0', id, result }];
  const fail = (code, msg) => [200, { jsonrpc: '2.0', id, error: { code, message: msg } }];
  switch (message?.method) {
    case 'initialize':
      return reply({ protocolVersion: PROTOCOL_VERSION, capabilities: { tools: {} }, serverInfo: { name: 'aseman-tool-runtime', version: '1.0.0' } });
    case 'notifications/initialized':
      return [202, null];
    case 'ping':
      return reply({});
    case 'tools/list':
      return reply({ tools });
    case 'tools/call': {
      const name = message.params?.name;
      const args = message.params?.arguments ?? {};
      if (!tools.some((t) => t.name === name)) return fail(-32602, `unknown microtool ${name}`);
      try {
        const value = await engine.call(name, args, hostApis(scopeOf(headers), node, log, fetch));
        return reply(toolResult(value));
      } catch (error) {
        // A failing microtool is a result the caller reads, not a transport error.
        return reply({ content: [{ type: 'text', text: String(error?.message ?? error) }], isError: true });
      }
    }
    default:
      return id === null ? [202, null] : fail(-32601, `method not found: ${message?.method}`);
  }
}
