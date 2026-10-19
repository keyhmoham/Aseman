// ---------------------------------------------------------------------------
// Markets (genui/catalog/markets.dart): Quote, OrderBook, TickerTape,
// AllocationBar, Countdown.
// ---------------------------------------------------------------------------

/**
 * Quote {symbol, name?, price, change?: fraction, changeAbs?, currency?,
 * trend?: [prices], logo?, caption?, size?: row|large, format?, action?}: a
 * live price row that flashes green or red when the price moves.
 */
component('quote', (el, p) => {
  const price = asNum(p.price);
  const fmt = p.format || (p.currency ? `currency:${p.currency}` : 'number:2');
  const large = p.size === 'large';
  const change = asNum(p.change);
  if (el._last != null && price != null && price !== el._last) {
    const dir = price > el._last ? 'up' : 'down';
    requestAnimationFrame(() => {
      const row = el.querySelector('.t-quote');
      if (!row) return;
      row.dataset.flash = dir;
      setTimeout(() => delete row.dataset.flash, 50);
    });
  }
  el._last = price;
  const trendVals = asList(p.trend).map(asNum).filter((x) => x != null);
  const tap = !!actionOf(el) || !!el._raw.selection;
  const row = h('div', { class: 't-quote', 'data-size': large ? 'large' : 'row', 'data-tap': tap ? '' : null, tabindex: tap ? '0' : null },
    !large && p.logo ? h('img', { class: 't-quote__logo', src: mediaUrl(p.logo), alt: '' }) : !large ? avatar({ name: asText(p.symbol), size: 36 }) : null,
    h('div', { class: 't-quote__id' }, h('div', { class: 't-quote__sym' }, asText(p.symbol)), p.name ? h('div', { class: 't-quote__name' }, asText(p.name)) : null),
    !large && trendVals.length > 1 ? sparkline(trendVals, { width: 72, height: 28, trendColor: true }) : null,
    h('div', { class: 't-quote__px' }, h('div', { class: 't-quote__price' }, price == null ? '—' : formatValue(price, fmt)),
      h('div', { style: { display: 'flex', gap: '6px', justifyContent: large ? 'flex-start' : 'flex-end' } },
        change != null ? trend(change, { format: '+percent:2', goodDown: p.goodDirection === 'down' }) : null,
        p.changeAbs != null ? trend(p.changeAbs, { format: '+' + fmt.replace(/^\+/, ''), arrow: false }) : null)),
    large && trendVals.length > 1 ? h('div', { style: { width: '100%' } }, sparkline(trendVals, { width: 300, height: 56, fill: true, type: 'area', trendColor: true })) : null,
    p.caption ? h('div', { class: 't-quote__caption' }, asText(p.caption)) : null);
  if (tap) row.onclick = () => select(el, 'symbol', null, { symbol: p.symbol, price, change, name: p.name });
  el.replaceChildren(row);
});

/** OrderBook {bids: [{price, size}], asks: [{price, size}], levels?, priceFormat?, sizeFormat?, title?, action?}. */
component('order-book', (el, p) => {
  const levels = asInt(p.levels, 8);
  const pf = p.priceFormat || 'number:2', sf = p.sizeFormat || 'compact';
  const norm = (l) => asList(l).map((x) => (Array.isArray(x) ? { price: asNum(x[0]), size: asNum(x[1]) } : { price: asNum(x.price ?? x.p), size: asNum(x.size ?? x.qty ?? x.amount ?? x.s) })).filter((x) => x.price != null && x.size != null);
  const bids = norm(p.bids).sort((a, b) => b.price - a.price).slice(0, levels);
  const asks = norm(p.asks).sort((a, b) => a.price - b.price).slice(0, levels);
  let cb = 0; const bidsC = bids.map((b) => ({ ...b, total: (cb += b.size) }));
  let ca = 0; const asksC = asks.map((a) => ({ ...a, total: (ca += a.size) }));
  const maxT = Math.max(cb, ca, 1e-9);
  const tap = !!actionOf(el) || !!el._raw.selection;
  const rowEl = (side, l) => {
    const r = h('div', { class: 't-ob__row', 'data-side': side, 'data-tap': tap ? '' : null },
      h('div', { class: 't-ob__bar', style: { width: `${(l.total / maxT) * 100}%` } }),
      h('span', null, formatValue(l.price, pf)), h('span', null, formatValue(l.size, sf)), h('span', null, formatValue(l.total, sf)));
    if (tap) r.onclick = () => select(el, side === 'bid' ? 'bids' : 'asks', null, { side, price: l.price, size: l.size });
    return r;
  };
  const spread = bids.length && asks.length ? asks[0].price - bids[0].price : null;
  const mid = spread == null ? null : (asks[0].price + bids[0].price) / 2;
  el.replaceChildren(h('div', { class: 't-ob' }, p.title ? h('div', { class: 't-ob__title' }, asText(p.title)) : null,
    h('div', { class: 't-ob__head' }, h('span', null, 'Price'), h('span', null, 'Size'), h('span', null, 'Total')),
    [...asksC].reverse().map((a) => rowEl('ask', a)),
    spread != null ? h('div', { class: 't-ob__spread' }, `Spread ${formatValue(spread, pf)}${mid ? ` (${formatValue(spread / mid, 'percent:3')})` : ''}`) : null,
    bidsC.map((b) => rowEl('bid', b)),
    !bids.length && !asks.length ? h('div', { class: 't-dg__empty' }, 'No orders') : null));
});

/** TickerTape {data: [{symbol, price, change}], speed?, format?}: a scrolling strip of prices. */
component('ticker-tape', (el, p) => {
  const items = asRows(p.data ?? p.items);
  const one = () => items.map((it) => h('span', { class: 't-tape__item' }, h('b', null, asText(it.symbol ?? it.label)), formatValue(it.price ?? it.value, p.format || 'number:2'),
    it.change != null ? trend(it.change, { format: '+percent:2' }) : null));
  const track = h('div', { class: 't-tape__track', style: { '--t-dur': `${Math.max(8, (items.length * 140) / asDouble(p.speed, 40))}s` } }, one(), one());
  el.replaceChildren(h('div', { class: 't-tape', role: 'marquee', 'aria-label': 'Prices' }, track));
});

/** AllocationBar {data, label: field, value: field, title?, format?}: shares of a whole as one bar. */
component('allocation-bar', (el, p) => {
  const lf = p.label ?? 'label', vf = p.value ?? 'value';
  let rows = asRows(p.data).map((r) => ({ label: asText(field(r, lf)), value: Math.max(0, asNum(field(r, vf)) ?? 0), color: r.color }));
  if (rows.length > 8) { const s = [...rows].sort((a, b) => b.value - a.value); rows = [...s.slice(0, 7), { label: 'Other', value: s.slice(7).reduce((a, r) => a + r.value, 0), other: true }]; }
  const total = rows.reduce((a, r) => a + r.value, 0) || 1;
  const col = (r, i) => (r.other ? 'var(--t-other)' : color(r.color, series(i)));
  el.replaceChildren(h('div', { class: 't-alloc' }, p.title ? h('div', { class: 't-alloc__title' }, asText(p.title)) : null,
    h('div', { class: 't-alloc__bar', role: 'img', 'aria-label': rows.map((r) => `${r.label} ${formatValue(r.value / total, 'percent:1')}`).join(', ') },
      rows.map((r, i) => h('div', { style: { flexGrow: r.value, '--t-c': col(r, i) }, title: `${r.label}: ${formatValue(r.value, p.format)} (${formatValue(r.value / total, 'percent:1')})` }))),
    h('div', { class: 't-alloc__legend' }, rows.map((r, i) => h('span', null, h('i', { style: { '--t-c': col(r, i) } }), r.label, h('b', null, formatValue(r.value / total, p.percentFormat || 'percent:1')))))));
});

/** Countdown {target: ISO time, label?, doneText?}: ticks every second. */
component('countdown', (el, p) => {
  const d = asDate(p.target);
  const tick = () => {
    const ms = d ? d.getTime() - Date.now() : 0;
    const v = el.querySelector('.t-countdown__value');
    if (!v) return;
    if (ms <= 0) { v.textContent = asText(p.doneText ?? 'Now'); clearInterval(el._timer); if (!el._fired) { el._fired = true; el.emit('t-done', {}); const a = actionOf(el); if (a) runAction(a, el); } return; }
    const s = Math.floor(ms / 1000);
    const dd = Math.floor(s / 86400), hh = Math.floor((s % 86400) / 3600), mm = Math.floor((s % 3600) / 60), ss = s % 60;
    const two = (x) => String(x).padStart(2, '0');
    v.textContent = `${dd ? dd + 'd ' : ''}${two(hh)}:${two(mm)}:${two(ss)}`;
  };
  el.replaceChildren(h('span', { class: 't-countdown' }, p.label ? h('span', { class: 't-countdown__label' }, asText(p.label)) : null, h('span', { class: 't-countdown__value', role: 'timer' })));
  clearInterval(el._timer);
  el._fired = false;
  tick();
  el._timer = setInterval(tick, 1000);
}, { cleanup() { clearInterval(this._timer); } });
