// Elpian VM engine: a backend program in Dart (Elpian's Dart subset) or the
// Elpian JavaScript subset, compiled to Elpian bytecode and run on the Elpian
// VM — both inside elpian-wasm built for Node.js with its compiler front-ends
// (`wasm-pack build --target nodejs -- --features compiler`, see the
// Dockerfile). The VM yields at every askHost; the runtime answers and resumes
// it, so platform calls are awaited without blocking the VM's state.

import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import { IDENTIFIER, serial, toolDefinitions } from './contract.mjs';

const require = createRequire(import.meta.url);

/** Where the elpian-wasm Node package is. */
export function elpianPackage() {
  return process.env.ELPIAN_WASM_DIR
    || path.join(path.dirname(fileURLToPath(import.meta.url)), '..', 'vendor', 'elpian');
}

/**
 * A fresh instance of the Elpian wasm module. A front-end that panics on a
 * source traps the instance it runs in (wasm aborts rather than unwinds), so
 * compiling untrusted source gets an instance of its own.
 */
export function loadElpian({ fresh = false } = {}) {
  const entry = require.resolve(path.join(elpianPackage(), 'elpian_wasm.js'));
  if (fresh) delete require.cache[entry];
  const vm = require(entry);
  if (fresh) delete require.cache[entry];
  vm.elpian_wasm_init();
  return vm;
}

/** Compiles an Elpian program to bytecode, in an instance of its own. */
export function compileElpian(language, source) {
  const vm = loadElpian({ fresh: true });
  try {
    return language === 'dart' ? vm.elpian_wasm_compile_dart(source) : vm.elpian_wasm_compile_js(source);
  } catch (error) {
    const message = String(error?.message ?? error);
    throw new Error(/unreachable/.test(message) ? 'the program is outside the Elpian ' + language + ' subset' : message);
  }
}

// --- the VM's typed values ----------------------------------------------------

/** A JSON value as the VM's typed value. */
export function typed(value) {
  if (value === null || value === undefined) return { type: 'null', data: { value: null } };
  if (typeof value === 'boolean') return { type: 'bool', data: { value } };
  if (typeof value === 'number') {
    return Number.isInteger(value) ? { type: 'i64', data: { value } } : { type: 'f64', data: { value } };
  }
  if (typeof value === 'string') return { type: 'string', data: { value } };
  if (Array.isArray(value)) return { type: 'array', data: { value: value.map(typed) } };
  const out = {};
  for (const [k, v] of Object.entries(value)) out[k] = typed(v);
  return { type: 'object', data: { value: out } };
}

/** The VM's rendering of a returned value, as JSON. */
function untyped(text) {
  if (text === '' || text === undefined) return null;
  try {
    return JSON.parse(text);
  } catch {
    return text;
  }
}

let machines = 0;

export async function createElpianEngine(source, { language = 'dart', maxInstructionsPerTurn = 200_000_000, maxMemoryBytes = 64 << 20 } = {}) {
  const bytecode = compileElpian(language, source);
  const vm = loadElpian();
  const id = `tool-${process.pid}-${++machines}`;
  if (!vm.elpian_wasm_create_vm_from_bytecode(id, bytecode)) throw new Error('the Elpian VM refused the program');
  vm.elpian_wasm_set_limits(id, JSON.stringify({ maxInstructionsPerTurn, maxMemoryBytes, maxCallDepth: 256 }));
  let cb = 0;

  // Drives one turn to its end, answering each host call it yields.
  const drive = async (first, host) => {
    let turn = JSON.parse(first);
    while (turn.hasHostCall) {
      const request = JSON.parse(turn.hostCallData);
      let reply;
      try {
        reply = await host(request.apiName, request.payload);
      } catch (error) {
        reply = { error: String(error?.message ?? error) };
      }
      turn = JSON.parse(vm.elpian_wasm_continue_execution(id, JSON.stringify(typed(reply))));
    }
    return untyped(turn.resultValue);
  };

  const run = serial();
  // Module initialisation: top-level code runs once (a warm instance).
  await run(() => drive(vm.elpian_wasm_execute(id), async () => null));

  return {
    engine: 'elpian',
    async list() {
      return run(async () => toolDefinitions(await drive(vm.elpian_wasm_execute_func(id, 'tools', ++cb), async () => null) ?? []));
    },
    async call(name, args, host) {
      if (!IDENTIFIER.test(name)) throw new Error(`invalid microtool ${name}`);
      return run(() => drive(vm.elpian_wasm_execute_func_with_input(id, name, JSON.stringify(typed(args ?? {})), ++cb), host));
    },
    dispose() {
      vm.elpian_wasm_destroy_vm(id);
    },
  };
}
