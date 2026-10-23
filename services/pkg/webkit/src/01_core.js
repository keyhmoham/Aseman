// ---------------------------------------------------------------------------
// Core: values and formats (ui_kit/values.dart), colors (ui_kit/palette.dart),
// icons, DOM helpers, the data model with {"path"} bindings, the AG-UI surface client
// functions and actions, and the base class of every <t-*> element.
// ---------------------------------------------------------------------------

const KIT_VERSION = '1.0.0';
const Aseman = (window.Aseman = window.Aseman || {});
Aseman.version = KIT_VERSION;

// ---- values ---------------------------------------------------------------

function asNum(v) {
  if (typeof v === 'number') return Number.isFinite(v) ? v : null;
  if (typeof v === 'string') {
    const s = v.trim().replace(/,/g, '');
    if (s === '' || !/^[-+]?(\d+\.?\d*|\.\d+)(e[-+]?\d+)?$/i.test(s)) return null;
    return Number(s);
  }
  if (typeof v === 'boolean') return v ? 1 : 0;
  return null;
}
const asDouble = (v, fallback) => { const n = asNum(v); return n == null ? fallback : n; };
const asInt = (v, fallback) => { const n = asNum(v); return n == null ? fallback : Math.round(n); };
function asBool(v, fallback = false) {
  if (typeof v === 'boolean') return v;
  if (typeof v === 'number') return v !== 0;
  if (v === 'true' || v === '') return true;
  if (v === 'false') return false;
  return fallback;
}
function asText(v) {
  if (v == null) return '';
  if (typeof v === 'object') return JSON.stringify(v);
  return String(v);
}
function asList(v) {
  if (Array.isArray(v)) return v;
  if (v && typeof v === 'object') return Object.values(v);
  if (v == null) return [];
  return [v];
}
const isMap = (v) => v != null && typeof v === 'object' && !Array.isArray(v);
const asMap = (v) => (isMap(v) ? v : {});
const asRows = (v) => asList(v).map((x) => (isMap(x) ? x : { value: x, label: asText(x) }));

/** The value at [path] of [row]: a field name, or a dotted path (a.b.0). */
function field(row, path) {
  if (path == null || path === '') return undefined;
  if (isMap(row) && Object.prototype.hasOwnProperty.call(row, path)) return row[path];
  let cur = row;
  for (const part of String(path).split(/[./]/)) {
    if (part === '') continue;
    if (cur == null || typeof cur !== 'object') return undefined;
    cur = cur[Array.isArray(cur) ? Number(part) : part];
  }
  return cur;
}

function autoDecimals(n) {
  if (Number.isInteger(n)) return 0;
  const a = Math.abs(n);
  if (a >= 100) return 1;
  if (a >= 1) return 2;
  if (a === 0) return 0;
  return Math.min(8, Math.floor(-Math.log10(a)) + 3);
}

/** [n] with thousands separators and [decimals] fraction digits. */
function formatNumber(n, decimals = 0) {
  if (!Number.isFinite(n)) return String(n);
  const fixed = Math.abs(n).toFixed(Math.max(0, Math.min(12, decimals)));
  const dot = fixed.indexOf('.');
  const whole = dot < 0 ? fixed : fixed.slice(0, dot);
  const frac = dot < 0 ? '' : fixed.slice(dot);
  let out = '';
  for (let i = 0; i < whole.length; i++) {
    if (i > 0 && (whole.length - i) % 3 === 0) out += ',';
    out += whole[i];
  }
  const negative = n < 0 && /[1-9]/.test(fixed);
  return (negative ? '-' : '') + out + frac;
}

/** 1,284 / 12.9K / 4.2M / 1.1B. */
function formatCompact(n, decimals = 1) {
  const a = Math.abs(n);
  for (const [size, suffix] of [[1e12, 'T'], [1e9, 'B'], [1e6, 'M'], [1e3, 'K']]) {
    if (a >= size) {
      let s = (n / size).toFixed(decimals);
      if (s.includes('.')) s = s.replace(/\.?0+$/, '');
      return s + suffix;
    }
  }
  return formatNumber(n, Number.isInteger(n) ? 0 : 1);
}

function asDate(v) {
  if (v instanceof Date) return v;
  if (typeof v === 'number') return new Date(Math.abs(v) < 1e10 ? v * 1000 : v);
  if (typeof v === 'string' && v.trim()) {
    const n = asNum(v);
    if (n != null && /^\d{9,13}$/.test(v.trim())) return asDate(n);
    const d = new Date(v);
    return isNaN(d) ? null : d;
  }
  return null;
}
const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
function formatDate(d, kind = 'date') {
  const two = (x) => String(x).padStart(2, '0');
  const date = `${MONTHS[d.getMonth()]} ${d.getDate()}, ${d.getFullYear()}`;
  const time = `${two(d.getHours())}:${two(d.getMinutes())}`;
  return kind === 'time' ? time : kind === 'datetime' ? `${date} ${time}` : date;
}

const CURRENCY = { USD: '$', EUR: '€', GBP: '£', JPY: '¥', CNY: '¥', INR: '₹', KRW: '₩', RUB: '₽', TRY: '₺', IRR: '﷼',
  BTC: '₿', ETH: 'Ξ', USDT: '₮', $: '$', '€': '€', '£': '£' };

/**
 * Formats [v] by [format] (kind[:arg[:arg]], a leading + signs positives):
 * number[:decimals], integer, compact[:decimals], percent[:decimals] (a
 * fraction), currency[:CODE[:decimals]], date, time, datetime, text.
 */
function formatValue(v, format) {
  if (v == null) return '';
  let spec = String(format || '').trim();
  if (spec === '' || spec === 'text') {
    if (typeof v === 'number') return formatNumber(v, autoDecimals(v));
    return asText(v);
  }
  let signed = false;
  if (spec.startsWith('+')) { signed = true; spec = spec.slice(1); }
  const parts = spec.split(':');
  const kind = parts[0];
  if (kind === 'date' || kind === 'time' || kind === 'datetime') {
    const d = asDate(v);
    return d ? formatDate(d, kind) : asText(v);
  }
  if (kind === 'relative') { const d = asDate(v); return d ? formatRelative(d) : asText(v); }
  const n = asNum(v);
  if (n == null) return asText(v);
  const sign = (s) => (signed && n > 0 ? '+' + s : s);
  const arg = (i) => (parts.length > i && parts[i] !== '' && !isNaN(parts[i]) ? parseInt(parts[i], 10) : null);
  switch (kind) {
    case 'integer': return sign(formatNumber(n, 0));
    case 'compact': return sign(formatCompact(n, arg(1) ?? 1));
    case 'percent': return sign(formatNumber(n * 100, arg(1) ?? 0) + '%');
    case 'currency': {
      const code = parts.length > 1 && parts[1] ? parts[1] : 'USD';
      const symbol = CURRENCY[code.toUpperCase()] ?? code + ' ';
      const body = formatNumber(Math.abs(n), arg(2) ?? 2);
      return n < 0 ? '-' + symbol + body : sign(symbol + body);
    }
    default: return sign(formatNumber(n, arg(1) ?? autoDecimals(n)));
  }
}

function formatRelative(d) {
  const s = (Date.now() - d.getTime()) / 1000;
  const a = Math.abs(s);
  const f = (n, u) => `${n} ${u}${n === 1 ? '' : 's'}`;
  const t = a < 45 ? 'just now' : a < 3600 ? f(Math.round(a / 60), 'min') : a < 86400 ? f(Math.round(a / 3600), 'hour')
    : a < 86400 * 30 ? f(Math.round(a / 86400), 'day') : null;
  if (t == null) return formatDate(d);
  if (t === 'just now') return t;
  return s >= 0 ? t + ' ago' : 'in ' + t;
}

/** Round axis ticks (1, 2, 2.5, 5 × 10ⁿ), about [count] of them. */
function niceTicks(min, max, count = 5) {
  if (!Number.isFinite(min) || !Number.isFinite(max)) return [0, 1];
  if (min === max) { const pad = min === 0 ? 1 : Math.abs(min) * 0.1; min -= pad; max += pad; }
  const raw = (max - min) / Math.max(1, count - 1);
  const mag = Math.pow(10, Math.floor(Math.log10(raw)));
  const step = [1, 2, 2.5, 5, 10].map((m) => m * mag).find((s) => s >= raw) ?? 10 * mag;
  const start = Math.floor(min / step) * step, end = Math.ceil(max / step) * step;
  const ticks = [];
  for (let v = start; v <= end + step / 2; v += step) ticks.push(Number(v.toPrecision(12)));
  return ticks;
}

// ---- colors ---------------------------------------------------------------

const HUES = ['blue', 'orange', 'aqua', 'yellow', 'magenta', 'green', 'violet', 'red'];
const STATUS = { good: 'good', success: 'good', positive: 'good', up: 'good', warning: 'warning', warn: 'warning',
  serious: 'serious', critical: 'critical', error: 'critical', danger: 'critical', negative: 'critical', down: 'critical',
  info: 'series-1' };
const TOKENS = { surface: 'surface', surfaceVariant: 'surface-container-highest', surfaceHigh: 'surface-container-high',
  surfaceLow: 'surface-container-low', primary: 'primary', accent: 'primary', onPrimary: 'on-primary',
  primaryContainer: 'primary-container', secondary: 'secondary', secondaryContainer: 'secondary-container',
  tertiary: 'tertiary', outline: 'outline-variant', error: 'error', onSurface: 'on-surface',
  onSurfaceVariant: 'on-surface-variant', muted: 'other', gray: 'other', grey: 'other', other: 'other' };
const SEQ_RAMP = ['#cde2fb', '#b7d3f6', '#9ec5f4', '#86b6ef', '#6da7ec', '#5598e7', '#3987e5', '#2a78d6', '#256abf',
  '#1c5cab', '#184f95', '#104281', '#0d366b'];

const series = (i) => (i >= 0 && i < 8 ? `var(--t-series-${i + 1})` : 'var(--t-other)');

/** A color spec as CSS: #hex, a series slot or hue, a status, a scheme token, or any CSS color. */
function color(spec, fallback = null) {
  if (spec == null || spec === '') return fallback;
  if (typeof spec === 'number') return series(spec - 1);
  const s = String(spec).trim();
  if (s.startsWith('#') || s.startsWith('rgb') || s.startsWith('hsl') || s.startsWith('var(') || s.startsWith('color-mix')) return s;
  const slot = /^(series-)?(\d)$/.exec(s);
  if (slot) return series(Number(slot[2]) - 1);
  const hue = HUES.indexOf(s);
  if (hue >= 0) return series(hue);
  if (STATUS[s]) return STATUS[s].startsWith('series') ? `var(--t-${STATUS[s]})` : `var(--t-${STATUS[s]})`;
  if (TOKENS[s]) return `var(--t-${TOKENS[s]})`;
  if (s === 'transparent') return 'transparent';
  if (/^[a-z]+$/i.test(s) && CSS.supports('color', s)) return s;
  return fallback;
}
const statusColor = (name) => color(STATUS[name] ? name : null, 'var(--t-primary)');

const _probe = { el: null };
/** A CSS color (vars included) as [r, g, b, a]. */
function rgba(css) {
  if (!_probe.el) {
    _probe.el = document.createElement('span');
    _probe.el.style.display = 'none';
    (document.body || document.documentElement).appendChild(_probe.el);
  }
  _probe.el.style.color = '';
  _probe.el.style.color = css;
  const m = getComputedStyle(_probe.el).color.match(/[\d.]+/g) || [0, 0, 0];
  return [+m[0], +m[1], +m[2], m[3] == null ? 1 : +m[3]];
}
const hex = ([r, g, b]) => '#' + [r, g, b].map((x) => Math.round(x).toString(16).padStart(2, '0')).join('');
function lerpColor(a, b, t) {
  const x = rgba(a), y = rgba(b);
  return hex([0, 1, 2].map((i) => x[i] + (y[i] - x[i]) * t));
}
function luminance(css) {
  const c = rgba(css).slice(0, 3).map((v) => { v /= 255; return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4); });
  return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2];
}
/** Ink that reads on [fill]: white or near-black. */
const onFill = (fill) => (luminance(fill) > 0.45 ? '#0b0b0b' : '#ffffff');
const isDark = () => luminance(getComputedStyle(document.documentElement).getPropertyValue('--t-surface').trim() || '#fff') < 0.2;
function sampleRamp(ramp, t) {
  const x = Math.max(0, Math.min(1, t)) * (ramp.length - 1);
  const i = Math.max(0, Math.min(ramp.length - 2, Math.floor(x)));
  return lerpColor(ramp[i], ramp[i + 1], x - i);
}
/** Magnitude 0..1 on the blue ramp (recedes near zero). */
const sequential = (t) => sampleRamp(isDark() ? [...SEQ_RAMP].reverse() : SEQ_RAMP, t);
/** Polarity -1..1: red ← neutral → blue. */
function diverging(t) {
  const c = Math.max(-1, Math.min(1, t));
  return lerpColor('var(--t-neutral)', c >= 0 ? 'var(--t-series-1)' : 'var(--t-critical)', Math.abs(c));
}

// ---- icons ----------------------------------------------------------------

const ICON_EXTRA = { copy: 'content_copy', info_outline: 'info', bookmark_outline: 'bookmark_border', eco: 'spa',
  radio_button_off: 'radio_button_unchecked', keys: 'vpn_key', chevronRight: 'chevron_right', chevronLeft: 'chevron_left',
  expandMore: 'expand_more', expandLess: 'expand_less', candlestick: 'candlestick_chart', bitcoin: 'currency_bitcoin',
  robot: 'smart_toy', agent: 'smart_toy', sparkles: 'auto_awesome', magic: 'auto_awesome', apps: 'apps', x: 'close',
  plus: 'add', minus: 'remove', trash: 'delete', pencil: 'edit', gear: 'settings', cog: 'settings', bell: 'notifications',
  calendar: 'calendar_today', heart: 'favorite', eye: 'visibility', eyeOff: 'visibility_off', external: 'open_in_new',
  arrowUp: 'arrow_upward', arrowDown: 'arrow_downward', arrowLeft: 'arrow_back', arrowRight: 'arrow_forward',
  caretUp: 'arrow_drop_up', caretDown: 'arrow_drop_down', moon: 'dark_mode', light: 'light_mode', dark: 'dark_mode' };
const snake = (n) => n.replace(/([a-z0-9])([A-Z])/g, '$1_$2').toLowerCase();
/** The material icon a name names (Surface Spec camelCase, Elpian snake_case, kit names), or null. */
function iconName(name) {
  if (!name || typeof name !== 'string') return null;
  const tries = [name, ICON_EXTRA[name], ICON_ALIASES[name], name.toLowerCase(), snake(name), ICON_ALIASES[snake(name)],
    ICON_EXTRA[snake(name)], snake(name).replace(/_(rounded|outlined|outline|sharp)$/, '')];
  for (const t of tries) {
    if (!t) continue;
    if (ICONS[t]) return t;
    if (ICON_ALIASES[t] && ICONS[ICON_ALIASES[t]]) return ICON_ALIASES[t];
  }
  return null;
}
const hasIcon = (name) => iconName(name) != null;
/** An icon element (a star when the name is unknown, like Elpian). */
function icon(name, size) {
  const span = document.createElement('span');
  span.className = 't-icon';
  span.setAttribute('aria-hidden', 'true');
  if (size) span.style.setProperty('--t-icon', typeof size === 'number' ? size + 'px' : size);
  const n = iconName(name) || (name && String(name).startsWith('M') ? null : 'star');
  const d = n ? ICONS[n] : String(name);
  span.innerHTML = `<svg viewBox="0 0 24 24" focusable="false"><path d="${d}"/></svg>`;
  return span;
}

// ---- DOM ------------------------------------------------------------------

/** h('div', {class, style, on: {click}, ...attrs}, ...children) */
function h(tag, attrs, ...kids) {
  const el = typeof tag === 'string' ? document.createElement(tag) : tag;
  if (attrs) {
    for (const [k, v] of Object.entries(attrs)) {
      if (v == null || v === false) continue;
      if (k === 'class' || k === 'className') el.className = v;
      else if (k === 'style' && typeof v === 'object') applyStyle(el, v);
      else if (k === 'on') for (const [ev, fn] of Object.entries(v)) el.addEventListener(ev, fn);
      else if (k === 'dataset') Object.assign(el.dataset, v);
      else if (k === 'html') el.innerHTML = v;
      else if (k === 'text') el.textContent = v;
      else if (k in el && typeof v !== 'string' && k !== 'list') el[k] = v;
      else el.setAttribute(k, v === true ? '' : v);
    }
  }
  append(el, kids);
  return el;
}
function append(el, kids) {
  for (const k of kids.flat(Infinity)) {
    if (k == null || k === false) continue;
    el.appendChild(k instanceof Node ? k : document.createTextNode(String(k)));
  }
  return el;
}
const kebab = (s) => s.replace(/([a-z0-9])([A-Z])/g, '$1-$2').toLowerCase();
const camel = (s) => s.replace(/-([a-z0-9])/g, (_, c) => c.toUpperCase());

// CSS from Elpian-style maps: camelCase keys, numbers are px (except unitless props).
const UNITLESS = new Set(['opacity', 'zIndex', 'flex', 'flexGrow', 'flexShrink', 'fontWeight', 'lineHeight', 'order', 'zoom',
  'gridRow', 'gridColumn', 'aspectRatio', 'scale']);
const STYLE_ALIAS = { color: 'color', backgroundColor: 'background-color', background: 'background', borderColor: 'border-color' };
function cssValue(key, v) {
  if (typeof v === 'number') return UNITLESS.has(key) ? String(v) : v + 'px';
  if (Array.isArray(v)) {
    if (/margin|padding/i.test(key)) return v.map((x) => (typeof x === 'number' ? x + 'px' : x)).join(' ');
    if (/gradient/i.test(key)) return `linear-gradient(135deg, ${v.map((c) => color(c, c)).join(', ')})`;
    return v.join(' ');
  }
  if (typeof v === 'string' && /color|background|fill|stroke/i.test(key) && !/url\(|gradient/.test(v)) return color(v, v);
  if (isMap(v) && /margin|padding|inset/i.test(key)) {
    const p = (x) => (x == null ? '0' : typeof x === 'number' ? x + 'px' : x);
    if ('all' in v) return p(v.all);
    return [p(v.top ?? v.vertical), p(v.right ?? v.horizontal), p(v.bottom ?? v.vertical), p(v.left ?? v.horizontal)].join(' ');
  }
  return v;
}
/** Applies an Elpian/CSS style map to an element. */
function applyStyle(el, style) {
  if (!style) return el;
  if (typeof style === 'string') { el.style.cssText += ';' + style; return el; }
  for (const [k, raw] of Object.entries(style)) {
    if (raw == null) continue;
    switch (k) {
      case 'gradient': case 'gradientColors':
        el.style.backgroundImage = `linear-gradient(135deg, ${asList(raw).map((c) => color(c, c)).join(', ')})`; continue;
      case 'elevation': el.style.boxShadow = `var(--t-shadow-${Math.max(1, Math.min(4, Math.round(asDouble(raw, 1) / 2) || 1))})`; continue;
      case 'transitionDuration': case 'animationDuration': el.style.setProperty('--t-duration', typeof raw === 'number' ? raw + 'ms' : raw); continue;
      case 'transitionCurve': case 'curve': el.style.setProperty('--t-curve', CURVES[raw] || raw); continue;
      case 'scaleBegin': case 'animationFrom': el.style.setProperty('--t-from', raw); continue;
      case 'scaleEnd': case 'animationTo': el.style.setProperty('--t-to', raw); continue;
      case 'rotate': el.style.rotate = typeof raw === 'number' ? raw + 'deg' : raw; continue;
      case 'visible': if (raw === false) el.style.display = 'none'; continue;
      case 'alignment': setAlignment(el, raw); continue;
    }
    const name = STYLE_ALIAS[k] || (k.startsWith('--') ? k : kebab(k));
    const v = cssValue(k, raw);
    if (name.startsWith('--')) el.style.setProperty(name, v); else el.style.setProperty(name, String(v));
  }
  return el;
}
const CURVES = { linear: 'linear', ease: 'ease', easeIn: 'ease-in', easeOut: 'ease-out', easeInOut: 'ease-in-out',
  fastOutSlowIn: 'cubic-bezier(.4,0,.2,1)', easeOutBack: 'var(--t-ease-back)', bounceOut: 'cubic-bezier(.34,1.56,.64,1)',
  elasticOut: 'cubic-bezier(.68,-.55,.27,1.55)', decelerate: 'cubic-bezier(0,0,.2,1)', emphasized: 'var(--t-ease)' };
/** Flutter-style alignment (topLeft, center, bottomRight…) on a flex box. */
function setAlignment(el, a) {
  const m = { topLeft: ['flex-start', 'flex-start'], topCenter: ['flex-start', 'center'], topRight: ['flex-start', 'flex-end'],
    centerLeft: ['center', 'flex-start'], center: ['center', 'center'], centerRight: ['center', 'flex-end'],
    bottomLeft: ['flex-end', 'flex-start'], bottomCenter: ['flex-end', 'center'], bottomRight: ['flex-end', 'flex-end'],
    topStart: ['flex-start', 'flex-start'], topEnd: ['flex-start', 'flex-end'], bottomStart: ['flex-end', 'flex-start'], bottomEnd: ['flex-end', 'flex-end'] };
  const v = m[a] || m[camel(String(a).replace(/_/g, '-'))];
  if (!v) return;
  el.style.display = el.style.display || 'flex';
  el.style.flexDirection = 'column';
  el.style.justifyContent = v[0];
  el.style.alignItems = v[1];
}
const JUSTIFY = { start: 'flex-start', center: 'center', end: 'flex-end', spaceBetween: 'space-between',
  spaceAround: 'space-around', spaceEvenly: 'space-evenly', stretch: 'stretch' };
const ALIGN = { start: 'flex-start', center: 'center', end: 'flex-end', stretch: 'stretch', baseline: 'baseline' };

// ---- data model and bindings --------------------------------------------

/**
 * A JSON data model with paths ("/a/b/0"), as AG-UI surfaces have: elements
 * bind props to it with {"path": "/x"} (or bind-<prop>="/x") and re-render
 * when what they read changes; inputs write to it.
 */
class Store {
  constructor(data = {}) { this.data = data; this.subs = new Set(); }
  static parts(path) {
    if (path == null) return [];
    return String(path).split('/').filter((p) => p !== '' && p !== '.').map((p) => p.replace(/~1/g, '/').replace(/~0/g, '~'));
  }
  get(path) {
    // Recorded first: a binding to data that is not there yet must update when it comes.
    if (Tracker.active) Tracker.active.add(normPath(path));
    let cur = this.data;
    for (const p of Store.parts(path)) {
      if (cur == null || typeof cur !== 'object') return undefined;
      cur = cur[Array.isArray(cur) ? Number(p) : p];
    }
    return cur;
  }
  set(path, value) {
    const parts = Store.parts(path);
    if (!parts.length) { this.data = value; this.notify('/'); return; }
    let cur = this.data;
    for (let i = 0; i < parts.length - 1; i++) {
      const p = parts[i];
      const key = Array.isArray(cur) ? Number(p) : p;
      if (cur[key] == null || typeof cur[key] !== 'object') cur[key] = /^\d+$/.test(parts[i + 1]) ? [] : {};
      cur = cur[key];
    }
    const last = parts[parts.length - 1];
    cur[Array.isArray(cur) ? Number(last) : last] = value;
    this.notify(normPath(path));
  }
  /** Merges [value] into the object at [path]. */
  merge(path, value) { this.set(path, { ...asMap(this.get(path)), ...asMap(value) }); }
  remove(path) {
    const parts = Store.parts(path);
    const parent = this.get('/' + parts.slice(0, -1).join('/'));
    if (Array.isArray(parent)) parent.splice(Number(parts[parts.length - 1]), 1);
    else if (isMap(parent)) delete parent[parts[parts.length - 1]];
    this.notify(normPath(path));
  }
  subscribe(fn) { this.subs.add(fn); return () => this.subs.delete(fn); }
  notify(path) {
    if (this._batch) { this._batch.add(path); return; }
    for (const fn of [...this.subs]) { try { fn(path); } catch (e) { console.error(e); } }
  }
  /** Runs [fn] and notifies once for everything it changed. */
  batch(fn) {
    if (this._batch) return fn();
    this._batch = new Set();
    try { return fn(); } finally {
      const paths = this._batch; this._batch = null;
      for (const p of paths) this.notify(p);
    }
  }
}
const normPath = (p) => '/' + Store.parts(p).join('/');
/** Whether a change at [changed] touches what was read at [read]. */
const touches = (read, changed) => read === changed || changed === '/' || read.startsWith(changed + '/') || changed.startsWith(read + '/');
const Tracker = { active: null };

/** Paths relative to a scope ("name", "./name", ".") resolve under it. */
function joinPath(scope, path) {
  if (path == null) return scope || '/';
  path = String(path);
  if (path.startsWith('/')) return path;
  if (path === '.' || path === '') return scope || '/';
  return normPath((scope || '') + '/' + path.replace(/^\.\//, ''));
}

/**
 * Resolves a prop value against the store: {"path"} bindings, {"call", args}
 * functions, Surface Spec literal wrappers, and nested maps and lists.
 */
function resolve(v, scope, store = Aseman.data) {
  if (v == null || typeof v !== 'object') return v;
  if (Array.isArray(v)) return v.map((x) => resolve(x, scope, store));
  const keys = Object.keys(v);
  if ('path' in v && keys.length <= 2 && (keys.length === 1 || 'default' in v || 'literal' in v)) {
    const got = store.get(joinPath(scope, v.path));
    return got === undefined ? (v.default ?? v.literal) : got;
  }
  if (keys.length === 1) {
    if ('literalString' in v) return v.literalString;
    if ('literalNumber' in v) return v.literalNumber;
    if ('literalBoolean' in v) return v.literalBoolean;
    if ('literalArray' in v) return v.literalArray;
  }
  if (typeof v.call === 'string' && FUNCTIONS[v.call] && (keys.length <= 3) && keys.every((k) => ['call', 'args', 'returnType'].includes(k))) {
    return callFunction(v.call, asMap(v.args), scope, store);
  }
  if (v.functionCall || v.event || v.tool) return v; // actions resolve when they run
  const out = {};
  for (const k of keys) out[k] = resolve(v[k], scope, store);
  return out;
}

// ---- functions (Surface Spec client functions) -------------------------

function interpolate(text, scope, store) {
  return String(text ?? '').replace(/\$\{([^}]+)\}/g, (_, p) => {
    p = p.trim();
    const [path, fmt] = p.split('|').map((s) => s.trim());
    const v = store.get(joinPath(scope, path));
    return fmt ? formatValue(v, fmt) : typeof v === 'number' ? formatValue(v) : asText(v);
  });
}
const nums = (vals, fieldName) => asList(vals).map((x) => asNum(fieldName ? field(x, fieldName) : x)).filter((x) => x != null);
const FUNCTIONS = {
  formatString: (a, s, st) => interpolate(a.value ?? a.text ?? a.template, s, st),
  formatNumber: (a) => formatValue(a.value, a.decimals != null ? `number:${a.decimals}` : 'number'),
  formatCurrency: (a) => formatValue(a.value, `currency:${a.currency || 'USD'}${a.decimals != null ? ':' + a.decimals : ''}`),
  formatDate: (a) => {
    const d = asDate(a.value); if (!d) return asText(a.value);
    const f = a.format || 'date';
    if (['date', 'time', 'datetime', 'relative'].includes(f)) return formatValue(d, f);
    const two = (x) => String(x).padStart(2, '0');
    return f.replace(/yyyy/g, d.getFullYear()).replace(/MMM/g, MONTHS[d.getMonth()]).replace(/MM/g, two(d.getMonth() + 1))
      .replace(/dd/g, two(d.getDate())).replace(/HH/g, two(d.getHours())).replace(/mm/g, two(d.getMinutes())).replace(/ss/g, two(d.getSeconds()));
  },
  format: (a) => formatValue(a.value, a.format),
  formatPercent: (a) => formatValue(a.value, `${a.signed ? '+' : ''}percent:${a.decimals ?? 0}`),
  formatCompact: (a) => formatValue(a.value, 'compact'),
  formatRelative: (a) => { const d = asDate(a.value); return d ? formatRelative(d) : asText(a.value); },
  now: (a) => { Tracker.active && Tracker.active.add('/__clock'); return a.format ? FUNCTIONS.formatDate({ value: new Date(), format: a.format }) : new Date().toISOString(); },
  pluralize: (a) => { const n = asNum(a.count ?? a.value) ?? 0; return `${a.includeCount === false ? '' : formatValue(n) + ' '}${n === 1 ? a.singular || a.one : a.plural || a.other || (a.singular || '') + 's'}`.trim(); },
  add: (a) => nums(a.values).reduce((x, y) => x + y, 0),
  multiply: (a) => nums(a.values).reduce((x, y) => x * y, 1),
  subtract: (a) => (asNum(a.a) ?? 0) - (asNum(a.b) ?? 0),
  divide: (a) => { const b = asNum(a.b); return b ? (asNum(a.a) ?? 0) / b : null; },
  round: (a) => { const p = Math.pow(10, asInt(a.decimals, 0)); return Math.round((asNum(a.value) ?? 0) * p) / p; },
  abs: (a) => Math.abs(asNum(a.value) ?? 0),
  clamp: (a) => Math.max(asNum(a.min) ?? -Infinity, Math.min(asNum(a.max) ?? Infinity, asNum(a.value) ?? 0)),
  percentChange: (a) => { const f = asNum(a.from), t = asNum(a.to); return f ? (t - f) / Math.abs(f) : null; },
  sum: (a) => nums(a.values, a.field).reduce((x, y) => x + y, 0),
  average: (a) => { const n = nums(a.values, a.field); return n.length ? n.reduce((x, y) => x + y, 0) / n.length : null; },
  min: (a) => { const n = nums(a.values, a.field); return n.length ? Math.min(...n) : null; },
  max: (a) => { const n = nums(a.values, a.field); return n.length ? Math.max(...n) : null; },
  count: (a) => asList(a.values ?? a.value).length,
  equals: (a) => JSON.stringify(a.a) === JSON.stringify(a.b) || (a.a != null && a.b != null && String(a.a) === String(a.b)),
  notEquals: (a) => !FUNCTIONS.equals(a),
  greaterThan: (a) => (asNum(a.a) ?? 0) > (asNum(a.b) ?? 0),
  lessThan: (a) => (asNum(a.a) ?? 0) < (asNum(a.b) ?? 0),
  isEmpty: (a) => a.value == null || a.value === '' || (Array.isArray(a.value) && !a.value.length) || (isMap(a.value) && !Object.keys(a.value).length),
  contains: (a) => (Array.isArray(a.value) ? a.value.some((x) => JSON.stringify(x) === JSON.stringify(a.item)) : asText(a.value).toLowerCase().includes(asText(a.item).toLowerCase())),
  if: (a) => (asBool(a.condition) ? a.then : a.else),
  coalesce: (a) => asList(a.values).find((x) => x != null && x !== ''),
  concat: (a) => asList(a.values).map(asText).join(a.separator ?? ''),
  join: (a) => asList(a.values).map((x) => asText(a.field ? field(x, a.field) : x)).join(a.separator ?? ', '),
  upper: (a) => asText(a.value).toUpperCase(),
  lower: (a) => asText(a.value).toLowerCase(),
  truncate: (a) => { const s = asText(a.value), m = asInt(a.max, 40); return s.length > m ? s.slice(0, m - 1) + '…' : s; },
  get: (a) => field(a.value, a.path),
  required: (a) => !FUNCTIONS.isEmpty(a),
  regex: (a) => { try { return new RegExp(a.pattern).test(asText(a.value)); } catch { return false; } },
  length: (a) => { const n = (a.value ?? '').length ?? 0; return (a.min == null || n >= a.min) && (a.max == null || n <= a.max); },
  numeric: (a) => asNum(a.value) != null && (a.min == null || asNum(a.value) >= a.min) && (a.max == null || asNum(a.value) <= a.max),
  email: (a) => /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(asText(a.value)),
  and: (a) => asList(a.values).every((x) => asBool(x)),
  or: (a) => asList(a.values).some((x) => asBool(x)),
  not: (a) => !asBool(a.value),
};
function callFunction(name, args, scope, store = Aseman.data) {
  const fn = FUNCTIONS[name];
  if (!fn) throw new Error('unknown function ' + name);
  const resolved = name === 'formatString' ? { ...args, value: args.value ?? args.text } : resolve(args, scope, store);
  return fn(resolved, scope, store);
}
// A ticking clock for now/formatRelative bindings.
setInterval(() => { if (Aseman.data) Aseman.data.notify('/__clock'); }, 30000);

// ---- actions -------------------------------------------------------------

/** Client-side actions ({"functionCall": {"call", "args"}}), no round trip. */
const CLIENT_ACTIONS = {
  setValue: (a, s, st) => st.set(joinPath(s, a.path), resolve(a.value, s, st)),
  toggle: (a, s, st) => { const p = joinPath(s, a.path); st.set(p, !asBool(st.get(p))); },
  increment: (a, s, st) => {
    const p = joinPath(s, a.path);
    let v = (asNum(st.get(p)) ?? 0) + (asNum(resolve(a.by, s, st)) ?? 1);
    if (a.min != null) v = Math.max(asNum(resolve(a.min, s, st)), v);
    if (a.max != null) v = Math.min(asNum(resolve(a.max, s, st)), v);
    st.set(p, v);
  },
  append: (a, s, st) => { const p = joinPath(s, a.path); st.set(p, [...asList(st.get(p)), resolve(a.value, s, st)]); },
  removeAt: (a, s, st) => { const p = joinPath(s, a.path); const l = [...asList(st.get(p))]; l.splice(asInt(resolve(a.index, s, st), 0), 1); st.set(p, l); },
  copyToClipboard: async (a, s, st) => { await navigator.clipboard.writeText(asText(resolve(a.text ?? a.value, s, st))); toast('Copied'); },
  showToast: (a, s, st) => toast(asText(resolve(a.message ?? a.text, s, st)), { status: a.status }),
  openUrl: (a, s, st) => { const u = asText(resolve(a.url, s, st)); if (/^(https?:|mailto:|\/|\.)/.test(u)) window.open(u, '_blank', 'noopener'); },
  closeModal: () => { const o = [...document.querySelectorAll('.t-overlay')].pop(); if (o && o._close) o._close(); },
};
Aseman.actions = CLIENT_ACTIONS;
const eventHandlers = {};
/** Aseman.on('submit_order', (context, element) => …): handles Surface Spec event actions on the page. */
Aseman.on = (name, fn) => { (eventHandlers[name] ||= []).push(fn); return () => { eventHandlers[name] = eventHandlers[name].filter((f) => f !== fn); }; };

/** "weather/forecast", "weather.forecast" or "weather:forecast" → [tool, microtool]. */
function splitCall(spec) {
  const s = String(spec).trim();
  const m = /^(.+?)[/:](.+)$/.exec(s) || /^([^.]+)\.(.+)$/.exec(s);
  return m ? [m[1], m[2]] : [s, ''];
}

/**
 * Runs an action from an element: a client functionCall, a Surface Spec event
 * (dispatched as a t-action DOM event and to Aseman.on handlers), a
 * Aseman API call {tool, microtool, args, into}, or a list of them in order.
 * [extra] (a tapped row, an input's value) joins the event's context.
 */
async function runAction(action, el, extra = {}, scope = el ? scopeOf(el) : '') {
  if (action == null) return;
  const store = Aseman.data;
  if (Array.isArray(action)) { let last; for (const a of action) last = await runAction(a, el, extra, scope); return last; }
  if (typeof action === 'string') action = { call: action };
  if (action.functionCall) {
    const { call, args } = action.functionCall;
    const fn = CLIENT_ACTIONS[call];
    if (fn) return fn(asMap(args), scope, store);
    if (FUNCTIONS[call]) return callFunction(call, asMap(args), scope, store);
    throw new Error('unknown client action ' + call);
  }
  if (action.event) {
    const name = action.event.name;
    const context = { ...resolve(asMap(action.event.context), scope, store), ...extra };
    el && el.dispatchEvent(new CustomEvent('t-action', { bubbles: true, composed: true, detail: { name, context } }));
    let out;
    for (const fn of eventHandlers[name] || []) out = await fn(context, el);
    if (!eventHandlers[name] && !(el && el.closest('[data-t-handles]'))) console.warn(`[aseman-ui] no handler for event "${name}": add Aseman.on("${name}", fn)`);
    return out;
  }
  if (action.call || action.tool) {
    let [tool, microtool] = action.tool ? [action.tool, action.microtool] : splitCall(action.call);
    if (!microtool && action.microtool) microtool = action.microtool;
    const args = { ...resolve(asMap(action.args), scope, store), ...(action.passValue && extra.value !== undefined ? { value: extra.value } : {}) };
    const result = await Aseman.call(tool, microtool, args);
    store.batch(() => {
      if (action.into) store.set(joinPath(scope, action.into), result);
      if (action.then) runAction(action.then, el, { ...extra, result }, scope);
    });
    el && el.dispatchEvent(new CustomEvent('t-result', { bubbles: true, detail: { tool, microtool, args, result } }));
    if (action.toast) toast(asText(resolve(action.toast, scope, store)), { status: 'good' });
    return result;
  }
  if (action.set) { for (const [p, v] of Object.entries(action.set)) store.set(joinPath(scope, p), resolve(v, scope, store)); return; }
  console.warn('[aseman-ui] unknown action', action);
}
Aseman.run = runAction;

/** The action an element declares: its action prop, or call/args/into/then attributes. */
function actionOf(el, prop = 'action') {
  const a = el._raw ? el._raw[prop] : undefined;
  if (a != null && a !== '') return a;
  const call = el.getAttribute('call');
  if (!call) return null;
  return { call, args: parseAttr(el.getAttribute('args') || '{}'), into: el.getAttribute('into') || undefined,
    then: el.hasAttribute('then') ? parseAttr(el.getAttribute('then')) : undefined, toast: el.getAttribute('toast') || undefined };
}

/** Runs [fn] (async) with the element marked busy; errors become a toast. */
async function busy(el, fn) {
  if (el.dataset.busy != null) return;
  el.dataset.busy = '';
  try { return await fn(); } catch (e) {
    console.error(e);
    toast(e && e.message ? e.message : String(e), { status: 'critical' });
    el.dispatchEvent(new CustomEvent('t-error', { bubbles: true, detail: { error: e } }));
  } finally { delete el.dataset.busy; }
}

// ---- toasts ---------------------------------------------------------------

function toast(message, opts = {}) {
  let host = document.querySelector('.t-toasts');
  if (!host) { host = h('div', { class: 't-toasts', role: 'status', 'aria-live': 'polite' }); document.body.appendChild(host); }
  const status = opts.status && STATUS[opts.status] ? opts.status : null;
  const t = h('div', { class: 't-toast' },
    status ? icon(status === 'good' || status === 'success' ? 'check_circle' : status === 'warning' ? 'warning_amber' : 'error_outline') : null,
    h('span', null, message),
    opts.action ? h('button', { on: { click: () => { opts.action.onPressed?.(); t.remove(); } } }, opts.action.label) : null);
  if (status) t.style.setProperty('--t-c', statusColor(status));
  host.appendChild(t);
  setTimeout(() => { t.style.transition = 'opacity .2s'; t.style.opacity = '0'; setTimeout(() => t.remove(), 220); }, opts.duration ?? 3500);
  return t;
}
Aseman.toast = toast;

// ---- elements ------------------------------------------------------------

/** "[1,2]" → [1,2], "true" → true, "12" → 12, else the string. */
function parseAttr(v) {
  if (v == null) return v;
  const s = v.trim();
  if (s === '') return '';
  if (s === 'true') return true;
  if (s === 'false') return false;
  if (s === 'null') return null;
  if (/^-?(\d+\.?\d*|\.\d+)(e[-+]?\d+)?$/i.test(s) && !/^0\d/.test(s)) return Number(s);
  if ((s[0] === '{' && s.endsWith('}')) || (s[0] === '[' && s.endsWith(']'))) {
    try { return JSON.parse(s); } catch { /* text */ }
  }
  return v;
}

/** The data-model path an element's relative bindings resolve under. */
function scopeOf(el) {
  for (let n = el; n; n = n.parentNode || n.host) {
    if (n._scope != null) return n._scope;
    if (n.nodeType === 1 && n.hasAttribute && n.hasAttribute('scope')) return n.getAttribute('scope');
  }
  return '';
}

const TEXT_PROPS = new Set(['text', 'label', 'value', 'placeholder', 'hint', 'helper', 'caption', 'title', 'subtitle', 'message', 'description', 'name', 'data', 'code', 'markdown', 'alt']);
const PROPS_ATTRS = new Set(['class', 'style', 'id', 'slot', 'hidden', 'role', 'tabindex', 'scope', 'then', 'toast', 'part', 'lang', 'dir']);

/**
 * The base of every <t-*> element. Props come from attributes (JSON where it
 * parses: data='[…]'), from properties (el.data = rows, el.props = {…}) and
 * from bindings ({"path": "/x"} or bind-x="/x") to Aseman.data, which
 * re-render the element when they change. Subclasses implement render().
 */
class TElement extends HTMLElement {
  constructor() {
    super();
    this._raw = {};
    this._deps = null;
    this._queued = false;
    this._rendered = false;
  }
  static get observedAttributes() { return []; }
  /** Reads its attributes now (a parent may ask before this element connected). */
  _ensureProps() {
    if (!this._attrsRead && this.attributes) { this._attrsRead = true; this._readAttrs(); }
  }
  /** Every prop, resolved against the data model. */
  get props() {
    this._ensureProps();
    const out = {};
    for (const k of Object.keys(this._raw)) out[k] = this.p(k);
    return out;
  }
  set props(v) { Object.assign(this._raw, asMap(v)); this.update(); }
  /** One prop, resolved (bindings evaluated in this element's scope). */
  p(name, fallback) {
    this._ensureProps();
    const raw = this._raw[name];
    if (raw === undefined) return fallback;
    const v = resolve(raw, scopeOf(this));
    return v === undefined ? fallback : v;
  }
  /** Sets a prop (re-renders). */
  set(name, value) { this._raw[name] = value; this.update(); return this; }
  /** Writes [value] where the prop is bound (two-way inputs), or keeps it locally. */
  write(name, value) {
    const raw = this._raw[name];
    if (isMap(raw) && typeof raw.path === 'string') Aseman.data.set(joinPath(scopeOf(this), raw.path), value);
    else { this._raw[name] = value; this.update(); }
    this.dispatchEvent(new CustomEvent('t-change', { bubbles: true, detail: { prop: name, value } }));
  }
  _readAttrs() {
    for (const a of [...this.attributes]) this._attr(a.name, a.value);
  }
  _attr(name, value) {
    if (PROPS_ATTRS.has(name) || name.startsWith('aria-') || name.startsWith('data-') || name.startsWith('on')) return;
    if (name.startsWith('bind-')) { this._raw[camel(name.slice(5))] = { path: value }; return; }
    if (name === 'title') {
      // A prop (a section's or chart's title), not the browser's tooltip.
      this._raw.title = parseAttr(value);
      this._droppingTitle = true;
      this.removeAttribute('title');
      this.dataset.title = value;
      return;
    }
    // A bare attribute (stacked, search, editable) is a flag; text props keep "".
    const key = camel(name);
    this._raw[key] = value === '' && !TEXT_PROPS.has(key) ? true : parseAttr(value);
  }
  connectedCallback() {
    // While the page is still parsing, an element connects before its
    // children exist: it renders once the document is parsed.
    if (document.readyState === 'loading') {
      if (!this._waiting) {
        this._waiting = true;
        document.addEventListener('DOMContentLoaded', () => { this._waiting = false; if (this.isConnected) this.connectedCallback(); }, { once: true });
      }
      return;
    }
    if (!this._inited) {
      this._inited = true;
      // Elements built from JSON (surfaces, Elpian nodes, el()) come with their props.
      if (!this._attrsRead) { this._attrsRead = true; this._readAttrs(); }
      this._observer = new MutationObserver((ms) => {
        let changed = false;
        for (const m of ms) {
          const name = m.attributeName;
          const v = this.getAttribute(name);
          // Elements set their own role, tabindex, aria-* and data-* while
          // rendering: those are not props, and an unchanged value is no change.
          if (v === m.oldValue || PROPS_ATTRS.has(name) || name.startsWith('aria-') || name.startsWith('data-') || name.startsWith('on')) continue;
          if (name === 'title' && v == null && this._droppingTitle) { this._droppingTitle = false; continue; }
          if (v == null) delete this._raw[camel(name.replace(/^bind-/, ''))];
          else this._attr(name, v);
          changed = true;
        }
        if (changed) this.update();
      });
      this._observer.observe(this, { attributes: true, attributeOldValue: true });
      this.init?.();
    }
    this._unsub = Aseman.data.subscribe((path) => {
      if (this._deps && [...this._deps].some((d) => touches(d, path))) this.update();
    });
    this.update(true);
  }
  disconnectedCallback() {
    this._unsub?.();
    this.cleanup?.();
  }
  /** Re-renders on the next microtask (several changes, one render). */
  update(now) {
    if (now === true) { this._render(); return; }
    if (this._queued) return;
    this._queued = true;
    queueMicrotask(() => { this._queued = false; if (this.isConnected) this._render(); });
  }
  _render() {
    const prev = Tracker.active;
    const deps = new Set();
    Tracker.active = deps;
    try { this.render(); } catch (e) {
      console.error(`[aseman-ui] <${this.localName}>`, e);
      this.replaceChildren(problem(e.message || String(e)));
    } finally { Tracker.active = prev; }
    this._deps = deps;
    this._rendered = true;
  }
  render() {}
  /** The element's own children, kept aside the first time (for wrappers that lay them out). */
  kids() {
    if (!this._kids) this._kids = [...this.childNodes].filter((n) => !(n.nodeType === 3 && !n.textContent.trim()) && n.localName !== 'template');
    return this._kids;
  }
  emit(name, detail) { this.dispatchEvent(new CustomEvent(name, { bubbles: true, composed: true, detail })); }
}

function problem(message) {
  return h('div', { class: 't-callout', style: { '--t-c': 'var(--t-error)' } }, icon('error_outline'), h('div', { class: 't-callout__body' }, h('div', { class: 't-callout__text' }, message)));
}

const defined = {};
/** Defines <t-name> with [cls] (and returns it). */
function define(name, cls) {
  const tag = 't-' + name;
  if (!customElements.get(tag)) customElements.define(tag, cls);
  defined[tag] = cls;
  return cls;
}
/** Defines a <t-name> that renders with [fn](el, props). */
function component(name, fn, extra = {}) {
  const cls = class extends TElement { render() { fn(this, this.props); } };
  Object.assign(cls.prototype, extra);
  return define(name, cls);
}

/** Makes an element of the kit with props: el('stat', {label, value}). */
function el(name, props = {}, ...kids) {
  const tag = name.includes('-') && name.startsWith('t-') ? name : 't-' + kebab(name);
  const e = document.createElement(tag);
  if (e instanceof TElement) { Object.assign(e._raw, props); e._attrsRead = false; }
  else for (const [k, v] of Object.entries(props)) e.setAttribute(kebab(k), typeof v === 'string' ? v : JSON.stringify(v));
  append(e, kids);
  return e;
}

Object.assign(Aseman, {
  data: new Store({}),
  Store, h, el, icon, hasIcon, color, series, sequential, diverging, onFill, format: formatValue, formatNumber,
  formatCompact, formatDate, asNum, asText, asList, asRows, field, niceTicks, resolve, functions: FUNCTIONS,
  applyStyle, TElement, define, component,
});
