// ---------------------------------------------------------------------------
// A2UI surfaces and Elpian nodes on the web, the same JSON the app renders:
//   <t-surface>: A2UI v0.9 messages (createSurface / updateComponents /
//     updateDataModel), or {components, data}; event actions reach
//     Aseman.on handlers.
//   <t-tool-frontend tool microtool args>: a tool's own frontend: its
//     generative surface with its actions run by the tool (frontend_action),
//     or, for a tool without one, its result in an automatic view.
//   <t-elpian node>: an Elpian node tree (Flutter widget names, HTML tags,
//     kit nodes; style maps are CSS).
//   <t-data call="Tool/microtool" args into every>: loads a microtool's value
//     into the data model, again when its bound args change.
// ---------------------------------------------------------------------------

/** Component types → elements (A2UI basic + Aseman catalog). */
const A2UI_TAGS = {
  Text: 't-text', Image: 't-image', Icon: 't-icon', Video: 't-video', AudioPlayer: 't-audio-player', Row: 't-row', Column: 't-column',
  List: 't-list', Card: 't-card', Tabs: 't-tabs', Modal: 't-modal', Divider: 't-divider', Button: 't-button', TextField: 't-text-field',
  CheckBox: 't-checkbox', ChoicePicker: 't-choice-picker', Slider: 't-slider', DateTimeInput: 't-date-time-input',
  Chart: 't-chart', Sparkline: 't-sparkline', Gauge: 't-gauge', Heatmap: 't-heatmap', Treemap: 't-treemap', Graph: 't-graph',
  Table: 't-table', DataGrid: 't-data-grid', Stat: 't-stat', KeyValue: 't-key-value', Timeline: 't-timeline', TreeView: 't-tree-view',
  JsonView: 't-json-view', CodeBlock: 't-code-block', Progress: 't-progress', Badge: 't-badge', Tag: 't-tag', Rating: 't-rating',
  Callout: 't-callout', Avatar: 't-avatar', Grid: 't-grid', Wrap: 't-wrap', Stack: 't-stack', Box: 't-box', Center: 't-center',
  Spacer: 't-spacer', AspectRatio: 't-aspect-ratio', Scroll: 't-scroll', Split: 't-split', Section: 't-section', Expandable: 't-expandable',
  Switch: 't-switch', Elpian: 't-elpian', ToolFrontend: 't-tool-frontend', SegmentedControl: 't-segmented-control',
  Dropdown: 't-dropdown', RangeSlider: 't-range-slider', NumberStepper: 't-number-stepper', SearchField: 't-search-field',
  Link: 't-link', IconButton: 't-icon-button', Menu: 't-menu', Steps: 't-steps', Carousel: 't-carousel', Accordion: 't-accordion',
  EmptyState: 't-empty-state', Skeleton: 't-skeleton', Loading: 't-loading', Tooltip: 't-tooltip', AvatarGroup: 't-avatar-group',
  Markdown: 't-markdown', Show: 't-show', Countdown: 't-countdown', Quote: 't-quote', OrderBook: 't-order-book',
  TickerTape: 't-ticker-tape', AllocationBar: 't-allocation-bar', Trend: 't-trend',
};
const STRUCTURAL = new Set(['id', 'component', 'child', 'children', 'weight', 'accessibility', 'trigger', 'content', 'tabs', 'panes', 'fallback', 'items']);

/** Rewrites absolute data paths of a surface's props under its root ({"path": "/x"} → /__surfaces/<id>/x). */
function rooted(v, root) {
  if (v == null || typeof v !== 'object') {
    if (typeof v === 'string' && v.includes('${/')) return v.replace(/\$\{\s*\//g, '${' + root + '/');
    return v;
  }
  if (Array.isArray(v)) return v.map((x) => rooted(x, root));
  const out = {};
  for (const [k, x] of Object.entries(v)) {
    out[k] = k === 'path' && typeof x === 'string' && x.startsWith('/') ? root + x : rooted(x, root);
  }
  return out;
}
/** Models write "${/x}" and "{{x}}" in plain strings: bindings, as the app reads them (genui/runtime/messages.dart). */
function a2uiValue(s) {
  if (typeof s !== 'string' || (!s.includes('${') && !s.includes('{{'))) return s;
  const t = s.replace(/\{\{\s*([A-Za-z0-9_./~\-[\]]+)\s*\}\}/g, (_, p) => '${' + (p.includes('/') ? p : p.replace(/\./g, '/')).replace(/\[/g, '/').replace(/\]/g, '') + '}');
  const whole = /^\$\{\s*([A-Za-z0-9_./~-]+)\s*\}$/.exec(t);
  if (whole) return { path: whole[1] };
  return { call: 'formatString', args: { value: t }, returnType: 'string' };
}
function normalizeProps(v) {
  if (typeof v === 'string') return a2uiValue(v);
  if (Array.isArray(v)) return v.map(normalizeProps);
  if (isMap(v)) { const o = {}; for (const [k, x] of Object.entries(v)) o[k] = k === 'path' || k === 'call' ? x : normalizeProps(x); return o; }
  return v;
}

/** A surface: its components by id, its data model under /__surfaces/<id>, rendered into [host]. */
class Surface {
  constructor(host, id) {
    this.host = host;
    this.id = id || 's' + Math.random().toString(36).slice(2, 9);
    this.root = `/__surfaces/${this.id}`;
    this.components = {};
    this.theme = {};
    host._scope = this.root;
    host.dataset.tHandles = '';
  }
  apply(message) {
    const m = isMap(message) ? message : {};
    if (m.createSurface) { this.theme = asMap(m.createSurface.theme); if (m.createSurface.surfaceId) this.sid = m.createSurface.surfaceId; }
    const upd = m.updateComponents || m.surfaceUpdate;
    if (upd) for (const c of asList(upd.components)) this.addComponent(c);
    const dm = m.updateDataModel || m.dataModelUpdate;
    if (dm) {
      const path = dm.path && dm.path !== '/' ? this.root + (dm.path.startsWith('/') ? dm.path : '/' + dm.path) : this.root;
      const value = dm.value !== undefined ? dm.value : dm.contents;
      if (path === this.root) Aseman.data.set(this.root, value ?? {}); else Aseman.data.set(path, value);
    }
    if (m.beginRendering?.root) this.rootId = m.beginRendering.root;
    if (m.deleteSurface) this.host.replaceChildren();
  }
  addComponent(c) {
    if (!isMap(c) || !c.id) return;
    // v0.8: {id, component: {Type: {props}}} → flat v0.9.
    if (isMap(c.component)) { const [type, props] = Object.entries(c.component)[0] || []; c = { id: c.id, component: type, ...asMap(props), weight: c.weight }; }
    this.components[c.id] = c;
  }
  setData(value) { Aseman.data.set(this.root, value ?? {}); }
  get data() { return Aseman.data.get(this.root); }
  render(rootId) {
    const id = rootId || this.rootId || (this.components.root ? 'root' : Object.keys(this.components)[0]);
    this.host.replaceChildren(id ? this.build(id) : '');
  }
  /** The element of component [id]. */
  build(id, depth = 0) {
    const c = this.components[id];
    if (!c || depth > 60) return h('span', { class: 't-caption' }, c ? '' : `missing component ${id}`);
    const type = c.component;
    const tag = A2UI_TAGS[type] || (customElements.get('t-' + kebab(type || '')) ? 't-' + kebab(type) : null);
    if (!tag) return problem(`Unknown component ${type}`);
    const e = document.createElement(tag);
    const props = {};
    for (const [k, v] of Object.entries(c)) if (!STRUCTURAL.has(k)) props[k] = rooted(normalizeProps(v), this.root);
    if (c.weight != null) props.weight = c.weight;
    if (type === 'Button' && !props.variant && c.primary) props.variant = 'primary';
    if (c.items && type !== 'Accordion' && type !== 'Menu') props.items = rooted(normalizeProps(c.items), this.root);
    if (type === 'Menu') props.items = rooted(c.items, this.root);
    if (type === 'Elpian') { props.node = rooted(c.node ?? c.props?.node, this.root); e._surface = this; }
    e._raw = Object.assign(e._raw || {}, props);
    if (e instanceof TElement) e._attrsRead = true;
    const kid = (cid) => this.build(cid, depth + 1);
    // Children: ids, or a template repeated per item of a bound list.
    const ch = c.children;
    if (Array.isArray(ch)) for (const cid of ch) e.appendChild(kid(cid));
    else if (isMap(ch) && (ch.componentId || ch.template)) this.template(e, ch);
    if (typeof c.child === 'string') e.appendChild(kid(c.child));
    if (type === 'Tabs') asList(c.tabs).forEach((t) => { const tab = document.createElement('t-tab'); tab._raw = { title: rooted(normalizeProps(t.title ?? t.label), this.root), icon: t.icon }; tab._attrsRead = true; if (t.child) tab.appendChild(kid(t.child)); e.appendChild(tab); });
    if (type === 'Split') asList(c.panes).forEach((pane, i) => { if (!pane?.child) return; const k = kid(pane.child); k.dataset.title = asText(pane.title ?? `Pane ${i + 1}`); if (pane.weight != null) k.setAttribute('weight', String(pane.weight)); e.appendChild(k); });
    if (type === 'Modal') { if (c.trigger) { const t = kid(c.trigger); t.setAttribute('slot', 'trigger'); e.appendChild(t); } if (c.content) e.appendChild(kid(c.content)); }
    if (type === 'Accordion') asList(c.items).forEach((it) => { const x = el('expandable', { title: rooted(normalizeProps(it.title), this.root), subtitle: it.subtitle, expanded: it.expanded }); x._attrsRead = true; if (it.child) x.appendChild(kid(it.child)); e.appendChild(x); });
    if (type === 'Show' && c.fallback) { const f = kid(c.fallback); f.setAttribute('slot', 'fallback'); e.appendChild(f); }
    if (type === 'Tooltip' && c.child == null && c.content) e.appendChild(kid(c.content));
    return e;
  }
  /** {componentId, path}: the template once per item, each in its item's scope. */
  template(host, spec) {
    const tplId = spec.componentId ?? spec.template;
    const path = (spec.path ?? '').startsWith('/') ? this.root + spec.path : joinPath(this.root, spec.path);
    const holder = document.createElement('t-for');
    holder._raw = { each: { path } };
    holder._attrsRead = true;
    holder._build = (i) => { const s = document.createElement('t-scope'); s.style.display = 'contents'; s._scope = `${path}/${i}`; s.appendChild(this.build(tplId)); return s; };
    host.appendChild(holder);
  }
}
/**
 * <t-surface>: renders A2UI. Its messages come from the messages prop, a
 * <script type="application/json"> child (messages, or {components, data}),
 * or src (a URL returning them).
 *   surface.apply({updateDataModel: {path: '/price', value: 12}})
 */
define('surface', class extends TElement {
  render() {
    if (this._surface && !this._dirty) return;
    this._dirty = false;
    const inline = this.querySelector(':scope > script[type="application/json"]');
    let msgs = this.p('messages') ?? (inline ? JSON.parse(inline.textContent || '[]') : null);
    if (this._raw.src && !this._loaded) {
      this._loaded = true;
      fetch(this.p('src')).then((r) => r.json()).then((m) => { this._raw.messages = m; this._dirty = true; this.update(); }).catch((e) => this.replaceChildren(problem(e.message)));
      return;
    }
    if (msgs == null && (this._raw.components || this._raw.data)) msgs = { components: this._raw.components, data: this._raw.data };
    this._surface ||= new Surface(this, this.getAttribute('surface-id'));
    const s = this._surface;
    if (isMap(msgs) && !msgs.createSurface && !msgs.updateComponents) {
      s.apply({ updateComponents: { components: msgs.components } });
      if (msgs.data !== undefined) s.setData(msgs.data);
    } else for (const m of asList(msgs)) s.apply(m);
    const out = h('div', { class: 't-column', style: { display: 'contents' } });
    s.host = out; out._scope = s.root; out.dataset.tHandles = '';
    s.render(this.p('root'));
    this.replaceChildren(out);
    this._scope = s.root;
  }
  /** Applies more A2UI messages (components, data) to the surface. */
  apply(...messages) { this._surface ||= new Surface(this); for (const m of messages.flat()) this._surface.apply(m); if (messages.flat().some((m) => m.updateComponents || m.surfaceUpdate)) { this._dirty = true; this.update(); } }
  get surface() { return this._surface; }
  get data() { return this._surface?.data; }
  set data(v) { this._surface ||= new Surface(this); this._surface.setData(v); }
});
Aseman.Surface = Surface;

// ---- automatic views -------------------------------------------------------------------

/** A value as the best view of it: rows → Table, an object → KeyValue, numbers → Stat, text → Markdown. */
function autoView(value, title) {
  if (value == null) return el('empty-state', { title: 'No result', icon: 'inbox' });
  if (Array.isArray(value)) {
    if (value.length && value.every(isMap)) return el('table', { data: value, search: value.length > 8, pageSize: value.length > 25 ? 25 : 0, title });
    if (value.every((x) => typeof x === 'number')) return el('chart', { type: 'line', data: value.map((v, i) => ({ label: i + 1, value: v })), x: 'label', title });
    return el('markdown', { text: value.map((x) => '- ' + asText(x)).join('\n') });
  }
  if (isMap(value)) {
    const entries = Object.entries(value);
    const scalars = entries.filter(([, v]) => v == null || typeof v !== 'object');
    const nested = entries.filter(([, v]) => v != null && typeof v === 'object');
    const col = el('column', {});
    if (title) col.appendChild(el('text', { text: title, variant: 'h5' }));
    const nums = scalars.filter(([, v]) => typeof v === 'number');
    if (nums.length && nums.length <= 4 && scalars.length <= 6) {
      const g = el('grid', { minColumnWidth: 150 });
      for (const [k, v] of nums) g.appendChild(el('card', {}, el('stat', { label: k.replace(/[_-]+/g, ' ').replace(/^\w/, (c) => c.toUpperCase()), value: v })));
      col.appendChild(g);
      const rest = scalars.filter(([, v]) => typeof v !== 'number');
      if (rest.length) col.appendChild(el('key-value', { data: Object.fromEntries(rest) }));
    } else if (scalars.length) col.appendChild(el('key-value', { data: Object.fromEntries(scalars) }));
    for (const [k, v] of nested) col.appendChild(el('section', { title: k.replace(/[_-]+/g, ' ').replace(/^\w/, (c) => c.toUpperCase()) }, autoView(v)));
    return col;
  }
  if (typeof value === 'number') return el('stat', { label: title ?? 'Value', value });
  return el('markdown', { text: asText(value) });
}
Aseman.autoView = autoView;
/** AutoView {value}: a value in the view that fits it. */
component('auto-view', (e, p) => e.replaceChildren(autoView(p.value ?? p.data, p.title)));

// ---- tool frontends ---------------------------------------------------------------------

/**
 * ToolFrontend {tool, microtool?, args?, height?}: the tool's own frontend
 * inside the page. A generative one renders here and its buttons run the
 * tool's actions; a tool without one shows the microtool's result in an
 * automatic view; a static (Elpian program) one opens on the desk.
 */
define('tool-frontend', class extends TElement {
  render() {
    const p = this.props;
    const key = JSON.stringify([p.tool, p.microtool, p.args, p.request]);
    if (key === this._key) return;
    this._key = key;
    if (p.height) this.style.height = px(p.height);
    if (p.height) this.style.overflow = 'auto';
    this.replaceChildren(el('loading', { text: `Loading ${asText(p.tool)}…` }));
    this._load(p).catch((e) => this.replaceChildren(problem(e.message)));
  }
  async _load(p) {
    let fe = null;
    try { fe = await Aseman.frontend(p.tool, { microtool: p.microtool, args: p.args, request: p.request }); } catch (e) { if (!p.microtool) throw e; }
    const mode = fe?.mode;
    if (mode === 'generative' && asList(fe.messages).length) {
      const surface = document.createElement('t-surface');
      surface._raw = { messages: fe.messages };
      surface._attrsRead = true;
      // The tool runs its frontend's actions and answers with the new data.
      surface.addEventListener('t-action', (ev) => {
        ev.stopPropagation();
        const { name, context } = ev.detail;
        busy(ev.target, async () => {
          const out = await Aseman.frontendAction(p.tool, name, { context, data: surface.data ?? {}, microtool: p.microtool, args: p.args, template: fe.template });
          if (out && out.data) surface.data = out.data;
          this.emit('t-frontend-action', { name, context, data: out?.data });
        });
      });
      this.replaceChildren(surface);
      return;
    }
    if (p.microtool) {
      const value = await Aseman.call(p.tool, p.microtool, p.args || {});
      this.replaceChildren(autoView(value, p.title));
      return;
    }
    const open = el('button', { text: 'Open on the desk', icon: 'open_in_new', variant: 'tonal' });
    open.addEventListener('t-press', () => busy(open, () => Aseman.show(p.tool, { microtool: p.microtool, args: p.args })));
    this.replaceChildren(el('empty-state', { icon: 'apps', title: asText(p.tool), text: 'This tool has its own app, which opens on the desk.' }, open));
  }
});

// ---- elpian nodes ---------------------------------------------------------------------------

const HTML_TAGS = new Set('a abbr address article aside audio b blockquote br button canvas caption cite code data datalist dd del details dfn dialog div dl dt em embed fieldset figcaption figure footer form h1 h2 h3 h4 h5 h6 header hr i iframe img input ins kbd label legend li main map mark meter nav object ol optgroup option output p param picture pre progress q s samp section select small source span strong sub summary sup table tbody td textarea tfoot th thead time tr track u ul var video area'.split(' '));
const ELPIAN_ALIAS = { Container: 'container', ElevatedButton: 'button', TextButton: 'button', OutlinedButton: 'button', FilledButton: 'button',
  ListView: 'list-view', GridView: 'grid-view', InkWell: 'inkwell', CircularProgressIndicator: 'circular-progress-indicator',
  LinearProgressIndicator: 'linear-progress-indicator', ClipRRect: 'clip-rrect', SizedBox: 'sized-box', Checkbox: 'checkbox',
  TextField: 'text-field', AppBar: 'app-bar', Canvas: 'canvas', CanvasWidget: 'canvas', CachedCanvas: 'cached-canvas',
  MathExpression: 'math-expression', VerticalDivider: 'vertical-divider', Tooltip: 'tooltip', Scope: 'scope' };

/** An Elpian node tree ({type, props, style, children, events, key}) as DOM. */
function elpian(node, surface) {
  if (node == null) return document.createTextNode('');
  if (typeof node !== 'object') return document.createTextNode(asText(node));
  if (Array.isArray(node)) { const f = document.createDocumentFragment(); node.forEach((n) => f.appendChild(elpian(n, surface))); return f; }
  if (node.slot != null && surface) return surface.build(node.slot);
  const type = asText(node.type ?? node.tag ?? 'div');
  const props = { ...asMap(node.props) };
  const style = node.style ?? props.style;
  delete props.style;
  let e;
  if (HTML_TAGS.has(type.toLowerCase()) && type === type.toLowerCase()) {
    e = document.createElement(type);
    for (const [k, v] of Object.entries(props)) {
      if (['text', 'data', 'content', 'innerText'].includes(k)) e.textContent = asText(resolve(v, scopeOf(e)));
      else if (k === 'src' || k === 'href') e.setAttribute(k, mediaUrl(v));
      else if (v === true) e.setAttribute(k, '');
      else if (v != null && v !== false && typeof v !== 'object') e.setAttribute(kebab(k), asText(v));
    }
  } else {
    const name = ELPIAN_ALIAS[type] || kebab(type);
    e = document.createElement(customElements.get('t-' + name) ? 't-' + name : 'div');
    if (e instanceof TElement) {
      e._raw = { ...props, ...(isMap(style) ? { styles: style } : {}) };
      if ((type === 'Text' || type === 'text') && props.text == null && props.data == null && node.text != null) e._raw.text = node.text;
      e._attrsRead = true;
    }
  }
  if (isMap(style) && !(e instanceof TElement)) applyStyle(e, style);
  if (typeof style === 'string') e.style.cssText = style;
  if (node.key) e.dataset.key = node.key;
  // Events: an action (A2UI or Aseman call), or a name reported as a t-elpian event.
  for (const [ev, handler] of Object.entries(asMap(node.events))) {
    const domEv = { tap: 'click', onTap: 'click', onClick: 'click', onPressed: 'click', onChanged: 'change', onChange: 'change', onSubmit: 'submit', onInput: 'input' }[ev] || ev.replace(/^on/, '').toLowerCase();
    e.addEventListener(domEv, (x) => {
      const value = x.target?.value ?? x.detail?.value;
      if (isMap(handler) || Array.isArray(handler)) busy(e, () => runAction(handler, e, { value }));
      else e.dispatchEvent(new CustomEvent('t-elpian-event', { bubbles: true, detail: { name: handler, type: ev, key: node.key, value } }));
    });
    if (domEv === 'click' && !(e instanceof TElement)) e.style.cursor = 'pointer';
  }
  for (const c of asList(node.children)) e.appendChild(elpian(c, surface));
  if (node.child) e.appendChild(elpian(node.child, surface));
  return e;
}
Aseman.elpian = elpian;
/** Elpian {node}: an Elpian node tree (inside a surface, {"slot": id} places a component). */
component('elpian', (e, p) => {
  const key = JSON.stringify(e._raw.node);
  if (key === e._key) return;
  e._key = key;
  e.replaceChildren(elpian(e._raw.node ?? (e.querySelector('script[type="application/json"]') ? JSON.parse(e.querySelector('script[type="application/json"]').textContent) : null), e._surface));
});

// ---- data loading ------------------------------------------------------------------------

/**
 * Data {call="Tool/microtool", args (bindings re-run it when they change),
 * into="/path", every?: seconds, lazy?}: loads a microtool's value into the
 * data model; /path__loading and /path__error say how it went.
 */
define('data', class extends TElement {
  render() {
    const call = this.getAttribute('call') ?? this.p('call');
    const into = this.getAttribute('into') ?? this.p('into');
    if (!call || !into) return;
    const args = resolve(this._args(), scopeOf(this));
    const key = JSON.stringify([call, args]);
    if (key === this._key) return;
    this._key = key;
    if (this.hasAttribute('lazy') && !this._kicked) return;
    this.load(args);
    clearInterval(this._timer);
    const every = asNum(this.p('every'));
    if (every) this._timer = setInterval(() => { if (!document.hidden) this.load(resolve(this._args(), scopeOf(this))); }, every * 1000);
  }
  _args() { return asMap(this._raw.args ?? parseAttr(this.getAttribute('args') || '{}')); }
  /** Loads it again now. */
  async load(args = resolve(this._args(), scopeOf(this))) {
    this._kicked = true;
    const [tool, microtool] = splitCall(this.getAttribute('call') ?? this.p('call'));
    const into = joinPath(scopeOf(this), this.getAttribute('into') ?? this.p('into'));
    const seq = (this._seq = (this._seq || 0) + 1);
    Aseman.data.set(into + '__loading', true);
    try {
      const v = await Aseman.call(tool, microtool, args);
      if (seq !== this._seq) return;
      Aseman.data.batch(() => { Aseman.data.set(into, v); Aseman.data.set(into + '__error', null); Aseman.data.set(into + '__loading', false); });
      this.emit('t-result', { tool, microtool, args, result: v });
    } catch (e) {
      if (seq !== this._seq) return;
      Aseman.data.batch(() => { Aseman.data.set(into + '__error', e.message); Aseman.data.set(into + '__loading', false); });
      this.emit('t-error', { error: e });
      if (!this.hasAttribute('quiet')) toast(e.message, { status: 'critical' });
    }
  }
  cleanup() { clearInterval(this._timer); this._key = null; }
});
