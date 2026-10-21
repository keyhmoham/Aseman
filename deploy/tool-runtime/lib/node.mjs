// The node, as a backend reaches it: the tool runtime gateway of the tools
// namespace (services/plugins/actions/tools/runtime.go).

import { readFile } from 'node:fs/promises';

export class NodeGateway {
  constructor({ url, toolId, token, fetchImpl = fetch }) {
    this.url = String(url || '').replace(/\/+$/, '');
    this.toolId = toolId;
    this.token = token;
    this.fetch = fetchImpl;
  }

  /** The backend's program: { engine, language, source }. */
  async program() {
    const res = await this.fetch(`${this.url}/tools/v1/runtime/program`, {
      headers: { Authorization: `Bearer ${this.token}`, 'X-Aseman-Tool': this.toolId },
    });
    const body = await res.json().catch(() => ({}));
    if (!res.ok) throw new Error(body?.error?.message || `program fetch failed: ${res.status}`);
    return body;
  }

  /** A platform action run as the tool in a call's scope. */
  async call(scope, namespace, action, body) {
    if (!scope.token) throw new Error('this call carries no scope to act in');
    const res = await this.fetch(`${this.url}/tools/v1/runtime/host`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${scope.token}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ namespace, action, body }),
    });
    const out = await res.json().catch(() => ({}));
    if (!res.ok) throw new Error(out?.error?.message || `${namespace}.${action} failed: ${res.status}`);
    return out;
  }
}

/**
 * Loads the program to run: from a file (a backend installed into a space
 * sandbox has it written next to it) or from the node, retrying while the
 * node is still recording the tool that is starting.
 */
export async function loadProgram({ file, gateway, attempts = 30, wait = 2000, log = console.log }) {
  if (file) return JSON.parse(await readFile(file, 'utf8'));
  let last;
  for (let i = 0; i < attempts; i++) {
    try {
      return await gateway.program();
    } catch (error) {
      last = error;
      log(`[runtime] program not available yet: ${error.message}`);
      await new Promise((r) => setTimeout(r, wait));
    }
  }
  throw last;
}
