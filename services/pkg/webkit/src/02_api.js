// ---------------------------------------------------------------------------
// The Tradera API from a page: the space's tools' microtools, called as the
// person viewing the page, through the preview gateway the page is served by
// (<preview>/_tradera/api/…, authorized by the preview's own sign-in), the
// way a frontend calls its backend. Also the app's theme, followed live.
// ---------------------------------------------------------------------------

class TraderaError extends Error {
  constructor(message, code, status) { super(message); this.name = 'TraderaError'; this.code = code; this.status = status; }
}
Tradera.Error = TraderaError;

const config = { base: null, mock: null, timeout: 120000 };

/** The preview's prefix (/v1/proxy/<id>), when the page is served through one. */
function previewPrefix() {
  if (typeof window.__traderaProxy === 'string') return window.__traderaProxy.replace(/\/$/, '');
  const m = /^(\/v1\/proxy\/[0-9a-fA-F]{32})(\/|$)/.exec(location.pathname);
  return m ? m[1] : '';
}
const apiBase = () => config.base ?? previewPrefix() + '/_tradera/api/';

/**
 * Tradera.configure({base, mock}): base overrides where the API is (a page
 * served elsewhere); mock answers calls locally while developing without the
 * gateway: {weather: {forecast: (args) => ({…})}}.
 */
Tradera.configure = (opts) => { Object.assign(config, opts || {}); return config; };

/** An MCP tool result as its value (as the app's microtoolValue). */
function microtoolValue(result) {
  if (!isMap(result) || !('content' in result || 'structuredContent' in result)) return result;
  const text = asList(result.content).filter((b) => isMap(b) && b.type === 'text').map((b) => asText(b.text)).join('\n');
  if (result.isError === true) throw new TraderaError(text || 'the tool reported an error', 'tool_error');
  if (result.structuredContent != null) return result.structuredContent;
  try { return JSON.parse(text); } catch { return text; }
}

async function api(op, body) {
  if (config.mock && op === 'call') {
    const fn = field(config.mock, `${body.tool}.${body.microtool}`) ?? config.mock[body.tool]?.[body.microtool];
    if (typeof fn !== 'function') throw new TraderaError(`no mock for ${body.tool}/${body.microtool}`, 'not_found');
    return { result: await fn(body.args || {}) };
  }
  if (config.mock && op !== 'call') {
    if (op === 'context') return { space: 'local', user: { id: 'local', handle: 'you' }, preview: { title: document.title } };
    if (op === 'tools') return { tools: Object.keys(config.mock).map((name) => ({ name, id: name, microtools: Object.keys(config.mock[name]).map((n) => ({ name: n })) })) };
  }
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), config.timeout);
  let res;
  try {
    res = await fetch(apiBase() + op, {
      method: body === undefined ? 'GET' : 'POST',
      headers: body === undefined ? { Accept: 'application/json' } : { 'Content-Type': 'application/json', Accept: 'application/json' },
      body: body === undefined ? undefined : JSON.stringify(body),
      credentials: 'include',
      signal: ctrl.signal,
    });
  } catch (e) {
    throw new TraderaError(e.name === 'AbortError' ? 'The request timed out' : 'Could not reach Tradera: ' + e.message, 'unavailable');
  } finally { clearTimeout(timer); }
  let data = null;
  const text = await res.text();
  try { data = text ? JSON.parse(text) : null; } catch { /* not JSON */ }
  if (!res.ok) {
    const msg = (data && data.error) || (res.status === 401 ? 'Sign in to Tradera to use this page' : res.status === 404 && !data
      ? 'The Tradera API is reached through the preview gateway: open this page from the desk (or its preview link), or use Tradera.configure({mock}) locally'
      : `Request failed (${res.status})`);
    throw new TraderaError(msg, data && data.code, res.status);
  }
  return data;
}

let contextPromise = null;
/** Who is viewing, in which space and room, through which preview. */
Tradera.context = () => (contextPromise ||= api('context').catch((e) => { contextPromise = null; throw e; }));
/** The space's tools, each with its microtools ({name, description, schema}). */
Tradera.tools = async () => (await api('tools')).tools;
/** One tool's microtools, asked live from its backend. */
Tradera.microtools = async (tool) => (await api('microtools', { tool })).microtools;

/**
 * Calls a microtool of one of the space's tools (by name or id) as the
 * person, and returns its value (an MCP result is unwrapped to its JSON).
 *   const forecast = await Tradera.call('Weather', 'forecast', {city: 'Oslo'});
 */
Tradera.call = async (tool, microtool, args = {}) => {
  if (microtool === undefined && typeof tool === 'string') [tool, microtool] = splitCall(tool);
  const out = await api('call', { tool, microtool, args });
  return microtoolValue(out.result);
};
/** The raw result of a call (MCP content blocks kept). */
Tradera.callRaw = async (tool, microtool, args = {}) => (await api('call', { tool, microtool, args })).result;

/**
 * A tool as an object: Tradera.tool('Weather').forecast({city}) calls its
 * forecast microtool; .call(name, args), .microtools(), .frontend(), .show().
 */
Tradera.tool = (name) => new Proxy({
  name,
  call: (microtool, args) => Tradera.call(name, microtool, args),
  microtools: () => Tradera.microtools(name),
  frontend: (opts) => Tradera.frontend(name, opts),
  show: (opts) => Tradera.show(name, opts),
}, { get: (t, k) => (k in t || typeof k === 'symbol' ? t[k] : (args) => Tradera.call(name, k, args)) });

/** A tool's own frontend: {mode, messages (A2UI, for generative), template, …}. */
Tradera.frontend = (tool, opts = {}) => api('frontend', { tool, ...opts });
/** Runs an action of a tool's generative frontend; returns {data}. */
Tradera.frontendAction = (tool, action, opts = {}) => api('action', { tool, action, ...opts });
/** Opens a tool's frontend (on a result) as a card window on the desk, next to this page. */
Tradera.show = (tool, opts = {}) => api('show', { tool, ...opts });

/** Calls [fn] now and every [ms] (paused while the page is hidden); returns stop(). */
Tradera.poll = (fn, ms = 30000) => {
  let stopped = false, timer = null;
  const tick = async () => {
    if (stopped) return;
    if (!document.hidden) { try { await fn(); } catch (e) { console.error(e); } }
    if (!stopped) timer = setTimeout(tick, ms);
  };
  tick();
  return () => { stopped = true; clearTimeout(timer); };
};

/**
 * Loads a microtool's value into the data model (and refreshes it):
 *   Tradera.load('/forecast', 'Weather', 'forecast', {city: 'Oslo'}, {every: 60})
 */
Tradera.load = async (path, tool, microtool, args = {}, opts = {}) => {
  const run = async () => {
    Tradera.data.set(path + '__loading', true);
    try {
      const v = await Tradera.call(tool, microtool, resolve(args, '', Tradera.data));
      Tradera.data.batch(() => { Tradera.data.set(path, v); Tradera.data.set(path + '__error', null); });
      return v;
    } catch (e) {
      Tradera.data.set(path + '__error', e.message);
      throw e;
    } finally { Tradera.data.set(path + '__loading', false); }
  };
  if (opts.every) return Tradera.poll(run, opts.every * 1000);
  return run();
};

// ---- theme ----------------------------------------------------------------

const SCHEME_ROLES = ['primary', 'onPrimary', 'primaryContainer', 'onPrimaryContainer', 'secondary', 'onSecondary',
  'secondaryContainer', 'onSecondaryContainer', 'tertiary', 'onTertiary', 'tertiaryContainer', 'onTertiaryContainer',
  'error', 'onError', 'errorContainer', 'onErrorContainer', 'surface', 'onSurface', 'onSurfaceVariant',
  'surfaceContainerLowest', 'surfaceContainerLow', 'surfaceContainer', 'surfaceContainerHigh', 'surfaceContainerHighest',
  'outline', 'outlineVariant', 'inverseSurface', 'onInverseSurface', 'inversePrimary', 'background'];

/**
 * Applies the app's theme: {mode: light|dark|system, scheme: {role: #hex},
 * embed: 'desk'}. The app sends it when it shows the page (query on first
 * load, a postMessage after), so the page follows the person's accent and
 * brightness.
 */
function setTheme(theme = {}) {
  const root = document.documentElement;
  if (theme.mode === 'light' || theme.mode === 'dark') root.dataset.theme = theme.mode;
  else if (theme.mode === 'system') delete root.dataset.theme;
  if (theme.embed) root.dataset.embed = theme.embed;
  if (isMap(theme.scheme)) {
    for (const role of SCHEME_ROLES) {
      const v = theme.scheme[role];
      if (typeof v === 'string' && /^#[0-9a-f]{6}$/i.test(v)) root.style.setProperty('--t-' + kebab(role), v);
    }
  }
  try { sessionStorage.setItem('tradera-theme', JSON.stringify({ ...readStoredTheme(), ...theme })); } catch { /* private mode */ }
  document.dispatchEvent(new CustomEvent('t-theme', { detail: theme }));
  for (const e of document.querySelectorAll('t-chart, t-sparkline, t-gauge, t-heatmap, t-treemap, t-graph, t-avatar, t-avatar-group, t-badge, t-tag, t-allocation-bar')) e.update?.();
}
function readStoredTheme() {
  try { return JSON.parse(sessionStorage.getItem('tradera-theme') || '{}') || {}; } catch { return {}; }
}
function b64json(s) {
  try { return JSON.parse(decodeURIComponent(escape(atob(s.replace(/-/g, '+').replace(/_/g, '/'))))); } catch { return null; }
}
Tradera.theme = {
  set: setTheme,
  get mode() { const t = document.documentElement.dataset.theme; return t || (matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light'); },
  toggle() { setTheme({ mode: this.mode === 'dark' ? 'light' : 'dark' }); },
};

function initTheme() {
  const q = new URLSearchParams(location.search);
  const theme = { ...readStoredTheme() };
  if (q.get('tradera_theme')) theme.mode = q.get('tradera_theme');
  if (q.get('tradera_embed')) theme.embed = q.get('tradera_embed');
  if (q.get('tradera_scheme')) theme.scheme = b64json(q.get('tradera_scheme')) || theme.scheme;
  if (Object.keys(theme).length) setTheme(theme);
  window.addEventListener('message', (e) => {
    const m = e.data;
    if (!isMap(m) || m.type !== 'tradera:theme') return;
    // Only the app that frames the page (or the web view host) sends it.
    if (e.source && e.source !== window.parent && e.source !== window) return;
    setTheme(m);
  });
  window.__traderaSetTheme = setTheme; // the native web view host calls it
}
