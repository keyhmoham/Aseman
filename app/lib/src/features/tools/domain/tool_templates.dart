/// Starter programs the tool form opens with, one per runtime, so a new tool
/// works before its author changes a line. They follow the backend contract
/// of the tool runtime (deploy/tool-runtime): `tools()` declares the
/// microtools, one function per microtool, `askHost` for the platform.
abstract final class ToolTemplates {
  static String backend(String runtime, String language) {
    if (runtime == 'elpian' && language == 'dart') return dartBackend;
    return jsBackend;
  }

  static const String jsBackend = r'''
// Microtools this tool offers: agents call them as tools, the frontend as
// its API.
function tools() {
  return [
    {
      name: 'greet',
      description: 'Greets someone by name',
      input: { type: 'object', properties: { name: { type: 'string' } }, required: ['name'] },
    },
    { name: 'counter', description: 'How many greetings this tool gave' },
  ];
}

var greeted = 0;

function greet(args) {
  // Who asks, from which space and room (an agent acting for them is named).
  var ctx = askHost('tradera.context', null);
  greeted++;
  return { text: 'Hello, ' + args.name + '!', asked_by: ctx.actor, space: ctx.space };
}

function counter() {
  return { greeted: greeted };
}
''';

  static const String dartBackend = r'''
// Microtools this tool offers: agents call them as tools, the frontend as
// its API.
List tools() => [
  {
    'name': 'greet',
    'description': 'Greets someone by name',
    'input': {'type': 'object', 'properties': {'name': {'type': 'string'}}},
  },
];

Map greet(Map args) {
  // Who asks, from which space and room (an agent acting for them is named).
  var ctx = askHost('tradera.context', null);
  return {'text': 'Hello, ' + args['name'] + '!', 'asked_by': ctx['actor']};
}
''';

  /// A static frontend: renders, and calls the backend's `greet` microtool.
  static const String jsFrontend = r'''
function view(reply) {
  return { type: 'Column', props: { style: { padding: '20', gap: '12' } }, children: [
    { type: 'Text', props: { text: 'Say hello', style: { fontSize: '22', fontWeight: 'bold' } } },
    { type: 'Button', props: { text: 'Greet Ada', className: 'primary' }, events: { tap: 'greet' } },
    { type: 'Text', props: { text: reply } }
  ] };
}

function greet() {
  // tool.call reaches this tool's backend, whichever mode it runs in.
  var raw = askHost('tool.call', ['greet', { name: 'Ada' }]);
  var value = JSON.parse(raw).data.value;
  var text = value && value.text ? value.text : JSON.stringify(value);
  askHost('render', JSON.stringify(view(text)));
}

askHost('render', JSON.stringify(view('Press the button.')));
''';

  /// A generative frontend's skill: what to show and how.
  static const String skill = '''
Show a compact card titled "Greeter".
- A text field for a name (bound to /form/name) and a "Greet" button that
  calls the greet microtool with that name and shows its text below.
- Under it, show how many greetings were given (the counter microtool),
  refreshed after each greeting.
''';
}
