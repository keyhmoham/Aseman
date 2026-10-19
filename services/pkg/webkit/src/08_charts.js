// ---------------------------------------------------------------------------
// Charts (ui_kit/charts): Chart {type: line|area|bar|scatter|bubble|
// candlestick|histogram|pie|donut|radar|heatmap|treemap}, Heatmap, Treemap,
// Graph. Responsive SVG drawn at the element's width, hairline grid, the
// categorical series hues in order (past eight, "Other"), a legend that
// toggles series, a tooltip with a crosshair, and taps that select a row.
// ---------------------------------------------------------------------------

const textWidth = (s, size = 11) => asText(s).length * size * 0.56;

/** Re-renders an element when its width changes (charts draw at their size). */
function sized(el) {
  if (el._ro) return el.clientWidth || el.parentElement?.clientWidth || 360;
  el._ro = new ResizeObserver(() => {
    const w = Math.round(el.clientWidth);
    if (w && Math.abs(w - (el._w || 0)) > 2) { el._w = w; el.update(); }
  });
  el._ro.observe(el);
  el._w = el.clientWidth;
  return el._w || el.parentElement?.clientWidth || 360;
}

function seriesOf(p, rows) {
  let s = p.series ?? (p.y != null ? asList(p.y) : null);
  if (s == null) {
    const first = rows[0] || {};
    s = Object.keys(first).filter((k) => k !== p.x && typeof first[k] === 'number').slice(0, 8);
    if (!s.length && 'value' in first) s = ['value'];
  }
  return asList(s).map((x, i) => (isMap(x) ? { field: x.field ?? x.y ?? x.key, label: asText(x.label ?? x.name ?? x.field), color: color(x.color, series(i)), i }
    : { field: asText(x), label: asText(x).replace(/[_-]+/g, ' ').replace(/^\w/, (c) => c.toUpperCase()), color: series(i), i }));
}

function frame(el, p, plot, legendItems) {
  const kids = [];
  if (p.title) kids.push(h('div', { class: 't-chart__title' }, asText(p.title)));
  if (p.subtitle) kids.push(h('div', { class: 't-chart__subtitle' }, asText(p.subtitle)));
  kids.push(plot);
  if (legendItems && legendItems.length > 1 && p.legend !== false) {
    el._off ||= new Set();
    kids.push(h('div', { class: 't-legend' }, legendItems.map((s) => h('span', { 'data-off': el._off.has(s.label) ? '' : null, role: 'button', tabindex: '0',
      on: { click: () => { if (el._off.has(s.label)) el._off.delete(s.label); else el._off.add(s.label); el.update(); } } }, h('i', { style: { '--t-c': s.color } }), s.label))));
  }
  el.replaceChildren(h('div', { class: 't-chart' }, kids));
}

function tooltipFor(plotEl) {
  let tip = plotEl.querySelector('.t-ctip');
  if (!tip) { tip = h('div', { class: 't-ctip', hidden: true }); plotEl.appendChild(tip); }
  return {
    show(x, y, head, rows) {
      tip.replaceChildren(h('div', { class: 't-ctip__head' }, head), ...rows.map(([label, value, c]) => h('div', { class: 't-ctip__row' }, h('span', null, c ? h('i', { style: { '--t-c': c } }) : null, label), h('b', null, value))));
      tip.hidden = false;
      const W = plotEl.clientWidth, tw = tip.offsetWidth, th = tip.offsetHeight;
      tip.style.left = Math.max(0, Math.min(W - tw, x + 12 > W - tw ? x - tw - 12 : x + 12)) + 'px';
      tip.style.top = Math.max(0, y - th / 2) + 'px';
    },
    hide() { tip.hidden = true; },
  };
}

const smoothPath = (pts) => {
  if (pts.length < 3) return pts.map(([x, y], i) => `${i ? 'L' : 'M'}${x} ${y}`).join('');
  let d = `M${pts[0][0]} ${pts[0][1]}`;
  for (let i = 0; i < pts.length - 1; i++) {
    const p0 = pts[i - 1] || pts[i], p1 = pts[i], p2 = pts[i + 1], p3 = pts[i + 2] || p2;
    const c1 = [p1[0] + (p2[0] - p0[0]) / 6, p1[1] + (p2[1] - p0[1]) / 6];
    const c2 = [p2[0] - (p3[0] - p1[0]) / 6, p2[1] - (p3[1] - p1[1]) / 6];
    d += `C${c1[0]} ${c1[1]} ${c2[0]} ${c2[1]} ${p2[0]} ${p2[1]}`;
  }
  return d;
};

function histogramRows(p, rows) {
  const f = p.field ?? p.x ?? 'value';
  const vals = rows.map((r) => asNum(field(r, f))).filter((v) => v != null);
  if (!vals.length) return { rows: [], x: 'bin', series: [{ field: 'count', label: 'Count' }] };
  const lo = Math.min(...vals), hi = Math.max(...vals);
  const n = asInt(p.bins, Math.min(30, Math.max(5, Math.ceil(Math.sqrt(vals.length)))));
  const w = (hi - lo) / n || 1;
  const bins = Array.from({ length: n }, (_, i) => ({ from: lo + i * w, to: lo + (i + 1) * w, count: 0 }));
  for (const v of vals) bins[Math.min(n - 1, Math.floor((v - lo) / w))].count++;
  return { rows: bins.map((b) => ({ bin: `${formatValue(b.from, p.xFormat)}–${formatValue(b.to, p.xFormat)}`, ...b })), x: 'bin', series: [{ field: 'count', label: 'Count', color: series(0), i: 0 }] };
}

/** Cartesian charts: line, area, bar (stacked, horizontal), scatter, bubble, candlestick, histogram. */
function cartesian(el, p) {
  let type = p.type || 'line';
  let rows = asRows(p.data);
  let xField = p.x ?? 'label';
  let ser;
  if (type === 'histogram') { const hr = histogramRows(p, rows); rows = hr.rows; xField = hr.x; ser = hr.series; type = 'bar'; }
  else if (type === 'candlestick') ser = [{ field: p.close ?? 'close', label: 'Price', color: series(0), i: 0 }];
  else ser = seriesOf(p, rows);
  if (!p.x && rows.length && !(xField in rows[0])) xField = ['date', 'time', 'x', 'name', 'label', 'category'].find((k) => k in rows[0]) ?? null;
  // Past eight series, the rest fold into "Other".
  if (ser.length > 8) {
    const rest = ser.slice(7);
    rows = rows.map((r) => ({ ...r, __other: rest.reduce((a, s) => a + (asNum(field(r, s.field)) ?? 0), 0) }));
    ser = [...ser.slice(0, 7), { field: '__other', label: 'Other', color: 'var(--t-other)', i: 7 }];
  }
  const W = sized(el);
  const H = asDouble(p.height, 240);
  const plot = h('div', { class: 't-chart__plot', style: { height: H + 'px' } });
  if (!rows.length) { plot.appendChild(h('div', { class: 't-chart__empty', style: { height: '100%' } }, asText(p.emptyText ?? 'No data yet'))); frame(el, p, plot); return; }
  const off = el._off || new Set();
  const live = ser.filter((s) => !off.has(s.label));
  const horizontal = type === 'bar' && !!p.horizontal;
  const xs = rows.map((r) => (xField ? field(r, xField) : null));
  const xNum = (type === 'scatter' || type === 'bubble') || (type !== 'bar' && type !== 'candlestick' && xs.every((v) => typeof v === 'number'));
  const xTime = !xNum && type !== 'bar' && /date|time/.test(p.xFormat || '') && xs.every((v) => asDate(v));
  const band = type === 'bar' || type === 'candlestick' || (!xNum && !xTime);
  const stacked = !!p.stacked && (type === 'bar' || type === 'area');
  // Value domain.
  let lo = Infinity, hi = -Infinity;
  const val = (r, s) => asNum(field(r, s.field));
  rows.forEach((r) => {
    if (type === 'candlestick') {
      for (const k of [p.low ?? 'low', p.high ?? 'high']) { const v = asNum(field(r, k)); if (v != null) { lo = Math.min(lo, v); hi = Math.max(hi, v); } }
    } else if (stacked) {
      let pos = 0, neg = 0;
      for (const s of live) { const v = val(r, s) ?? 0; if (v >= 0) pos += v; else neg += v; }
      lo = Math.min(lo, neg); hi = Math.max(hi, pos);
    } else for (const s of live) { const v = val(r, s); if (v != null) { lo = Math.min(lo, v); hi = Math.max(hi, v); } }
  });
  if (!Number.isFinite(lo)) { lo = 0; hi = 1; }
  if (type === 'bar' || type === 'area' || p.zero) { lo = Math.min(0, lo); hi = Math.max(0, hi); }
  if (p.min != null) lo = asDouble(p.min, lo);
  if (p.max != null) hi = asDouble(p.max, hi);
  const ticks = niceTicks(lo, hi, Math.max(3, Math.min(6, Math.floor((horizontal ? W : H) / 50))));
  const y0 = p.min != null ? lo : ticks[0], y1 = p.max != null ? hi : ticks[ticks.length - 1];
  const yFmt = p.yFormat || (type === 'histogram' ? 'integer' : null);
  const tickLabels = ticks.filter((t) => t >= y0 - 1e-9 && t <= y1 + 1e-9).map((t) => formatValue(t, yFmt && yFmt.startsWith('+') ? yFmt.slice(1) : yFmt));
  // Category labels / x domain.
  const xLabel = (v) => (v == null ? '' : formatValue(v, p.xFormat || (xTime ? 'date' : null)));
  const catLabels = rows.map((r, i) => xLabel(xs[i] ?? i + 1));
  const mL = horizontal ? Math.min(W * 0.35, Math.max(...catLabels.map((s) => textWidth(s))) + 14) : Math.max(...tickLabels.map((s) => textWidth(s))) + 12 + (p.yLabel ? 16 : 0);
  const mR = 12, mT = 10, mB = horizontal ? 24 : 26 + (p.xLabel ? 16 : 0);
  const iw = Math.max(40, W - mL - mR), ih = Math.max(40, H - mT - mB);
  const vScale = (v) => (horizontal ? mL + ((v - y0) / (y1 - y0 || 1)) * iw : mT + ih - ((v - y0) / (y1 - y0 || 1)) * ih);
  let xPos, bw = 0;
  let xd0, xd1;
  if (band) {
    const n = rows.length;
    const step = (horizontal ? ih : iw) / n;
    bw = step * (type === 'candlestick' ? 0.6 : 0.72);
    xPos = (i) => (horizontal ? mT : mL) + step * i + step / 2;
  } else {
    const xv = xs.map((v) => (xTime ? asDate(v).getTime() : asNum(v)));
    xd0 = Math.min(...xv); xd1 = Math.max(...xv);
    if (type === 'scatter' || type === 'bubble') { const t = niceTicks(xd0, xd1, 5); xd0 = t[0]; xd1 = t[t.length - 1]; }
    xPos = (i) => mL + ((xv[i] - xd0) / (xd1 - xd0 || 1)) * iw;
  }
  const s = svg('svg', { width: W, height: H, viewBox: `0 0 ${W} ${H}`, role: 'img', 'aria-label': asText(p.title ?? 'Chart') });
  // Grid and value axis.
  ticks.filter((t) => t >= y0 - 1e-9 && t <= y1 + 1e-9).forEach((t, k) => {
    const v = vScale(t);
    if (horizontal) {
      s.appendChild(svg('line', { class: 't-grid', x1: v, x2: v, y1: mT, y2: mT + ih }));
      s.appendChild(svg('text', { x: v, y: H - 6, 'text-anchor': 'middle' }, tickLabels[k]));
    } else {
      s.appendChild(svg('line', { class: t === 0 && y0 < 0 ? 't-axis' : 't-grid', x1: mL, x2: mL + iw, y1: v, y2: v }));
      s.appendChild(svg('text', { x: mL - 8, y: v + 3.5, 'text-anchor': 'end' }, tickLabels[k]));
    }
  });
  if (!horizontal) s.appendChild(svg('line', { class: 't-axis', x1: mL, x2: mL + iw, y1: mT + ih, y2: mT + ih }));
  // Category / x axis labels, thinned to fit.
  const maxLabels = Math.max(2, Math.floor((horizontal ? ih / 16 : iw / (Math.max(...catLabels.map((c) => textWidth(c))) + 12))));
  if (band) {
    const every = Math.max(1, Math.ceil(rows.length / maxLabels));
    rows.forEach((_, i) => {
      if (i % every) return;
      if (horizontal) s.appendChild(svg('text', { x: mL - 8, y: xPos(i) + 3.5, 'text-anchor': 'end' }, catLabels[i].length > 24 ? catLabels[i].slice(0, 23) + '…' : catLabels[i]));
      else s.appendChild(svg('text', { x: xPos(i), y: mT + ih + 16, 'text-anchor': 'middle' }, catLabels[i]));
    });
  } else {
    const t = xTime ? Array.from({ length: Math.min(maxLabels, 6) }, (_, k) => xd0 + ((xd1 - xd0) * k) / Math.max(1, Math.min(maxLabels, 6) - 1)) : niceTicks(xd0, xd1, Math.min(maxLabels, 6)).filter((v) => v >= xd0 && v <= xd1);
    for (const v of t) {
      const x = mL + ((v - xd0) / (xd1 - xd0 || 1)) * iw;
      if (type === 'scatter' || type === 'bubble') s.appendChild(svg('line', { class: 't-grid', x1: x, x2: x, y1: mT, y2: mT + ih }));
      s.appendChild(svg('text', { x, y: mT + ih + 16, 'text-anchor': 'middle' }, xTime ? formatValue(new Date(v), p.xFormat || 'date') : formatValue(v, p.xFormat)));
    }
  }
  if (p.yLabel) s.appendChild(svg('text', { x: 10, y: mT + ih / 2, transform: `rotate(-90 10 ${mT + ih / 2})`, 'text-anchor': 'middle' }, asText(p.yLabel)));
  if (p.xLabel) s.appendChild(svg('text', { x: mL + iw / 2, y: H - 4, 'text-anchor': 'middle' }, asText(p.xLabel)));
  const marks = svg('g');
  s.appendChild(marks);
  // Marks.
  if (type === 'bar') {
    const groups = stacked ? 1 : live.length;
    const gw = bw / Math.max(1, groups);
    rows.forEach((r, i) => {
      let pos = 0, neg = 0;
      live.forEach((sr, k) => {
        const v = val(r, sr);
        if (v == null) return;
        let a, b;
        if (stacked) { if (v >= 0) { a = pos; b = pos + v; pos = b; } else { a = neg + v; b = neg; neg = a; } } else { a = Math.min(0, v); b = Math.max(0, v); if (y0 > 0) a = Math.max(a, y0); }
        const off_ = stacked ? 0 : k * gw;
        const c = xPos(i) - bw / 2 + off_;
        const va = vScale(a), vb = vScale(b);
        const rect = horizontal
          ? svg('rect', { class: 't-mark', x: Math.min(va, vb), y: c, width: Math.max(1, Math.abs(vb - va)), height: Math.max(1, gw - (groups > 1 ? 2 : 0)), rx: Math.min(4, gw / 3), fill: sr.color })
          : svg('rect', { class: 't-mark', x: c, y: Math.min(va, vb), width: Math.max(1, gw - (groups > 1 ? 2 : 0)), height: Math.max(1, Math.abs(vb - va)), rx: Math.min(4, gw / 3), fill: sr.color });
        rect.dataset.i = i;
        marks.appendChild(rect);
        if (p.valueLabels) marks.appendChild(horizontal
          ? svg('text', { class: 't-v', x: Math.max(va, vb) + 4, y: c + gw / 2 + 3.5 }, formatValue(v, yFmt))
          : svg('text', { class: 't-v', x: c + gw / 2, y: Math.min(va, vb) - 4, 'text-anchor': 'middle' }, formatValue(v, yFmt)));
      });
    });
  } else if (type === 'candlestick') {
    const [o, hk, l, c] = [p.open ?? 'open', p.high ?? 'high', p.low ?? 'low', p.close ?? 'close'];
    rows.forEach((r, i) => {
      const ov = asNum(field(r, o)), hv = asNum(field(r, hk)), lv = asNum(field(r, l)), cv = asNum(field(r, c));
      if ([ov, hv, lv, cv].some((v) => v == null)) return;
      const up = cv >= ov, col = up ? 'var(--t-good)' : 'var(--t-critical)';
      const x = xPos(i);
      marks.appendChild(svg('line', { x1: x, x2: x, y1: vScale(hv), y2: vScale(lv), stroke: col, 'stroke-width': 1.2 }));
      marks.appendChild(svg('rect', { class: 't-mark', 'data-i': i, x: x - bw / 2, y: vScale(Math.max(ov, cv)), width: Math.max(1, bw), height: Math.max(1, Math.abs(vScale(ov) - vScale(cv))), fill: col, rx: 1 }));
    });
  } else if (type === 'scatter' || type === 'bubble') {
    const sf = p.size;
    const sv = sf ? rows.map((r) => asNum(field(r, sf)) ?? 0) : [];
    const smax = Math.max(1, ...sv);
    live.forEach((sr) => rows.forEach((r, i) => {
      const v = val(r, sr); if (v == null) return;
      const rad = type === 'bubble' && sf ? 4 + 14 * Math.sqrt(Math.max(0, sv[i]) / smax) : 4.5;
      marks.appendChild(svg('circle', { class: 't-mark', 'data-i': i, cx: xPos(i), cy: vScale(v), r: rad, fill: sr.color, 'fill-opacity': type === 'bubble' ? 0.55 : 0.85, stroke: sr.color }));
    }));
  } else {
    // line / area
    const base = new Array(rows.length).fill(0);
    live.forEach((sr) => {
      const pts = [], lower = [];
      rows.forEach((r, i) => {
        const v = val(r, sr); if (v == null) return;
        const top = stacked ? base[i] + v : v;
        pts.push([xPos(i), vScale(top)]);
        lower.push([xPos(i), vScale(stacked ? base[i] : Math.max(y0, Math.min(y1, 0)))]);
        if (stacked) base[i] = top;
      });
      if (!pts.length) return;
      const line = p.smooth ? smoothPath(pts) : pts.map(([x, y], i) => `${i ? 'L' : 'M'}${x} ${y}`).join('');
      if (type === 'area') {
        const back = [...lower].reverse();
        const d = `${line}L${back.map(([x, y]) => `${x} ${y}`).join('L')}Z`;
        marks.appendChild(svg('path', { class: 't-mark', d, fill: sr.color, 'fill-opacity': stacked ? 0.55 : 0.16 }));
      }
      marks.appendChild(svg('path', { class: 't-mark', d: line, fill: 'none', stroke: sr.color, 'stroke-width': 2, 'stroke-linejoin': 'round', 'stroke-linecap': 'round' }));
      if (p.points || pts.length <= 12) pts.forEach(([x, y]) => marks.appendChild(svg('circle', { cx: x, cy: y, r: p.points === false ? 0 : 3, fill: 'var(--t-viz-surface)', stroke: sr.color, 'stroke-width': 1.6 })));
    });
  }
  // Hover: crosshair + tooltip; tap selects the nearest row.
  const cross = svg('line', { class: 't-cross', y1: mT, y2: mT + ih, x1: 0, x2: 0, opacity: 0 });
  s.appendChild(cross);
  plot.appendChild(s);
  const tip = tooltipFor(plot);
  const nearest = (mx, my) => {
    if (type === 'scatter' || type === 'bubble') {
      let best = -1, bd = Infinity;
      rows.forEach((r, i) => live.forEach((sr) => { const v = val(r, sr); if (v == null) return; const d = Math.hypot(xPos(i) - mx, vScale(v) - my); if (d < bd) { bd = d; best = i; } }));
      return bd < 30 ? best : -1;
    }
    const pos = horizontal ? my : mx;
    let best = -1, bd = Infinity;
    rows.forEach((_, i) => { const d = Math.abs(xPos(i) - pos); if (d < bd) { bd = d; best = i; } });
    return best;
  };
  const yFmtTip = yFmt;
  s.addEventListener('pointermove', (e) => {
    const r = s.getBoundingClientRect();
    const mx = e.clientX - r.left, my = e.clientY - r.top;
    const i = nearest(mx, my);
    if (i < 0) { tip.hide(); cross.setAttribute('opacity', 0); return; }
    if (!horizontal && type !== 'scatter' && type !== 'bubble') { cross.setAttribute('x1', xPos(i)); cross.setAttribute('x2', xPos(i)); cross.setAttribute('opacity', 1); }
    const row = rows[i];
    const lines = type === 'candlestick'
      ? [['Open', p.open ?? 'open'], ['High', p.high ?? 'high'], ['Low', p.low ?? 'low'], ['Close', p.close ?? 'close']].map(([l, k]) => [l, formatValue(field(row, k), yFmtTip)])
      : live.map((sr) => [sr.label, formatValue(val(row, sr), yFmtTip), sr.color]);
    if ((type === 'bubble') && p.size) lines.push([asText(p.sizeLabel ?? p.size), formatValue(field(row, p.size))]);
    tip.show(mx, my, xField ? (type === 'scatter' || type === 'bubble' ? asText(row.label ?? row.name ?? xLabel(xs[i])) : catLabels[i]) : `#${i + 1}`, lines);
    marks.querySelectorAll('[data-i]').forEach((m) => m.toggleAttribute('data-dim', type === 'bar' || type === 'candlestick' ? m.dataset.i !== String(i) : false));
  });
  s.addEventListener('pointerleave', () => { tip.hide(); cross.setAttribute('opacity', 0); marks.querySelectorAll('[data-dim]').forEach((m) => m.removeAttribute('data-dim')); });
  s.addEventListener('click', (e) => {
    const r = s.getBoundingClientRect();
    const i = nearest(e.clientX - r.left, e.clientY - r.top);
    if (i >= 0) select(el, 'data', i, rows[i]);
  });
  if (tappable(el)) s.style.cursor = 'pointer';
  frame(el, p, plot, type === 'candlestick' ? null : ser);
}

/** Pie and donut {data, label: field, value: field, centerLabel?, format?}. */
function pie(el, p) {
  let rows = asRows(p.data);
  const lf = p.label ?? 'label', vf = p.value ?? 'value';
  rows = rows.filter((r) => (asNum(field(r, vf)) ?? 0) > 0);
  if (rows.length > 8) {
    const sorted = [...rows].sort((a, b) => asNum(field(b, vf)) - asNum(field(a, vf)));
    const other = sorted.slice(7).reduce((a, r) => a + asNum(field(r, vf)), 0);
    rows = [...sorted.slice(0, 7), { [lf]: 'Other', [vf]: other, __other: true }];
  }
  const W = sized(el), H = asDouble(p.height, 240);
  const plot = h('div', { class: 't-chart__plot', style: { height: H + 'px' } });
  const items = rows.map((r, i) => ({ label: asText(field(r, lf)), value: asNum(field(r, vf)), color: r.__other ? 'var(--t-other)' : color(r.color, series(i)), row: r, i }));
  const off = el._off || new Set();
  const live = items.filter((x) => !off.has(x.label));
  const total = live.reduce((a, x) => a + x.value, 0);
  const R = Math.min(W, H) / 2 - 6, cx = W / 2, cy = H / 2;
  const inner = p.type === 'donut' ? R * 0.62 : 0;
  const s = svg('svg', { width: W, height: H, viewBox: `0 0 ${W} ${H}`, role: 'img', 'aria-label': asText(p.title ?? 'Chart') });
  let a = -Math.PI / 2;
  const tip = tooltipFor(plot);
  for (const it of live) {
    const sweep = total ? (it.value / total) * Math.PI * 2 : 0;
    const a1 = a + sweep;
    const pt = (r, ang) => [cx + r * Math.cos(ang), cy + r * Math.sin(ang)];
    const large = sweep > Math.PI ? 1 : 0;
    const [x0, y0] = pt(R, a), [x1, y1] = pt(R, a1 - 1e-6);
    const d = inner ? (() => { const [ix0, iy0] = pt(inner, a1 - 1e-6), [ix1, iy1] = pt(inner, a); return `M${x0} ${y0}A${R} ${R} 0 ${large} 1 ${x1} ${y1}L${ix0} ${iy0}A${inner} ${inner} 0 ${large} 0 ${ix1} ${iy1}Z`; })()
      : `M${cx} ${cy}L${x0} ${y0}A${R} ${R} 0 ${large} 1 ${x1} ${y1}Z`;
    const path = svg('path', { class: 't-mark', d, fill: it.color, stroke: 'var(--t-page-bg)', 'stroke-width': 1.5 });
    path.addEventListener('pointermove', (e) => { const r = plot.getBoundingClientRect(); tip.show(e.clientX - r.left, e.clientY - r.top, it.label, [[formatValue(it.value, p.format), formatValue(it.value / (total || 1), 'percent:1'), it.color]]); });
    path.addEventListener('pointerleave', () => tip.hide());
    path.addEventListener('click', () => select(el, 'data', it.row.__other ? null : asRows(p.data).indexOf(it.row), it.row));
    if (p.valueLabels !== false && sweep > 0.35) {
      const [lx, ly] = pt(inner ? (R + inner) / 2 : R * 0.62, a + sweep / 2);
      s.appendChild(path);
      s.appendChild(svg('text', { x: lx, y: ly + 4, 'text-anchor': 'middle', style: `fill:${onFill(it.color)};font-size:11px;font-weight:600;pointer-events:none` }, formatValue(it.value / (total || 1), 'percent')));
    } else s.appendChild(path);
    a = a1;
  }
  if (inner) {
    s.appendChild(svg('text', { x: cx, y: cy + 2, 'text-anchor': 'middle', style: 'font-size:20px;font-weight:600;fill:var(--t-on-surface)' }, p.centerValue != null ? formatValue(p.centerValue, p.format) : formatValue(total, p.format || 'compact')));
    s.appendChild(svg('text', { x: cx, y: cy + 20, 'text-anchor': 'middle' }, asText(p.centerLabel ?? 'Total')));
  }
  plot.appendChild(s);
  frame(el, p, plot, items);
}

/** Radar {data: rows (one axis each, x field labels them), series}. */
function radar(el, p) {
  const rows = asRows(p.data);
  const ser = seriesOf(p, rows);
  const W = sized(el), H = asDouble(p.height, 280);
  const plot = h('div', { class: 't-chart__plot', style: { height: H + 'px' } });
  const off = el._off || new Set();
  const live = ser.filter((s) => !off.has(s.label));
  const n = rows.length;
  const R = Math.min(W, H) / 2 - 36, cx = W / 2, cy = H / 2;
  const max = p.max != null ? asDouble(p.max, 1) : Math.max(1e-9, ...rows.flatMap((r) => live.map((s) => asNum(field(r, s.field)) ?? 0)));
  const s = svg('svg', { width: W, height: H, viewBox: `0 0 ${W} ${H}`, role: 'img', 'aria-label': asText(p.title ?? 'Chart') });
  const ang = (i) => -Math.PI / 2 + (i / n) * Math.PI * 2;
  for (const f of [0.25, 0.5, 0.75, 1]) s.appendChild(svg('polygon', { class: 't-grid', fill: 'none', points: rows.map((_, i) => `${cx + R * f * Math.cos(ang(i))},${cy + R * f * Math.sin(ang(i))}`).join(' ') }));
  rows.forEach((r, i) => {
    s.appendChild(svg('line', { class: 't-grid', x1: cx, y1: cy, x2: cx + R * Math.cos(ang(i)), y2: cy + R * Math.sin(ang(i)) }));
    const lx = cx + (R + 14) * Math.cos(ang(i)), ly = cy + (R + 14) * Math.sin(ang(i));
    s.appendChild(svg('text', { x: lx, y: ly + 4, 'text-anchor': Math.abs(Math.cos(ang(i))) < 0.2 ? 'middle' : Math.cos(ang(i)) > 0 ? 'start' : 'end' }, asText(field(r, p.x ?? 'label') ?? i + 1)));
  });
  for (const sr of live) {
    const pts = rows.map((r, i) => { const v = Math.max(0, asNum(field(r, sr.field)) ?? 0) / max; return [cx + R * v * Math.cos(ang(i)), cy + R * v * Math.sin(ang(i))]; });
    s.appendChild(svg('polygon', { class: 't-mark', points: pts.map((q) => q.join(',')).join(' '), fill: sr.color, 'fill-opacity': 0.18, stroke: sr.color, 'stroke-width': 2, 'stroke-linejoin': 'round' }));
    pts.forEach(([x, y], i) => { const c = svg('circle', { cx: x, cy: y, r: 3.5, fill: sr.color }); c.addEventListener('click', () => select(el, 'data', i, rows[i])); s.appendChild(c); });
  }
  plot.appendChild(s);
  frame(el, p, plot, ser);
}

/** Chart {type, data, x, series|y, …} (see the README of the kit). */
component('chart', (el, p) => {
  const t = p.type || 'line';
  if (t === 'pie' || t === 'donut') return pie(el, p);
  if (t === 'radar') return radar(el, p);
  if (t === 'heatmap') return heatmap(el, p);
  if (t === 'treemap') return treemap(el, p);
  return cartesian(el, p);
}, { cleanup() { this._ro?.disconnect(); this._ro = null; } });

// ---- heatmap -----------------------------------------------------------------------------

/** Heatmap {data: rows of {x, y, value} (x, y, value rename the fields) | rows, columns, values (matrix); format?, diverging?, showValues?, cellHeight?}. */
function heatmap(el, p) {
  let rowsL, colsL, matrix;
  if (p.values != null && (p.rows != null || p.columns != null)) {
    matrix = asList(p.values).map((r) => asList(r).map(asNum));
    rowsL = asList(p.rows ?? matrix.map((_, i) => i + 1)).map(asText);
    colsL = asList(p.columns ?? (matrix[0] || []).map((_, i) => i + 1)).map(asText);
  } else {
    const xf = p.x ?? 'x', yf = p.y ?? 'y', vf = p.value ?? 'value';
    const data = asRows(p.data);
    colsL = [...new Set(data.map((d) => asText(field(d, xf))))];
    rowsL = [...new Set(data.map((d) => asText(field(d, yf))))];
    matrix = rowsL.map(() => colsL.map(() => null));
    for (const d of data) matrix[rowsL.indexOf(asText(field(d, yf)))][colsL.indexOf(asText(field(d, xf)))] = asNum(field(d, vf));
  }
  const all = matrix.flat().filter((v) => v != null);
  const lo = Math.min(...all, 0), hi = Math.max(...all, 0);
  const div = p.diverging ?? (lo < 0 && hi > 0);
  const bound = Math.max(Math.abs(lo), Math.abs(hi)) || 1;
  const fill = (v) => (v == null ? 'transparent' : div ? diverging(v / bound) : sequential((v - Math.min(...all)) / ((Math.max(...all) - Math.min(...all)) || 1)));
  const showValues = p.showValues ?? colsL.length <= 12;
  const tbl = h('table', null,
    h('thead', null, h('tr', null, h('th'), colsL.map((c) => h('th', { scope: 'col' }, c)))),
    h('tbody', null, rowsL.map((r, i) => h('tr', null, h('th', { scope: 'row', style: { textAlign: 'right' } }, r), colsL.map((c, j) => {
      const v = matrix[i]?.[j];
      const bg = fill(v);
      const td = h('td', { title: `${r} · ${c}: ${formatValue(v, p.format)}`, style: { background: bg, color: v == null ? '' : onFill(bg) } }, showValues && v != null ? formatValue(v, p.format) : '');
      td.onclick = () => select(el, 'data', null, { x: c, y: r, value: v, row: i, column: j });
      return td;
    })))));
  const scale = h('div', { class: 't-heat__scale' }, formatValue(div ? -bound : Math.min(...all), p.format),
    h('div', { style: { background: div ? `linear-gradient(90deg, ${diverging(-1)}, ${diverging(0)}, ${diverging(1)})` : `linear-gradient(90deg, ${sequential(0)}, ${sequential(0.5)}, ${sequential(1)})` } }),
    formatValue(div ? bound : Math.max(...all), p.format));
  const box = h('div', { class: 't-heat', style: { '--t-cell': px(p.cellHeight ?? 28) } }, tbl);
  frame(el, p, h('div', null, box, all.length ? scale : null));
}
component('heatmap', heatmap);

// ---- treemap ------------------------------------------------------------------------------

function squarify(items, x, y, w, hgt) {
  const out = [];
  const total = items.reduce((a, i) => a + i.value, 0) || 1;
  let rest = items.map((i) => ({ ...i, area: (i.value / total) * w * hgt }));
  while (rest.length) {
    const short = Math.min(w, hgt);
    let row = [rest[0]], best = worst(row, short);
    for (let k = 1; k < rest.length; k++) {
      const next = [...row, rest[k]];
      const wv = worst(next, short);
      if (wv > best) break;
      row = next; best = wv;
    }
    const sum = row.reduce((a, r) => a + r.area, 0);
    const thick = sum / short;
    let off = 0;
    for (const r of row) {
      const len = r.area / thick;
      out.push(w >= hgt ? { ...r, x, y: y + off, w: thick, h: len } : { ...r, x: x + off, y, w: len, h: thick });
      off += len;
    }
    if (w >= hgt) { x += thick; w -= thick; } else { y += thick; hgt -= thick; }
    rest = rest.slice(row.length);
  }
  return out;
  function worst(row, side) {
    const s = row.reduce((a, r) => a + r.area, 0);
    const mx = Math.max(...row.map((r) => r.area)), mn = Math.min(...row.map((r) => r.area));
    return Math.max((side * side * mx) / (s * s), (s * s) / (side * side * mn));
  }
}
/** Treemap {data, label, value, group? (categorical color) | colorBy? (signed field), format?, colorFormat?, height?}. */
function treemap(el, p) {
  const lf = p.label ?? 'label', vf = p.value ?? 'value';
  const rows = asRows(p.data);
  const items = rows.map((r, i) => ({ r, i, value: Math.max(0, asNum(field(r, vf)) ?? 0) })).filter((x) => x.value > 0).sort((a, b) => b.value - a.value);
  const W = sized(el), H = asDouble(p.height, 260);
  const groups = p.group ? [...new Set(rows.map((r) => asText(field(r, p.group))))] : [];
  const cb = p.colorBy ? Math.max(1e-9, ...rows.map((r) => Math.abs(asNum(field(r, p.colorBy)) ?? 0))) : 0;
  const box = h('div', { class: 't-treemap', style: { height: H + 'px' } });
  for (const c of squarify(items, 0, 0, W, H)) {
    const bg = p.colorBy ? diverging((asNum(field(c.r, p.colorBy)) ?? 0) / cb) : p.group ? series(groups.indexOf(asText(field(c.r, p.group)))) : series(0);
    const big = c.w > 56 && c.h > 30;
    const tile = h('div', { style: { left: c.x + 'px', top: c.y + 'px', width: c.w + 'px', height: c.h + 'px', background: bg, color: onFill(bg) },
      title: `${asText(field(c.r, lf))}: ${formatValue(c.value, p.format)}${p.colorBy ? ' · ' + formatValue(field(c.r, p.colorBy), p.colorFormat) : ''}` },
    big ? h('b', null, asText(field(c.r, lf))) : null,
    big && c.h > 44 ? h('span', null, p.colorBy ? formatValue(field(c.r, p.colorBy), p.colorFormat || '+percent:1') : formatValue(c.value, p.format)) : null);
    tile.onclick = () => select(el, 'data', c.i, c.r);
    box.appendChild(tile);
  }
  frame(el, p, box, p.group ? groups.map((g, i) => ({ label: g, color: series(i) })) : null);
}
component('treemap', treemap, { cleanup() { this._ro?.disconnect(); this._ro = null; } });

// ---- graph ----------------------------------------------------------------------------------

/** Graph {nodes: [{id, label?, group?, color?}], edges: [{from, to, label?, weight?}], layout?: force|circle|tree, directed?, size? (node field), height?}. */
component('graph', (el, p) => {
  const nodes = asList(p.nodes).map((n, i) => (isMap(n) ? { ...n, id: asText(n.id ?? i) } : { id: asText(n), label: asText(n) }));
  const edges = asList(p.edges).map((e) => ({ ...e, from: asText(e.from ?? e.source), to: asText(e.to ?? e.target) })).filter((e) => nodes.some((n) => n.id === e.from) && nodes.some((n) => n.id === e.to));
  const W = sized(el), H = asDouble(p.height, 320);
  const groups = [...new Set(nodes.map((n) => asText(n.group ?? '')))];
  const key = JSON.stringify([nodes.map((n) => n.id), edges.map((e) => [e.from, e.to]), p.layout, Math.round(W / 40)]);
  if (el._gkey !== key) {
    el._gkey = key;
    const pos = {};
    const layoutName = p.layout || 'force';
    if (layoutName === 'circle') nodes.forEach((n, i) => { const a = (i / nodes.length) * Math.PI * 2 - Math.PI / 2; pos[n.id] = [W / 2 + (Math.min(W, H) / 2 - 40) * Math.cos(a), H / 2 + (Math.min(W, H) / 2 - 40) * Math.sin(a)]; });
    else if (layoutName === 'tree') {
      const kids = {}, hasParent = new Set();
      for (const e of edges) { (kids[e.from] ||= []).push(e.to); hasParent.add(e.to); }
      const roots = nodes.filter((n) => !hasParent.has(n.id));
      const levels = []; const seen = new Set();
      let frontier = (roots.length ? roots : nodes.slice(0, 1)).map((n) => n.id);
      while (frontier.length) { levels.push(frontier); frontier.forEach((f) => seen.add(f)); frontier = frontier.flatMap((f) => kids[f] || []).filter((f) => !seen.has(f)); }
      nodes.forEach((n) => { if (!seen.has(n.id)) (levels[levels.length - 1] ||= []).push(n.id); });
      levels.forEach((lv, d) => lv.forEach((id, i) => { pos[id] = [((i + 1) / (lv.length + 1)) * W, 30 + (d / Math.max(1, levels.length - 1)) * (H - 60)]; }));
    } else {
      nodes.forEach((n, i) => { const a = i * 2.4; pos[n.id] = [W / 2 + Math.cos(a) * 20 * Math.sqrt(i + 1), H / 2 + Math.sin(a) * 20 * Math.sqrt(i + 1)]; });
      const k = Math.sqrt((W * H) / Math.max(1, nodes.length)) * 0.6;
      for (let it = 0; it < 300; it++) {
        const disp = Object.fromEntries(nodes.map((n) => [n.id, [0, 0]]));
        for (let a = 0; a < nodes.length; a++) for (let b = a + 1; b < nodes.length; b++) {
          const A = pos[nodes[a].id], B = pos[nodes[b].id];
          let dx = A[0] - B[0], dy = A[1] - B[1]; const d = Math.max(0.01, Math.hypot(dx, dy));
          const f = (k * k) / d; dx = (dx / d) * f; dy = (dy / d) * f;
          disp[nodes[a].id][0] += dx; disp[nodes[a].id][1] += dy; disp[nodes[b].id][0] -= dx; disp[nodes[b].id][1] -= dy;
        }
        for (const e of edges) {
          const A = pos[e.from], B = pos[e.to];
          let dx = A[0] - B[0], dy = A[1] - B[1]; const d = Math.max(0.01, Math.hypot(dx, dy));
          const f = (d * d) / k; dx = (dx / d) * f; dy = (dy / d) * f;
          disp[e.from][0] -= dx; disp[e.from][1] -= dy; disp[e.to][0] += dx; disp[e.to][1] += dy;
        }
        const t = 10 * (1 - it / 300) + 0.5;
        for (const n of nodes) {
          const [dx, dy] = disp[n.id]; const d = Math.max(0.01, Math.hypot(dx, dy));
          pos[n.id][0] = Math.max(24, Math.min(W - 24, pos[n.id][0] + (dx / d) * Math.min(d, t) + (W / 2 - pos[n.id][0]) * 0.01));
          pos[n.id][1] = Math.max(24, Math.min(H - 24, pos[n.id][1] + (dy / d) * Math.min(d, t) + (H / 2 - pos[n.id][1]) * 0.01));
        }
      }
    }
    el._pos = pos;
  }
  const pos = el._pos;
  const sizes = p.size ? nodes.map((n) => asNum(field(n, p.size)) ?? 0) : [];
  const smax = Math.max(1, ...sizes);
  const radius = (i) => (p.size ? 6 + 12 * Math.sqrt(Math.max(0, sizes[i]) / smax) : 9);
  const s = svg('svg', { width: W, height: H, viewBox: `0 0 ${W} ${H}`, role: 'img', 'aria-label': asText(p.title ?? 'Graph') });
  const mid = 'ga' + Math.random().toString(36).slice(2, 7);
  if (p.directed) s.appendChild(svg('defs', null, svg('marker', { id: mid, viewBox: '0 0 10 10', refX: 10, refY: 5, markerWidth: 7, markerHeight: 7, orient: 'auto-start-reverse' }, svg('path', { d: 'M0 0L10 5L0 10z', fill: 'var(--t-axis)' }))));
  const edgeEls = edges.map((e) => {
    const line = svg('line', { class: 't-edge', 'stroke-width': e.weight ? 1 + Math.min(4, asDouble(e.weight, 1)) : 1.4, 'marker-end': p.directed ? `url(#${mid})` : null });
    const label = e.label ? svg('text', { class: 't-elabel', 'text-anchor': 'middle' }, asText(e.label)) : null;
    s.appendChild(line); if (label) s.appendChild(label);
    return { e, line, label };
  });
  const nodeEls = nodes.map((n, i) => {
    const c = color(n.color, series(groups.indexOf(asText(n.group ?? ''))));
    const g = svg('g', { class: 't-node', 'aria-selected': String(el._selNode === n.id) },
      svg('circle', { r: radius(i), fill: c }),
      svg('text', { y: radius(i) + 13, 'text-anchor': 'middle' }, asText(n.label ?? n.id)));
    s.appendChild(g);
    let drag = null;
    g.addEventListener('pointerdown', (ev) => { drag = [ev.clientX, ev.clientY, ...pos[n.id]]; g.setPointerCapture(ev.pointerId); });
    g.addEventListener('pointermove', (ev) => { if (!drag) return; pos[n.id] = [drag[2] + ev.clientX - drag[0], drag[3] + ev.clientY - drag[1]]; place(); });
    g.addEventListener('pointerup', (ev) => { const moved = drag && Math.hypot(ev.clientX - drag[0], ev.clientY - drag[1]) > 3; drag = null; if (!moved) { el._selNode = n.id; select(el, 'nodes', i, n); el.update(); } });
    return { n, g, i };
  });
  function place() {
    for (const { e, line, label } of edgeEls) {
      const [x1, y1] = pos[e.from], [x2, y2] = pos[e.to];
      const ri = radius(nodes.findIndex((n) => n.id === e.to));
      const d = Math.max(1, Math.hypot(x2 - x1, y2 - y1));
      const ex = p.directed ? x2 - ((x2 - x1) / d) * (ri + 2) : x2, ey = p.directed ? y2 - ((y2 - y1) / d) * (ri + 2) : y2;
      line.setAttribute('x1', x1); line.setAttribute('y1', y1); line.setAttribute('x2', ex); line.setAttribute('y2', ey);
      if (label) { label.setAttribute('x', (x1 + x2) / 2); label.setAttribute('y', (y1 + y2) / 2 - 4); }
    }
    for (const { n, g } of nodeEls) g.setAttribute('transform', `translate(${pos[n.id][0]},${pos[n.id][1]})`);
  }
  place();
  frame(el, p, h('div', { class: 't-graph' }, s), groups.length > 1 ? groups.map((g, i) => ({ label: g || '—', color: series(i) })) : null);
}, { cleanup() { this._ro?.disconnect(); this._ro = null; } });
