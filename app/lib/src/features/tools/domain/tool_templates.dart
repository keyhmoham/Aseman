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

  /// A static frontend built from the UI kit: stat tiles, charts and a
  /// table whose tapped row is shown in detail. The numbers come from the
  /// starter backend's `counter`; the rest is sample data to replace.
  static const String jsDashboardFrontend = r'''
// The UI kit's nodes (Chart, DataGrid, Stat, Gauge, Graph, Heatmap, Treemap,
// Timeline, KeyValue, Tag, Progress, ResponsiveGrid, Section…) sit next to
// every Flutter and HTML node. A tap on a chart or a row sends the node's
// `select` event; its data carries the tapped `row` and `index`.
var sales = [
  { month: 'Jan', online: 120, stores: 80 },
  { month: 'Feb', online: 135, stores: 76 },
  { month: 'Mar', online: 160, stores: 90 },
  { month: 'Apr', online: 158, stores: 95 },
];
var products = [
  { name: 'Keyboard', units: 1280, revenue: 89600, change: 0.084, trend: [3, 4, 4, 6, 7] },
  { name: 'Mouse', units: 2210, revenue: 66300, change: -0.021, trend: [6, 5, 5, 4, 4] },
  { name: 'Monitor', units: 340, revenue: 101660, change: 0.152, trend: [1, 2, 2, 3, 5] },
];
var picked = null;

// Event handlers receive the VM's typed values: unwrap them to plain JSON.
function plain(v) {
  if (v === null || typeof v !== 'object') return v;
  if (v.type && v.data && 'value' in v.data) v = v.data.value;
  if (Array.isArray(v)) return v.map(plain);
  if (v && typeof v === 'object') {
    var out = {};
    for (var k in v) out[k] = plain(v[k]);
    return out;
  }
  return v;
}

function counter() {
  var raw = askHost('tool.call', ['counter', {}]);
  var value = JSON.parse(raw).data.value;
  return value && value.greeted !== undefined ? value.greeted : 0;
}

function view() {
  return { type: 'Column', props: { style: { padding: '16', gap: '12' } }, children: [
    { type: 'ResponsiveGrid', props: { minColumnWidth: 180 }, children: [
      { type: 'Stat', props: { label: 'Revenue', value: 257560, format: 'currency:USD:0', delta: 0.064, deltaFormat: '+percent:1', deltaLabel: 'vs last month', trend: [4, 5, 5, 6, 7] } },
      { type: 'Stat', props: { label: 'Greetings given', value: counter(), icon: 'chat' } },
      { type: 'Gauge', props: { value: 72, label: 'Stock level', thresholds: [{ value: 80, status: 'warning' }] } },
    ] },
    { type: 'ResponsiveGrid', props: { minColumnWidth: 280 }, children: [
      { type: 'Chart', props: { type: 'bar', title: 'Sales by channel', data: sales, x: 'month', series: ['online', 'stores'], stacked: true } },
      { type: 'Chart', props: { type: 'donut', title: 'Revenue share', data: products, label: 'name', value: 'revenue', format: 'compact' } },
    ] },
    { type: 'DataGrid', props: { title: 'Products', data: products, search: true, columns: [
      { field: 'name' },
      { field: 'units', type: 'number' },
      { field: 'revenue', type: 'number', format: 'currency:USD:0' },
      { field: 'change', type: 'trend', format: 'percent:1' },
      { field: 'trend', type: 'sparkline' },
    ] }, events: { select: 'pick' } },
    picked
      ? { type: 'KeyValue', props: { items: [
          { label: 'Product', value: picked.name },
          { label: 'Units', value: picked.units },
          { label: 'Change', value: picked.change, type: 'trend', format: 'percent:1' },
        ] } }
      : { type: 'Text', props: { text: 'Tap a product for details.', style: { color: '#888' } } },
  ] };
}

function pick(event) {
  var e = plain(event);
  picked = e && e.data ? e.data.row : null;
  askHost('render', JSON.stringify(view()));
}

askHost('render', JSON.stringify(view()));
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
