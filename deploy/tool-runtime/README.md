# Tool runtime

Runs a Tradera tool's backend program — written for the **Elpian VM** (Dart or
the Elpian JavaScript subset) or for **QuickJS** (plain JavaScript) — and
serves its microtools over MCP (`POST /mcp`, JSON-RPC: `initialize`,
`tools/list`, `tools/call`).

| Use | How it runs |
|---|---|
| **Managed** tools | Nomad runs this image as a service of its own on the stack's network (`tool-<key>:8790`); the node calls it there. |
| **Installed** tools | The sandbox computer image carries this runtime at `/opt/tradera-tool-runtime`; the node writes the program into the space's sandbox and starts it there, reaching it through the space's gateway proxy. |
| The node's **compiler** | `node server.mjs --compiler` (the `tool-runtime` compose service): compiles static Elpian frontends to bytecode and lists the microtools a backend program declares. |

Docker backends are not run by this image: their own image serves MCP.

## Writing a backend

A program declares its microtools with `tools()` and implements each as a
function of the same name. `askHost` is its only way out.

```js
// QuickJS (or the Elpian JS subset)
function tools() {
  return [{
    name: 'forecast',
    description: 'Weather forecast for a city',
    input: { type: 'object', properties: { city: { type: 'string' } }, required: ['city'] },
  }];
}

function forecast(args) {
  var ctx = askHost('tradera.context', null);   // who asks, from which space and room
  askHost('tradera.send', { body: ctx.actor + ' asked about ' + args.city });
  return { city: args.city, summary: 'sunny', high: 24 };
}
```

```dart
// Elpian VM (Dart subset)
List tools() => [
  {'name': 'forecast', 'description': 'Weather forecast for a city',
   'input': {'type': 'object', 'properties': {'city': {'type': 'string'}}}},
];

Map forecast(Map args) {
  var ctx = askHost('tradera.context', null);
  return {'city': args['city'], 'summary': 'sunny', 'asked_by': ctx['actor']};
}
```

| Host API | |
|---|---|
| `tradera.context` | `{tool, actor, space, room, agent}` of the call — the person asking, and the agent when one asks for them |
| `tradera.call` | `{namespace, action, body}`: a platform action run as the tool, inside the call's space and room (`spaces.message_send`, `spaces.ask`, `spaces.message_list`, `spaces.tools_list`, `spaces.members_list`, `spaces.room_get`, `users.account_get`, `bots.kv_*`) |
| `tradera.send` | `{body, room?}`: post into the room the tool was called from |
| `tradera.ask` | `{bot, body}`: ask another tool or agent of the space |
| `tradera.kv.get` / `.set` / `.delete` | the tool's own key-value store |
| `log` | a line in the runtime's log |

What a microtool returns is its result (an object becomes MCP
`structuredContent` too); a thrown error is an `isError` result. Calls run one
at a time and the program keeps module state between them, so never keep one
caller's data for the next.

## Develop

```bash
npm install
# The Elpian VM for Node.js (optional: Elpian tests skip without it)
(cd ../../../elpian/rust/crates/elpian-wasm && \
  wasm-pack build --release --target nodejs --out-dir "$PWD/vendor/elpian" -- --features compiler)
npm test
```
