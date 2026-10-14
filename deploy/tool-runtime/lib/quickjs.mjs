// QuickJS engine: a backend program in plain JavaScript, run in a QuickJS
// context compiled to WebAssembly (quickjs-emscripten). The program sees no
// Node, no network and no files: only askHost, which the runtime answers.
// askHost is synchronous to the program and asynchronous here (asyncify), so
// a program reads naturally while the runtime awaits the platform.

import { newQuickJSAsyncWASMModule } from 'quickjs-emscripten';
import { IDENTIFIER, serial, toolDefinitions } from './contract.mjs';

const PRELUDE = `
globalThis.askHost = function (api, value) {
  var raw = __askHost(String(api), JSON.stringify(value === undefined ? null : value));
  var reply = JSON.parse(raw);
  if (reply && reply.__error) throw new Error(reply.__error);
  return reply;
};
globalThis.console = { log: function () { askHost('log', Array.prototype.join.call(arguments, ' ')); } };
`;

export async function createQuickJSEngine(source, { memoryBytes = 64 << 20, callMillis = 30000 } = {}) {
  const module = await newQuickJSAsyncWASMModule();
  const runtime = module.newRuntime();
  runtime.setMemoryLimit(memoryBytes);
  runtime.setMaxStackSize(1 << 20);
  let deadline = Infinity;
  runtime.setInterruptHandler(() => Date.now() > deadline);
  const vm = runtime.newContext();
  let serve = async () => null;

  const askHost = vm.newAsyncifiedFunction('__askHost', async (apiH, payloadH) => {
    const api = vm.getString(apiH);
    let payload = null;
    try {
      payload = JSON.parse(vm.getString(payloadH));
    } catch {
      payload = null;
    }
    try {
      const value = await serve(api, payload);
      return vm.newString(JSON.stringify(value === undefined ? null : value));
    } catch (error) {
      return vm.newString(JSON.stringify({ __error: String(error?.message ?? error) }));
    }
  });
  vm.setProp(vm.global, '__askHost', askHost);
  askHost.dispose();

  const evaluate = async (code, filename) => {
    deadline = Date.now() + callMillis;
    try {
      let result = await vm.evalCodeAsync(code, filename);
      let handle = vm.unwrapResult(result);
      // An async microtool returns a promise: settle it.
      if (vm.typeof(handle) === 'object' && vm.getProp(handle, 'then').consume((t) => vm.typeof(t)) === 'function') {
        const settled = vm.resolvePromise(handle);
        handle.dispose();
        runtime.executePendingJobs();
        handle = vm.unwrapResult(await settled);
      }
      const value = vm.dump(handle);
      handle.dispose();
      return value;
    } finally {
      deadline = Infinity;
    }
  };

  const run = serial();
  await run(() => evaluate(PRELUDE, 'prelude.js'));
  await run(() => evaluate(source, 'program.js'));

  return {
    engine: 'quickjs',
    async list() {
      return run(async () => {
        serve = async () => null;
        const raw = await evaluate('JSON.stringify(typeof tools === "function" ? tools() : [])', 'list.js');
        return toolDefinitions(JSON.parse(raw));
      });
    },
    async call(name, args, host) {
      if (!IDENTIFIER.test(name)) throw new Error(`invalid microtool ${name}`);
      return run(async () => {
        serve = host;
        try {
          const raw = await evaluate(
            `(function () { if (typeof ${name} !== "function") throw new Error("no microtool ${name}");` +
              ` var r = ${name}(${JSON.stringify(args ?? {})});` +
              ` return (r && typeof r.then === "function") ? r.then(function (v) { return JSON.stringify(v === undefined ? null : v); }) : JSON.stringify(r === undefined ? null : r); })()`,
            `${name}.js`,
          );
          return JSON.parse(raw);
        } finally {
          serve = async () => null;
        }
      });
    },
    dispose() {
      // The context only: freeing the runtime too trips over the asyncified
      // function's host reference. Each engine has a wasm module of its own,
      // which is collected with it.
      if (vm.alive) vm.dispose();
    },
  };
}
