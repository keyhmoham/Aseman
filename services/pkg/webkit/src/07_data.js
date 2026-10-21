// ---------------------------------------------------------------------------
// Data views (ui_kit/data_widgets.dart, data_grid.dart, structured_views.dart):
// Stat, StatCard, Trend, KeyValue, Timeline, TreeView, Progress (Elpian
// Linear/CircularProgressIndicator), Gauge, Sparkline, Rating, DataGrid/Table.
// Tappable views write the tapped row to `selection` and run `action` in the
// row's scope ("symbol" in its context means the row's symbol).
// ---------------------------------------------------------------------------

const SVGNS = 'http://www.w3.org/2000/svg';
function svg(tag, attrs, ...kids) {
  const e = document.createElementNS(SVGNS, tag);
  for (const [k, v] of Object.entries(attrs || {})) if (v != null && v !== false) e.setAttribute(k, v);
  for (const k of kids.flat()) if (k != null) e.appendChild(k instanceof Node ? k : document.createTextNode(String(k)));
  return e;
}

/** The data-model path of row [i] of an element's [prop] (literal data is kept under /__lists). */
function rowPath(el, prop, i) {
  const raw = el._raw[prop];
  if (isMap(raw) && typeof raw.path === 'string') return `${joinPath(scopeOf(el), raw.path)}/${i}`;
  el._rowsPath ||= `/__lists/${++listSeq}`;
  const was = Tracker.active; Tracker.active = null;
  Aseman.data.data.__lists ||= {};
  Aseman.data.data.__lists[el._rowsPath.split('/').pop()] = el.p(prop);
  Tracker.active = was;
  return `${el._rowsPath}/${i}`;
}
/** A tap on item [i] (its row [row]) of a data view: selection, action and a t-select event. */
function select(el, prop, i, row, extra = {}) {
  const detail = { index: i, row, ...extra };
  if (isMap(el._raw.selection) && el._raw.selection.path) Aseman.data.set(joinPath(scopeOf(el), el._raw.selection.path), row);
  el.emit('t-select', detail);
  const a = actionOf(el);
  if (a) busy(el, () => runAction(a, el, { ...detail, ...(isMap(row) ? row : { value: row }) }, i == null ? scopeOf(el) : rowPath(el, prop, i)));
}
const tappable = (el) => !!(el._raw.selection || actionOf(el) || el.hasAttribute('selectable'));

// ---- trend, stat ------------------------------------------------------------------

function trend(value, opts = {}) {
  const v = asNum(value);
  if (v == null) return document.createTextNode('');
  const up = v > 0, down = v < 0;
  const good = opts.goodDown ? down : up;
  let f = opts.format || '+number';
  if (!f.startsWith('+')) f = '+' + f;
  const span = h('span', { class: 't-trend', 'data-dir': up || down ? (good ? 'good' : 'bad') : null },
    opts.arrow !== false && (up || down) ? icon(up ? 'arrow_drop_up' : 'arrow_drop_down') : null,
    formatValue(v, f) + (opts.suffix ? ' ' + opts.suffix : ''));
  if (opts.size) span.style.fontSize = px(opts.size);
  return span;
}
Aseman.trend = trend;
/** Trend {value, format?: "+percent:2", label?, goodDirection?: up|down}: an inline signed change. */
component('trend', (el, p) => el.replaceChildren(trend(p.value, { format: p.format, goodDown: p.goodDirection === 'down', suffix: p.label, size: p.size, arrow: p.arrow })));

/** Stat {label, value, format?, delta?, deltaFormat?, deltaLabel?, goodDirection?, trend?, icon?, status?, size?: compact|default|hero, caption?, color?}. */
function statTile(p) {
  const size = p.size || 'default';
  const raw = p.value;
  const value = p.format == null && typeof raw === 'number' && Math.abs(raw) >= 10000 ? formatCompact(raw) : formatValue(raw, p.format);
  const delta = asNum(p.delta);
  const series_ = asList(p.trend).map((t) => asNum(isMap(t) ? t.value : t));
  const sc = p.status ? statusColor(p.status) : null;
  const tile = h('div', { class: 't-stat', 'data-size': size, style: sc ? { '--t-c': sc } : null },
    h('div', { class: 't-stat__head' }, p.icon ? icon(p.icon) : null, h('span', { class: 't-stat__label' }, asText(p.label))),
    h('div', { class: 't-stat__value', title: value }, value || '—'),
    delta != null || p.caption != null || p.deltaLabel != null
      ? h('div', { class: 't-stat__foot' }, delta != null ? trend(delta, { format: p.deltaFormat || '+number', goodDown: p.goodDirection === 'down' }) : null,
        p.deltaLabel != null || p.caption != null ? h('span', { class: 't-stat__note' }, asText(p.deltaLabel ?? p.caption)) : null)
      : null,
    series_.filter((x) => x != null).length > 1 ? h('div', { class: 't-stat__spark' }, sparkline(series_, { height: size === 'hero' ? 48 : 32, color: p.color, type: 'area' })) : null);
  return tile;
}
Aseman.stat = statTile;
component('stat', (el, p) => el.replaceChildren(statTile(p)));
/** StatCard {label, value, icon?, color?, …}: a Stat in an outlined card (the app's StatCard). */
component('stat-card', (el, p) => el.replaceChildren(h('div', { class: 't-card' }, statTile(p))));

// ---- key value, timeline, tree --------------------------------------------------------

function kvValue(v, format, type) {
  if (type === 'trend') return trend(v, { format });
  if (type === 'badge') return pill({ text: formatValue(v, format), color: color(asText(v).toLowerCase(), 'var(--t-series-1)') });
  if (type === 'link' && v) return h('a', { href: asText(v), target: '_blank', rel: 'noopener' }, asText(v));
  if (type === 'boolean') return icon(asBool(v) ? 'check_circle' : 'cancel', 18);
  if (Array.isArray(v)) return v.map((x) => formatValue(x, format)).join(', ');
  if (isMap(v)) return JSON.stringify(v);
  return formatValue(v, format);
}
/** KeyValue {items: [{label, value, format?, type?: trend|badge|link|boolean}] | data: object (+labels, formats), columns?, layout?: rows|stacked}. */
component('key-value', (el, p) => {
  let items = asList(p.items).map((it) => (isMap(it) ? it : { label: '', value: it }));
  if (!items.length && isMap(p.data)) {
    const labels = asMap(p.labels), formats = asMap(p.formats), types = asMap(p.types);
    items = Object.entries(p.data).filter(([k]) => !asList(p.exclude).includes(k)).map(([k, v]) => ({ label: labels[k] ?? k.replace(/[_-]+/g, ' ').replace(/^\w/, (c) => c.toUpperCase()), value: v, format: formats[k], type: types[k] }));
  }
  el.replaceChildren(h('div', { class: 't-kv', 'data-layout': p.layout || 'rows', style: { '--t-cols': asInt(p.columns, 1) } },
    items.map((it) => h('div', { class: 't-kv__item' }, h('span', { class: 't-kv__label' }, asText(it.label ?? it.key)), h('span', { class: 't-kv__value' }, kvValue(it.value, it.format, it.type))))));
});

/** Timeline {data: rows of {title, description?, time, status?, icon?, color?}, titleField?, descriptionField?, timeField?, timeFormat?}. */
component('timeline', (el, p) => {
  const rows = asRows(p.data ?? p.items);
  const tf = p.titleField || 'title', df = p.descriptionField || 'description', tm = p.timeField || 'time';
  const tap = tappable(el);
  el.replaceChildren(h('div', { class: 't-tl' }, rows.map((r, i) => {
    const c = color(r.color ?? r.status, 'var(--t-series-1)');
    const ic = r.icon;
    return h('div', { class: 't-tl__item', 'data-tap': tap ? '' : null, tabindex: tap ? '0' : null, on: tap ? { click: () => select(el, 'data', i, r) } : null },
      h('div', { class: 't-tl__rail' }, h('span', { class: 't-tl__dot', 'data-icon': ic ? '' : null, style: { '--t-c': c, background: c } }, ic ? icon(ic) : null), h('span', { class: 't-tl__line' })),
      h('div', { class: 't-tl__body' }, h('div', { class: 't-tl__top' }, h('span', { class: 't-tl__title' }, asText(field(r, tf) ?? r.label)),
        field(r, tm) != null ? h('span', { class: 't-tl__time' }, formatValue(field(r, tm), p.timeFormat || (asDate(field(r, tm)) && typeof field(r, tm) !== 'number' && !/^\d+$/.test(asText(field(r, tm))) ? 'datetime' : null))) : null),
      field(r, df) ? h('div', { class: 't-tl__desc' }, asText(field(r, df))) : null));
  })));
});

/** TreeView {data: {label, value?, icon?, children} | [nodes], labelField?, childrenField?, expanded?: levels, format?}. */
component('tree-view', (el, p) => {
  const lf = p.labelField || 'label', cf = p.childrenField || 'children';
  const levels = p.expanded === true ? 99 : asInt(p.expanded, 1);
  el._open ||= new Map();
  const tap = tappable(el);
  const node = (n, depth, key) => {
    const kids = asList(field(n, cf));
    const open = el._open.has(key) ? el._open.get(key) : depth < levels;
    const label = isMap(n) ? field(n, lf) ?? n.name ?? n.title : n;
    const row = h('div', { class: 't-tree__row', role: 'treeitem', 'aria-expanded': kids.length ? String(open) : null, 'aria-selected': String(el._sel === key), tabindex: '0',
      on: { click: () => { if (kids.length) el._open.set(key, !open); if (tap) { el._sel = key; select(el, 'data', null, n, { path: key }); } el.update(); } } },
    h('span', { class: 't-tree__twist', 'data-open': open ? '' : null, 'data-leaf': kids.length ? null : '' }, icon('chevron_right')),
    n?.icon ? h('span', { class: 't-tree__icon' }, icon(n.icon)) : null,
    h('span', { class: 't-tree__label' }, asText(label)),
    isMap(n) && n.value != null ? h('span', { class: 't-tree__value' }, formatValue(n.value, p.format)) : null);
    return h('div', null, row, kids.length && open ? h('div', { class: 't-tree__kids', role: 'group' }, kids.map((k, i) => node(k, depth + 1, `${key}/${i}`))) : null);
  };
  const roots = Array.isArray(p.data) ? p.data : p.data != null ? [p.data] : [];
  el.replaceChildren(h('div', { class: 't-tree', role: 'tree' }, roots.map((r, i) => node(r, 0, String(i)))));
});

// ---- progress, gauge, rating ----------------------------------------------------------

function circular(t, opts = {}) {
  const size = asDouble(opts.size, 56);
  const stroke = Math.max(3, opts.thickness ?? size / 10);
  const r = (size - stroke) / 2, c = 2 * Math.PI * r;
  const col = opts.color || 'var(--t-series-1)';
  const s = svg('svg', { width: size, height: size, viewBox: `0 0 ${size} ${size}` },
    svg('circle', { cx: size / 2, cy: size / 2, r, fill: 'none', stroke: `color-mix(in srgb, ${col} 20%, var(--t-viz-surface))`, 'stroke-width': stroke }),
    svg('circle', { cx: size / 2, cy: size / 2, r, fill: 'none', stroke: col, 'stroke-width': stroke, 'stroke-linecap': 'round',
      'stroke-dasharray': `${t == null ? c * 0.25 : c * t} ${c}`, style: 'transition: stroke-dasharray .4s var(--t-ease)' }));
  const box = h('span', { class: 't-cprog', 'data-indeterminate': t == null ? '' : null, role: 'progressbar', 'aria-valuenow': t == null ? null : Math.round(t * 100), 'aria-valuemin': '0', 'aria-valuemax': '100' }, s);
  if (opts.text) box.appendChild(h('span', { class: 't-cprog__text', style: { fontSize: Math.max(10, size / 4.5) + 'px' } }, opts.text));
  return box;
}
function linear(t, opts = {}) {
  const col = opts.color || 'var(--t-series-1)';
  return h('div', { class: 't-lprog', 'data-indeterminate': t == null ? '' : null, role: 'progressbar', 'aria-valuenow': t == null ? null : Math.round(t * 100),
    style: { '--t-c': col, '--t-track': `color-mix(in srgb, ${col} 20%, var(--t-viz-surface))`, '--t-thick': px(opts.thickness ?? 8) } }, h('div', { style: { width: `${(t ?? 0) * 100}%` } }));
}
/** Progress {value, max?, variant?: linear|circular, label?, showValue?, format?, color?|status?, size?, thickness?}. */
component('progress', (el, p) => {
  const v = asNum(p.value);
  const max = asNum(p.max) ?? (v != null && v <= 1 ? 1 : 100);
  const t = v == null || max === 0 ? null : Math.max(0, Math.min(1, v / max));
  const col = color(p.color ?? p.status, 'var(--t-series-1)');
  const text = asBool(p.showValue, true) && v != null
    ? (p.format ? formatValue(v, p.format) : max === 1 ? formatValue(v, 'percent') : max === 100 ? `${formatValue(v)}%` : `${formatValue(v)} / ${formatValue(max)}`) : null;
  if (p.variant === 'circular') {
    el.replaceChildren(h('div', { style: { display: 'inline-flex', flexDirection: 'column', alignItems: 'center', gap: '6px' } },
      circular(t, { size: p.size, color: col, text, thickness: p.thickness }), p.label ? h('span', { class: 't-caption' }, asText(p.label)) : null));
    return;
  }
  el.replaceChildren(h('div', { class: 't-column', style: { gap: '6px' } },
    p.label != null || text != null ? h('div', { class: 't-row', style: { gap: '8px' } }, h('span', { style: { flex: '1 1 auto', fontSize: '13px' } }, asText(p.label ?? '')),
      text != null ? h('span', { style: { fontSize: '12px', fontWeight: 500, fontVariantNumeric: 'tabular-nums' } }, text) : null) : null,
    linear(t, { color: col, thickness: p.thickness })));
});
component('linear-progress-indicator', (el, p) => { const v = asNum(p.value); el.replaceChildren(linear(v == null ? null : Math.max(0, Math.min(1, v)), { color: color(p.color, 'var(--t-primary)'), thickness: p.minHeight ?? p.thickness ?? 4 })); });
component('circular-progress-indicator', (el, p) => { const v = asNum(p.value); el.replaceChildren(circular(v == null ? null : Math.max(0, Math.min(1, v)), { size: p.size ?? 36, color: color(p.color, 'var(--t-primary)'), thickness: p.strokeWidth ?? 4 })); });

/** Gauge {value, min?, max?, label?, format?, thresholds?: [{value, status|color}], size?}. */
component('gauge', (el, p) => {
  const min = asDouble(p.min, 0), max = asDouble(p.max, 100);
  const v = asNum(p.value);
  const size = asDouble(p.size, 180);
  const t = v == null ? 0 : Math.max(0, Math.min(1, (v - min) / (max - min || 1)));
  const th = asList(p.thresholds).map((x) => ({ value: asDouble(x.value, max), c: color(x.color ?? x.status, 'var(--t-series-1)') })).sort((a, b) => a.value - b.value);
  const active = th.find((x) => (v ?? min) <= x.value)?.c ?? (th.length ? th[th.length - 1].c : 'var(--t-series-1)');
  const stroke = size / 11, r = size / 2 - stroke, cx = size / 2, cy = size / 2;
  const a0 = Math.PI * 0.75, sweep = Math.PI * 1.5;
  const pt = (a) => [cx + r * Math.cos(a), cy + r * Math.sin(a)];
  const arc = (f0, f1) => { const [x0, y0] = pt(a0 + sweep * f0), [x1, y1] = pt(a0 + sweep * f1); return `M${x0} ${y0}A${r} ${r} 0 ${sweep * (f1 - f0) > Math.PI ? 1 : 0} 1 ${x1} ${y1}`; };
  const s = svg('svg', { width: size, height: size * 0.82, viewBox: `0 0 ${size} ${size * 0.82}`, role: 'img', 'aria-label': `${asText(p.label ?? 'Gauge')}: ${formatValue(v, p.format)}` });
  s.appendChild(svg('path', { d: arc(0, 1), fill: 'none', stroke: 'var(--t-neutral)', 'stroke-width': stroke, 'stroke-linecap': 'round' }));
  let prev = 0;
  for (const x of th) { const f = Math.max(0, Math.min(1, (x.value - min) / (max - min || 1))); s.appendChild(svg('path', { d: arc(prev, f), fill: 'none', stroke: x.c, 'stroke-opacity': '.22', 'stroke-width': stroke })); prev = f; }
  if (t > 0) s.appendChild(svg('path', { d: arc(0, Math.max(0.001, t)), fill: 'none', stroke: active, 'stroke-width': stroke, 'stroke-linecap': 'round' }));
  s.appendChild(svg('text', { x: cx, y: cy + size * 0.04, 'text-anchor': 'middle', 'font-size': size / 6.5, 'font-weight': 600, fill: 'var(--t-on-surface)', style: 'font-variant-numeric: tabular-nums' }, formatValue(v, p.format)));
  if (p.label) s.appendChild(svg('text', { x: cx, y: cy + size * 0.17, 'text-anchor': 'middle', 'font-size': Math.max(11, size / 15), fill: 'var(--t-on-surface-variant)' }, asText(p.label)));
  s.appendChild(svg('text', { x: pt(a0)[0], y: pt(a0)[1] + stroke + 6, 'text-anchor': 'middle', 'font-size': 10.5, fill: 'var(--t-on-surface-variant)' }, formatValue(min, p.format)));
  s.appendChild(svg('text', { x: pt(a0 + sweep)[0], y: pt(a0 + sweep)[1] + stroke + 6, 'text-anchor': 'middle', 'font-size': 10.5, fill: 'var(--t-on-surface-variant)' }, formatValue(max, p.format)));
  el.replaceChildren(h('div', { class: 't-gauge' }, s));
});

/** Rating {value, max?, size?, color?, showValue?, editable?} (editable with a bound value). */
component('rating', (el, p) => {
  const v = asDouble(p.value, 0), max = Math.max(1, Math.min(10, asInt(p.max, 5)));
  const editable = !!p.editable || (isMap(el._raw.value) && el._raw.value.path && p.editable !== false && el.hasAttribute('editable'));
  const stars = [];
  for (let i = 1; i <= max; i++) {
    const on = v >= i - 0.5;
    stars.push(h('button', { type: 'button', disabled: !editable, 'data-off': on ? null : '', 'aria-label': `${i} of ${max}`,
      on: editable ? { click: () => { el.write('value', i); changed(el, i); } } : null }, icon(v >= i ? 'star' : v >= i - 0.5 ? 'star_half' : 'star_border')));
  }
  el.replaceChildren(h('span', { class: 't-rating', role: editable ? 'radiogroup' : 'img', 'aria-label': `${formatValue(v, 'number:1')} of ${max}`,
    style: { '--t-size': px(p.size ?? 20), '--t-c': color(p.color, 'var(--t-warning)') } }, stars, p.showValue ? h('span', { class: 't-rating__value' }, formatValue(v, 'number:1')) : null));
});

// ---- sparkline --------------------------------------------------------------------------

/** A small trend line ([numbers]) as SVG: type line|area|bar. */
function sparkline(values, opts = {}) {
  const vals = asList(values).map((x) => asNum(isMap(x) ? x[opts.field || 'value'] : x));
  const w = asDouble(opts.width, 120), hgt = asDouble(opts.height, 32);
  const nums_ = vals.filter((x) => x != null);
  const s = svg('svg', { width: opts.fill ? '100%' : w, height: hgt, viewBox: `0 0 ${w} ${hgt}`, preserveAspectRatio: 'none', role: 'img', 'aria-label': 'Trend' });
  if (nums_.length < 2) return s;
  const lo = Math.min(...nums_), hi = Math.max(...nums_);
  const up = nums_[nums_.length - 1] >= nums_[0];
  const col = color(opts.color, opts.colorByTrend === false ? 'var(--t-series-1)' : opts.color === undefined && opts.trendColor ? (up ? 'var(--t-good)' : 'var(--t-critical)') : 'var(--t-series-1)');
  const y = (v) => (hi === lo ? hgt / 2 : 2 + (hgt - 4) * (1 - (v - lo) / (hi - lo)));
  if (opts.type === 'bar') {
    const bw = w / vals.length;
    vals.forEach((v, i) => { if (v == null) return; const top = y(Math.max(v, lo)); s.appendChild(svg('rect', { x: i * bw + bw * 0.15, y: top, width: bw * 0.7, height: Math.max(1, hgt - top), rx: 1.5, fill: col })); });
    return s;
  }
  const pts = vals.map((v, i) => (v == null ? null : [(i / (vals.length - 1)) * w, y(v)])).filter(Boolean);
  const d = pts.map(([x, yy], i) => `${i ? 'L' : 'M'}${x.toFixed(2)} ${yy.toFixed(2)}`).join('');
  if (opts.type === 'area') {
    const gid = 'sg' + Math.random().toString(36).slice(2, 8);
    s.appendChild(svg('defs', null, svg('linearGradient', { id: gid, x1: 0, y1: 0, x2: 0, y2: 1 }, svg('stop', { offset: 0, 'stop-color': col, 'stop-opacity': 0.28 }), svg('stop', { offset: 1, 'stop-color': col, 'stop-opacity': 0 }))));
    s.appendChild(svg('path', { d: `${d}L${pts[pts.length - 1][0]} ${hgt}L${pts[0][0]} ${hgt}Z`, fill: `url(#${gid})` }));
  }
  s.appendChild(svg('path', { d, fill: 'none', stroke: col, 'stroke-width': 1.6, 'stroke-linejoin': 'round', 'stroke-linecap': 'round', 'vector-effect': 'non-scaling-stroke' }));
  return s;
}
Aseman.sparkline = sparkline;
/** Sparkline {values (numbers, or rows + field), type?: line|bar|area, color?, height?, width?}. */
component('sparkline', (el, p) => el.replaceChildren(sparkline(p.values ?? p.data, { ...p, trendColor: p.color == null && p.trendColor !== false })));

// ---- data grid --------------------------------------------------------------------------

function cell(col, row, palette) {
  const v = field(row, col.field);
  const fmt = col.format;
  switch (col.type) {
    case 'number': return formatValue(v, fmt);
    case 'trend': return trend(v, { format: fmt || '+number', goodDown: col.goodDirection === 'down' });
    case 'badge': {
      const colors = asMap(col.colors);
      return pill({ text: formatValue(v, fmt), color: color(colors[asText(v)] ?? col.color ?? asText(v).toLowerCase(), series(Object.keys(colors).indexOf(asText(v)) >= 0 ? Object.keys(colors).indexOf(asText(v)) : 0)) });
    }
    case 'progress': {
      const max = asDouble(col.max, 1);
      const t = Math.max(0, Math.min(1, asDouble(v, 0) / (max || 1)));
      return h('div', { class: 't-dg__cellprog' }, linear(t, { color: color(col.color, 'var(--t-series-1)'), thickness: 6 }), h('span', null, formatValue(v, fmt || (max === 1 ? 'percent' : null))));
    }
    case 'sparkline': return sparkline(v, { width: asDouble(col.width, 90), height: 24, trendColor: true });
    case 'image': return v ? h('img', { src: mediaUrl(v), alt: '', loading: 'lazy' }) : '';
    case 'avatar': return h('span', { style: { display: 'inline-flex', alignItems: 'center', gap: '8px' } }, avatar({ name: asText(v), url: col.imageField ? field(row, col.imageField) : null, size: 24 }), col.showName === false ? null : asText(v));
    case 'boolean': return h('span', { class: 't-dg__bool', 'data-on': asBool(v) ? '' : null }, icon(asBool(v) ? 'check_circle' : 'remove_circle_outline'));
    case 'link': return v ? h('a', { href: asText(col.urlField ? field(row, col.urlField) : v), target: '_blank', rel: 'noopener', on: { click: (e) => e.stopPropagation() } }, asText(col.textField ? field(row, col.textField) : v)) : '';
    default: return isMap(v) || Array.isArray(v) ? JSON.stringify(v) : formatValue(v, fmt);
  }
}
const isNumericType = (t) => t === 'number' || t === 'trend' || t === 'progress';

/**
 * DataGrid / Table {data, columns: [{field, label?, type?, format?, align?,
 * width?, max?, colors?, color?}], search?, pageSize?, sortable?, sortBy?,
 * sortDirection?, striped?, dense?, maxHeight?, title?, emptyText?,
 * selection?, action?}. Without columns, every key of the first row.
 */
function dataGrid(el, p) {
  const rows = asRows(p.data ?? p.rows ?? p.items);
  let cols = asList(p.columns).map((c) => (isMap(c) ? c : { field: asText(c) }));
  if (!cols.length && rows.length) cols = Object.keys(rows[0]).filter((k) => !k.startsWith('_')).slice(0, 8).map((k) => ({ field: k, type: typeof rows[0][k] === 'number' ? 'number' : undefined }));
  cols = cols.map((c) => ({ ...c, label: c.label ?? c.title ?? asText(c.field).replace(/[_.-]+/g, ' ').replace(/^\w/, (x) => x.toUpperCase()) }));
  const st = (el._st ||= { q: '', sort: p.sortBy ?? null, dir: p.sortDirection === 'desc' ? -1 : 1, page: 0, sel: null });
  const sortable = p.sortable !== false;
  let idx = rows.map((_, i) => i);
  if (st.q) {
    const q = st.q.toLowerCase();
    idx = idx.filter((i) => cols.some((c) => asText(field(rows[i], c.field)).toLowerCase().includes(q)));
  }
  if (st.sort) {
    const c = cols.find((x) => x.field === st.sort) || { field: st.sort };
    idx.sort((a, b) => {
      const x = field(rows[a], c.field), y = field(rows[b], c.field);
      const nx = asNum(x), ny = asNum(y);
      const r = nx != null && ny != null ? nx - ny : asText(x).localeCompare(asText(y), undefined, { numeric: true });
      return r * st.dir;
    });
  }
  const pageSize = asInt(p.pageSize, 0);
  const pages = pageSize ? Math.max(1, Math.ceil(idx.length / pageSize)) : 1;
  st.page = Math.min(st.page, pages - 1);
  const shown = pageSize ? idx.slice(st.page * pageSize, (st.page + 1) * pageSize) : idx;
  const tap = tappable(el);
  const head = h('tr', null, cols.map((c) => {
    const sorted = st.sort === c.field;
    const align = c.align || (isNumericType(c.type) ? 'right' : null);
    const th = h('th', { 'data-align': align, 'data-sort': sortable ? '' : null, 'aria-sort': sorted ? (st.dir > 0 ? 'ascending' : 'descending') : null, scope: 'col', style: c.width ? { width: px(c.width) } : null },
      asText(c.label), sortable ? icon(sorted && st.dir < 0 ? 'arrow_downward' : 'arrow_upward') : null);
    if (sortable) th.onclick = () => { if (st.sort === c.field) { if (st.dir > 0) st.dir = -1; else { st.sort = null; st.dir = 1; } } else { st.sort = c.field; st.dir = isNumericType(c.type) ? -1 : 1; } el.update(); };
    return th;
  }));
  const body = h('tbody', null, shown.map((i) => {
    const r = rows[i];
    const tr = h('tr', { 'data-tap': tap ? '' : null, 'aria-selected': tap ? String(st.sel === i) : null, tabindex: tap ? '0' : null },
      cols.map((c) => h('td', { 'data-type': c.type || null, 'data-align': c.align || (isNumericType(c.type) ? 'right' : null), style: c.max ? { '--t-max': px(c.max) } : null }, cell(c, r))));
    if (tap) { tr.onclick = () => { st.sel = i; select(el, p.data != null ? 'data' : p.rows != null ? 'rows' : 'items', i, r); el.update(); }; tr.onkeydown = (e) => { if (e.key === 'Enter') tr.click(); }; }
    return tr;
  }));
  const table = h('table', { 'data-fit': cols.length <= 4 ? '' : null }, h('thead', null, head), body);
  const wrap = h('div', { class: 't-dg__wrap', style: p.maxHeight ? { maxHeight: px(p.maxHeight) } : null }, table,
    !shown.length ? h('div', { class: 't-dg__empty' }, st.q ? `No rows match “${st.q}”` : asText(p.emptyText ?? 'Nothing to show yet')) : null);
  // The header (title and search) stays in place across renders, so the
  // search box keeps focus while people type; the rest is replaced.
  if (!el._dg) {
    const input = h('input', { type: 'search', 'aria-label': 'Search the table' });
    input.addEventListener('input', () => { st.q = input.value; st.page = 0; el.update(); });
    const title = h('div', { class: 't-dg__title' });
    const search = h('div', { class: 't-dg__search' }, h('div', { class: 't-field__box' }, h('span', { class: 't-field__prefix' }, icon('search')), input));
    const top = h('div', { class: 't-dg__top' }, title, search);
    const rest = h('div', { class: 't-column', style: { gap: '10px' } });
    el._dg = { root: h('div', { class: 't-dg' }, top, rest), top, title, search, input, rest };
    el.replaceChildren(el._dg.root);
  }
  const g = el._dg;
  g.root.toggleAttribute('data-dense', !!p.dense);
  g.root.toggleAttribute('data-striped', !!p.striped);
  g.title.textContent = asText(p.title ?? '');
  g.input.placeholder = asText(p.searchPlaceholder ?? 'Search');
  g.search.hidden = !p.search;
  g.top.hidden = !p.title && !p.search;
  const pager = pageSize && idx.length > pageSize ? h('div', { class: 't-dg__pager' },
    `${st.page * pageSize + 1}–${Math.min(idx.length, (st.page + 1) * pageSize)} of ${idx.length}`,
    h('button', { class: 't-icon-btn', 'aria-label': 'Previous page', disabled: st.page === 0, on: { click: () => { st.page--; el.update(); } } }, icon('chevron_left')),
    h('button', { class: 't-icon-btn', 'aria-label': 'Next page', disabled: st.page >= pages - 1, on: { click: () => { st.page++; el.update(); } } }, icon('chevron_right'))) : null;
  const scroll = g.rest.querySelector('.t-dg__wrap')?.scrollLeft;
  g.rest.replaceChildren(...[wrap, pager].filter(Boolean));
  if (scroll) wrap.scrollLeft = scroll;
}
component('table', dataGrid);
component('data-grid', dataGrid);
