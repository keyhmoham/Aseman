// The contract between an Aseman tool backend program and its runtime — the
// same for the Elpian VM (Dart or the JS subset) and QuickJS (JavaScript):
//
//   tools()              returns the microtools the program offers:
//                        [{ name, description, input }] — input is the JSON
//                        schema of the microtool's arguments.
//   <name>(args)         one function per microtool, called with its
//                        arguments; what it returns is the microtool's result.
//   askHost(api, value)  the program's only way out, answered by the runtime:
//
//     aseman.context    → { tool, actor, space, room, agent } of the call:
//                          who asks (a person; an agent acting for them is
//                          named apart), from which space and room
//     aseman.call       { namespace, action, body } → a platform action run
//                          as the tool inside the call's scope (spaces.
//                          message_send, spaces.ask, spaces.message_list, ...)
//     aseman.send       { body, room? } → posts a message into the room
//     aseman.ask        { bot, body } → asks another tool or agent of the space
//     aseman.kv.get / aseman.kv.set / aseman.kv.delete
//                        the tool's own key-value store
//     aseman.fetch      { url, method?, headers?, body? } → { status, ok,
//                          contentType, json, text }: an HTTP request to the
//                          public internet (see lib/fetch.mjs)
//     log                a line in the runtime's log
//
// Calls are served one at a time per backend: a program keeps module state
// between calls (a warm instance), so it must not keep one caller's data for
// the next.

export const IDENTIFIER = /^[A-Za-z_$][A-Za-z0-9_$]*$/;

/** Normalizes what a program's tools() returned into MCP tool definitions. */
export function toolDefinitions(declared) {
  if (!Array.isArray(declared)) {
    throw new Error('tools() must return a list of {name, description, input}');
  }
  return declared.map((t) => {
    if (!t || typeof t.name !== 'string' || !IDENTIFIER.test(t.name)) {
      throw new Error(`invalid microtool name: ${JSON.stringify(t && t.name)}`);
    }
    const schema = t.input && typeof t.input === 'object' ? t.input : { type: 'object', properties: {} };
    return {
      name: t.name,
      description: typeof t.description === 'string' ? t.description : '',
      inputSchema: schema,
    };
  });
}

/**
 * Serves the host APIs a program calls. [scope] is the call's execution scope;
 * [node] performs platform actions in it (absent when describing a program);
 * [fetch] performs a program's outbound HTTP (absent: no network).
 */
export function hostApis(scope, node, log = console.log, fetch = null) {
  const call = async (namespace, action, body) => {
    if (!node) throw new Error('no platform here: the program is only being described');
    return node.call(scope, namespace, action, body ?? {});
  };
  return async (api, payload) => {
    switch (api) {
      case 'aseman.context':
        return {
          tool: scope.tool ?? '', actor: scope.actor ?? '', space: scope.space ?? '',
          room: scope.room ?? '', agent: scope.agent ?? '',
        };
      case 'aseman.call':
        return call(payload?.namespace, payload?.action, payload?.body);
      case 'aseman.send':
        return call('spaces', 'message_send', { body: String(payload?.body ?? ''), ...(payload?.room ? { room: payload.room } : {}) });
      case 'aseman.ask':
        return call('spaces', 'ask', { bot: payload?.bot, body: typeof payload?.body === 'string' ? payload.body : JSON.stringify(payload?.body ?? '') });
      case 'aseman.kv.get':
        return call('bots', 'kv_get', { key: payload?.key ?? payload });
      case 'aseman.kv.set':
        return call('bots', 'kv_set', { key: payload?.key, value: payload?.value });
      case 'aseman.kv.delete':
        return call('bots', 'kv_delete', { key: payload?.key ?? payload });
      case 'aseman.fetch':
        if (!fetch) throw new Error('this runtime gives programs no network');
        return fetch(payload);
      case 'log':
        log(`[tool] ${typeof payload === 'string' ? payload : JSON.stringify(payload)}`);
        return null;
      default:
        throw new Error(`unknown host API ${api}`);
    }
  };
}

/** Runs calls one at a time (an engine instance is single-threaded). */
export function serial() {
  let tail = Promise.resolve();
  return (fn) => {
    const run = tail.then(fn, fn);
    tail = run.catch(() => {});
    return run;
  };
}
