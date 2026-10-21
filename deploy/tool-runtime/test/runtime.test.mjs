import assert from 'node:assert/strict';
import { existsSync } from 'node:fs';
import http from 'node:http';
import path from 'node:path';
import test from 'node:test';
import { elpianPackage } from '../lib/elpian.mjs';
import { backendHandler, compilerHandler, createEngine } from '../server.mjs';

const QUICKJS = `
function tools() {
  return [
    { name: 'greet', description: 'Greets someone', input: { type: 'object', properties: { name: { type: 'string' } } } },
    { name: 'announce', description: 'Posts into the room it was asked from' },
    { name: 'later', description: 'An async microtool' },
    { name: 'fail', description: 'Always fails' },
  ];
}
var calls = 0;
function greet(args) {
  calls++;
  var ctx = askHost('aseman.context', null);
  return { text: 'hello ' + args.name, actor: ctx.actor, space: ctx.space, calls: calls };
}
function announce(args) {
  return askHost('aseman.send', { body: 'news: ' + args.text });
}
async function later(args) { return { doubled: args.n * 2 }; }
function fail() { throw new Error('nope'); }
`;

const DART = `
List tools() => [
  {'name': 'greet', 'description': 'Greets someone', 'input': {'type': 'object', 'properties': {'name': {'type': 'string'}}}},
  {'name': 'announce', 'description': 'Posts into the room'},
];
Map greet(Map args) {
  var ctx = askHost('aseman.context', null);
  return {'text': 'hello ' + args['name'], 'actor': ctx['actor'], 'space': ctx['space']};
}
Map announce(Map args) {
  return askHost('aseman.send', {'body': 'news: ' + args['text']});
}
`;

const hasElpian = existsSync(path.join(elpianPackage(), 'elpian_wasm.js'));

function fakeNode() {
  const calls = [];
  return {
    calls,
    async call(scope, namespace, action, body) {
      calls.push({ scope, namespace, action, body });
      return { ok: true, message_id: 'm1' };
    },
  };
}

async function serve(handler) {
  const server = http.createServer(handler);
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  const { port } = server.address();
  const rpc = async (method, params, headers = {}) => {
    const res = await fetch(`http://127.0.0.1:${port}/mcp`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', ...headers },
      body: JSON.stringify({ jsonrpc: '2.0', id: 1, method, params }),
    });
    return { status: res.status, body: res.status === 202 ? null : await res.json() };
  };
  return { server, port, rpc };
}

const SCOPE = {
  'x-aseman-token': 'secret', 'x-aseman-tool': 'b1', 'x-aseman-actor': 'alice',
  'x-aseman-space': 'S', 'x-aseman-room': 'R', 'x-aseman-scope': 'scope-token',
};

for (const [label, program, available] of [
  ['quickjs', { engine: 'quickjs', source: QUICKJS }, true],
  ['elpian (dart)', { engine: 'elpian', language: 'dart', source: DART }, hasElpian],
]) {
  test(`${label}: serves its microtools over MCP in the caller's scope`, { skip: !available && 'elpian-wasm not built (set ELPIAN_WASM_DIR)' }, async () => {
    const engine = await createEngine(program);
    const tools = await engine.list();
    assert.ok(tools.some((t) => t.name === 'greet' && t.description === 'Greets someone'));
    const node = fakeNode();
    const { server, rpc } = await serve(backendHandler({ engine, tools, token: 'secret', node }));
    try {
      assert.equal((await rpc('tools/list', {}, { 'x-aseman-token': 'wrong' })).status, 401, 'only the node may call');
      const init = await rpc('initialize', {}, SCOPE);
      assert.equal(init.body.result.serverInfo.name, 'aseman-tool-runtime');
      const listed = await rpc('tools/list', {}, SCOPE);
      assert.deepEqual(listed.body.result.tools.map((t) => t.name).slice(0, 2), ['greet', 'announce']);

      const greeted = await rpc('tools/call', { name: 'greet', arguments: { name: 'bob' } }, SCOPE);
      const value = greeted.body.result.structuredContent;
      assert.equal(value.text, 'hello bob');
      assert.equal(value.actor, 'alice');
      assert.equal(value.space, 'S');

      const announced = await rpc('tools/call', { name: 'announce', arguments: { text: 'up' } }, SCOPE);
      assert.equal(announced.body.result.isError, false);
      assert.equal(node.calls.length, 1);
      assert.equal(node.calls[0].action, 'message_send');
      assert.equal(node.calls[0].body.body, 'news: up');
      assert.equal(node.calls[0].scope.token, 'scope-token', 'callbacks carry the call scope');

      const unknown = await rpc('tools/call', { name: 'nope', arguments: {} }, SCOPE);
      assert.ok(unknown.body.error);
    } finally {
      server.close();
      engine.dispose();
    }
  });
}

test('quickjs: async microtools, errors and warm module state', async () => {
  const engine = await createEngine({ engine: 'quickjs', source: QUICKJS });
  const host = async (api) => (api === 'aseman.context' ? { actor: 'a', space: 's' } : null);
  assert.deepEqual(await engine.call('later', { n: 21 }, host), { doubled: 42 });
  await assert.rejects(engine.call('fail', {}, host), /nope/);
  const first = await engine.call('greet', { name: 'x' }, host);
  const second = await engine.call('greet', { name: 'x' }, host);
  assert.equal(second.calls, first.calls + 1, 'module state survives between calls');
  engine.dispose();
});

test('quickjs: a runaway program is interrupted', async () => {
  const { createQuickJSEngine } = await import('../lib/quickjs.mjs');
  const engine = await createQuickJSEngine('function tools(){return [{name:"spin"}];} function spin(){ for(;;){} }', { callMillis: 200 });
  await assert.rejects(engine.call('spin', {}, async () => null), /interrupted/i);
  engine.dispose();
});

test('compiler role compiles Elpian programs and describes backends', { skip: !hasElpian && 'elpian-wasm not built' }, async () => {
  const server = http.createServer(compilerHandler());
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  const base = `http://127.0.0.1:${server.address().port}`;
  try {
    const compiled = await (await fetch(`${base}/compile`, { method: 'POST', body: JSON.stringify({ language: 'dart', source: DART }) })).json();
    assert.ok(Buffer.from(compiled.bytecode, 'base64').length > 100);
    const described = await (await fetch(`${base}/describe`, { method: 'POST', body: JSON.stringify({ engine: 'quickjs', source: QUICKJS }) })).json();
    assert.equal(described.tools.length, 4);
    const broken = await fetch(`${base}/compile`, { method: 'POST', body: JSON.stringify({ language: 'js', source: 'function (' }) });
    assert.equal(broken.status, 422);
    // A source the compiler trapped on did not poison the next compile.
    const again = await fetch(`${base}/compile`, { method: 'POST', body: JSON.stringify({ language: 'js', source: 'function f(a) { return a; }' }) });
    assert.equal(again.status, 200);
  } finally {
    server.close();
  }
});
