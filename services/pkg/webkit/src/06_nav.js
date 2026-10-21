// ---------------------------------------------------------------------------
// Navigation, overlays and conditional UI: Tabs, Modal (and Aseman.dialog /
// confirm), Expandable, Accordion, Carousel, Menu, Steps, Tooltip, Show.
// ---------------------------------------------------------------------------

// ---- tooltip ---------------------------------------------------------------------

let tipEl = null;
function attachTooltip(target, text) {
  const show = () => {
    const msg = typeof text === 'function' ? text() : text;
    if (!msg) return;
    tipEl?.remove();
    tipEl = h('div', { class: 't-tip', role: 'tooltip' }, msg);
    document.body.appendChild(tipEl);
    const r = target.getBoundingClientRect(), t = tipEl.getBoundingClientRect();
    let top = r.top - t.height - 8;
    if (top < 4) top = r.bottom + 8;
    tipEl.style.top = top + 'px';
    tipEl.style.left = Math.max(4, Math.min(innerWidth - t.width - 4, r.left + r.width / 2 - t.width / 2)) + 'px';
  };
  const hide = () => { tipEl?.remove(); tipEl = null; };
  let timer;
  target.addEventListener('pointerenter', () => { timer = setTimeout(show, 450); });
  target.addEventListener('pointerleave', () => { clearTimeout(timer); hide(); });
  target.addEventListener('focus', show);
  target.addEventListener('blur', hide);
  target.addEventListener('touchstart', () => { timer = setTimeout(show, 500); }, { passive: true });
  target.addEventListener('touchend', () => { clearTimeout(timer); setTimeout(hide, 1200); });
}
/** Tooltip {message}: shown over its child on hover, focus and long press. */
define('tooltip', class extends TElement {
  render() {
    if (!this._wired) { this._wired = true; attachTooltip(this, () => asText(this.p('message') ?? this.p('text'))); }
    this.setAttribute('aria-label', asText(this.p('message') ?? ''));
  }
});

// ---- dialogs ---------------------------------------------------------------------

/**
 * Opens a dialog (or a bottom sheet with sheet: true): {title, content (a
 * node, nodes or text), actions: [{label, variant, value, action}]}. Resolves
 * with the pressed action's value (null when dismissed).
 */
function dialog(opts = {}) {
  return new Promise((done) => {
    const overlay = h('div', { class: 't-overlay', 'data-sheet': opts.sheet ? '' : null });
    const close = (v = null) => {
      overlay.style.transition = 'opacity .15s'; overlay.style.opacity = '0';
      setTimeout(() => overlay.remove(), 160);
      document.removeEventListener('keydown', onKey);
      opts.onClose?.(v);
      done(v);
    };
    overlay._close = close;
    const onKey = (e) => { if (e.key === 'Escape') close(); };
    document.addEventListener('keydown', onKey);
    overlay.addEventListener('click', (e) => { if (e.target === overlay && opts.dismissible !== false) close(); });
    const body = h('div', { class: 't-dialog__body' });
    const content = opts.content;
    if (typeof content === 'string') body.innerHTML = markdown(content); else append(body, [content]);
    const actions = asList(opts.actions).map((a) => {
      const b = h('button', { class: 't-btn', 'data-variant': a.variant || 'borderless', type: 'button' }, a.icon ? icon(a.icon) : null, asText(a.label));
      b.onclick = () => {
        if (a.action) busy(b, async () => { await runAction(a.action, b); close(a.value ?? true); });
        else close(a.value ?? a.label);
      };
      return b;
    });
    const box = h('div', { class: 't-dialog', role: 'dialog', 'aria-modal': 'true', 'aria-label': asText(opts.title ?? '') },
      opts.sheet ? h('div', { class: 't-dialog__handle' }) : null,
      opts.title ? h('div', { class: 't-dialog__head' }, h('div', { class: 't-dialog__title' }, asText(opts.title)),
        h('button', { class: 't-icon-btn', 'aria-label': 'Close', on: { click: () => close() } }, icon('close'))) : null,
      body, actions.length ? h('div', { class: 't-dialog__actions' }, actions) : null);
    if (opts.width) box.style.width = `min(${px(opts.width)}, 100%)`;
    overlay.appendChild(box);
    document.body.appendChild(overlay);
    setTimeout(() => (box.querySelector('input, textarea, select, button.t-btn') || box).focus?.(), 50);
  });
}
Aseman.dialog = dialog;
/** await Aseman.confirm('Delete this alert?', {confirm: 'Delete', destructive: true}) → true/false. */
Aseman.confirm = async (message, o = {}) => (await dialog({ title: o.title ?? 'Are you sure?', content: message,
  actions: [{ label: o.cancel ?? 'Cancel', value: false }, { label: o.confirm ?? 'OK', value: true, variant: o.destructive ? 'destructive' : 'primary' }] })) === true;
/** await Aseman.prompt('Name the watchlist', {value}) → the text, or null. */
Aseman.prompt = async (message, o = {}) => {
  const input = h('input', { type: 'text', value: o.value ?? '', placeholder: o.placeholder ?? '' });
  const r = await dialog({ title: o.title ?? message, content: [o.title ? h('p', null, message) : null, input],
    actions: [{ label: 'Cancel', value: false }, { label: o.confirm ?? 'OK', value: true, variant: 'primary' }] });
  return r === true ? input.value : null;
};

/**
 * Modal {title?, variant?: dialog|sheet, open?: {"path"}}: its slot="trigger"
 * child opens the rest of its children in a dialog (or a bottom sheet).
 */
define('modal', class extends TElement {
  render() {
    const p = this.props;
    const kids = this.kids();
    const trigger = kids.filter((k) => k.getAttribute?.('slot') === 'trigger');
    const content = kids.filter((k) => !trigger.includes(k));
    this._content = content;
    if (!this._wired) {
      this._wired = true;
      for (const t of trigger) t.addEventListener('click', () => this.open(), true);
    }
    this.replaceChildren(...trigger);
    const want = asBool(p.open);
    if (want && !this._overlay) this.open();
    if (!want && this._overlay && this._raw.open != null) this.close();
  }
  open() {
    if (this._overlay) return;
    const p = this.props;
    const holder = h('div', { class: 't-column', style: { display: 'contents' } }, this._content);
    holder._scope = scopeOf(this);
    dialog({ title: p.title, sheet: p.variant === 'sheet', content: holder, width: p.width, onClose: () => { this._overlay = null; if (isMap(this._raw.open)) this.write('open', false); } });
    this._overlay = document.querySelector('.t-overlay:last-of-type');
    if (isMap(this._raw.open) && !asBool(this.p('open'))) this.write('open', true);
  }
  close() { this._overlay?._close(); this._overlay = null; }
});

// ---- tabs -------------------------------------------------------------------------

/**
 * Tabs {selected?: {"path"} (index), tabs?: [{title, icon?}]}: each child (a
 * <t-tab title icon>, or any element with a title/label attribute) is a tab.
 */
define('tabs', class extends TElement {
  render() {
    const p = this.props;
    const kids = this.kids().filter((k) => k.nodeType === 1);
    const meta = asList(p.tabs);
    const titles = kids.map((k, i) => ({
      title: asText(meta[i]?.title ?? meta[i]?.label ?? (k.p ? k.p('title') ?? k.p('label') : null) ?? k.getAttribute('title') ?? k.getAttribute('label') ?? `Tab ${i + 1}`),
      icon: meta[i]?.icon ?? (k.p ? k.p('icon') : null) ?? k.getAttribute('icon'),
    }));
    let sel = asInt(p.selected ?? this._sel, 0);
    if (sel >= kids.length) sel = 0;
    const panel = this._panel || (this._panel = h('div', { class: 't-tabs__panel', role: 'tabpanel' }));
    kids.forEach((k, i) => { k.hidden = i !== sel; if (k.parentNode !== panel) panel.appendChild(k); if (k.hasAttribute('title')) { k.dataset.title = k.getAttribute('title'); } });
    const bar = h('div', { class: 't-tabs__bar', role: 'tablist' }, titles.map((t, i) => h('button', { class: 't-tabs__tab', role: 'tab', 'aria-selected': String(i === sel), type: 'button',
      on: { click: () => { this._sel = i; if (this._raw.selected != null && isMap(this._raw.selected)) this.write('selected', i); else this.update(); this.emit('t-tab', { index: i }); } } },
    t.icon ? icon(t.icon) : null, t.title)));
    this.replaceChildren(h('div', { class: 't-tabs' }, bar, panel));
  }
});
layout('tab', () => {});

// ---- expandable, accordion ---------------------------------------------------------

function expander(el, p, kids) {
  const open = el._open ?? asBool(p.expanded ?? p.open, false);
  el._open = open;
  const content = el._content || (el._content = h('div', { class: 't-exp__content' }));
  for (const k of kids) if (k.parentNode !== content) content.appendChild(k);
  const box = el._box || (el._box = h('div', { class: 't-exp' }));
  const head = h('button', { class: 't-exp__head', type: 'button', 'aria-expanded': String(open),
    on: { click: () => {
      el._open = !el._open;
      const acc = el.closest('t-accordion');
      if (el._open && acc && !asBool(acc.p('multiple'))) for (const sib of acc.querySelectorAll('t-expandable')) if (sib !== el && sib._open) { sib._open = false; sib.update(); }
      if (isMap(el._raw.expanded)) el.write('expanded', el._open);
      el.update();
      el.emit('t-toggle', { open: el._open });
    } } },
  p.icon ? icon(p.icon) : null,
  h('div', { class: 't-exp__titles' }, h('div', { class: 't-exp__title' }, asText(p.title ?? '')), p.subtitle ? h('div', { class: 't-exp__subtitle' }, asText(p.subtitle)) : null),
  h('span', { class: 't-exp__chev' }, icon('expand_more')));
  if (open) box.dataset.open = ''; else delete box.dataset.open;
  box.replaceChildren(head, h('div', { class: 't-exp__body' }, h('div', { class: 't-exp__inner' }, content)));
  return box;
}
/** Expandable {title, subtitle?, icon?, expanded?}: its children, folded under a header. */
define('expandable', class extends TElement {
  render() { this.replaceChildren(expander(this, this.props, this.kids())); }
});
/** Accordion {items?: [{title, subtitle?, text}], multiple?}: <t-expandable> children, one open at a time unless multiple. */
define('accordion', class extends TElement {
  render() {
    const p = this.props;
    if (!this._made && asList(p.items).length) {
      this._made = true;
      for (const it of asList(p.items)) {
        const x = el('expandable', { title: it.title, subtitle: it.subtitle, expanded: it.expanded });
        if (it.text) x.appendChild(h('div', { class: 't-md', html: markdown(it.text) }));
        this.appendChild(x);
      }
    }
  }
});

// ---- carousel ----------------------------------------------------------------------

/** Carousel {height?, autoplay?: seconds}: swipeable pages of its children, with dots. */
define('carousel', class extends TElement {
  render() {
    const p = this.props;
    const kids = this.kids().filter((k) => k.nodeType === 1);
    const track = this._track || (this._track = h('div', { class: 't-carousel__track' }));
    for (const k of kids) if (k.parentNode !== track) track.appendChild(k);
    if (p.height) track.style.height = px(p.height);
    const dots = h('div', { class: 't-carousel__dots' }, kids.map((_, i) => h('button', { 'aria-label': `Page ${i + 1}`, on: { click: () => track.scrollTo({ left: i * track.clientWidth }) } })));
    const mark = () => { const i = Math.round(track.scrollLeft / Math.max(1, track.clientWidth)); [...dots.children].forEach((d, k) => d.setAttribute('aria-current', String(k === i))); };
    track.onscroll = () => { clearTimeout(this._st); this._st = setTimeout(mark, 60); };
    const nav = (dir) => h('button', { class: 't-icon-btn t-carousel__nav', 'data-dir': dir, 'aria-label': dir === 'prev' ? 'Previous' : 'Next',
      on: { click: () => track.scrollBy({ left: (dir === 'prev' ? -1 : 1) * track.clientWidth }) } }, icon(dir === 'prev' ? 'chevron_left' : 'chevron_right'));
    this.replaceChildren(h('div', { class: 't-carousel' }, track, kids.length > 1 ? nav('prev') : null, kids.length > 1 ? nav('next') : null), kids.length > 1 ? dots : '');
    requestAnimationFrame(mark);
    clearInterval(this._auto);
    if (p.autoplay) this._auto = setInterval(() => { if (!document.hidden) { const end = track.scrollLeft + track.clientWidth >= track.scrollWidth - 2; track.scrollTo({ left: end ? 0 : track.scrollLeft + track.clientWidth }); } }, asDouble(p.autoplay, 5) * 1000);
  }
  cleanup() { clearInterval(this._auto); }
});

// ---- menu ----------------------------------------------------------------------------

/** Opens a menu of [items] ({label, icon?, action?, destructive?, divider?}) at an element. */
function openMenu(anchor, items, owner) {
  document.querySelector('.t-menu')?._close?.();
  const menu = h('div', { class: 't-menu', role: 'menu' });
  const close = () => { menu.remove(); document.removeEventListener('pointerdown', outside, true); };
  menu._close = close;
  const outside = (e) => { if (!menu.contains(e.target)) close(); };
  for (const it of asList(items)) {
    if (it.divider) { menu.appendChild(h('hr')); continue; }
    menu.appendChild(h('button', { role: 'menuitem', type: 'button', 'data-destructive': it.destructive ? '' : null,
      on: { click: () => { close(); owner?.emit('t-menu', { item: it }); if (it.action) busy(owner || anchor, () => runAction(it.action, owner || anchor, { value: it.value ?? it.label })); } } },
    it.icon ? icon(it.icon) : null, asText(it.label)));
  }
  document.body.appendChild(menu);
  const r = anchor.getBoundingClientRect(), m = menu.getBoundingClientRect();
  menu.style.top = (r.bottom + 4 + m.height > innerHeight ? Math.max(4, r.top - m.height - 4) : r.bottom + 4) + 'px';
  menu.style.left = Math.max(4, Math.min(innerWidth - m.width - 4, r.right - m.width)) + 'px';
  setTimeout(() => document.addEventListener('pointerdown', outside, true));
  menu.querySelector('button')?.focus();
  menu.addEventListener('keydown', (e) => { if (e.key === 'Escape') close(); });
  return menu;
}
Aseman.menu = openMenu;
/** Menu {items: [{label, icon?, action, destructive?}], icon?, label?}: an overflow menu. */
define('menu', class extends TElement {
  render() {
    const p = this.props;
    const btn = p.label
      ? h('button', { class: 't-btn', 'data-variant': p.variant || 'default', type: 'button' }, asText(p.label), icon(p.icon || 'arrow_drop_down'))
      : h('button', { class: 't-icon-btn', type: 'button', 'aria-label': asText(p.tooltip ?? 'More') }, icon(p.icon || 'more_vert'));
    btn.setAttribute('aria-haspopup', 'menu');
    btn.onclick = () => openMenu(btn, this._raw.items ? asList(this._raw.items).map((it) => ({ ...resolve(it, scopeOf(this)), action: it.action })) : [], this);
    this.replaceChildren(btn);
  }
});

// ---- steps ------------------------------------------------------------------------------

/** Steps {steps: [{title, description?, status?: done|current|todo|error}], current?, direction?}. */
component('steps', (el, p) => {
  const steps = asList(p.steps ?? p.data ?? p.items);
  const cur = p.current != null ? asInt(p.current, 0) : -1;
  el.replaceChildren(h('div', { class: 't-steps', 'data-dir': p.direction === 'horizontal' ? 'horizontal' : 'vertical' }, steps.map((s, i) => {
    s = isMap(s) ? s : { title: asText(s) };
    const status = s.status || (cur < 0 ? 'todo' : i < cur ? 'done' : i === cur ? 'current' : 'todo');
    return h('div', { class: 't-step', 'data-status': status },
      h('span', { class: 't-step__dot' }, status === 'done' ? icon('check') : status === 'error' ? icon('close') : String(i + 1)),
      h('span', { class: 't-step__line' }),
      h('div', { class: 't-step__text' }, h('div', { class: 't-step__title' }, asText(s.title ?? s.label)), s.description ? h('div', { class: 't-step__desc' }, asText(s.description)) : null));
  })));
});

// ---- show -----------------------------------------------------------------------------------

/**
 * Show {when}: its children only while the condition holds (a boolean, a
 * {"path"} or a function call); children with slot="fallback" otherwise.
 */
define('show', class extends TElement {
  render() {
    const raw = this._raw.when ?? this._raw.if ?? this._raw.condition;
    let on;
    if (typeof raw === 'string' && raw.startsWith('/')) on = Aseman.data.get(joinPath(scopeOf(this), raw));
    else on = this.p('when') ?? this.p('if') ?? this.p('condition');
    on = Array.isArray(on) ? on.length > 0 : isMap(on) ? Object.keys(on).length > 0 : asBool(on, on != null && on !== '' && on !== 0);
    if (this.hasAttribute('not')) on = !on;
    this.style.display = 'contents';
    if (on) this.dataset.shown = ''; else delete this.dataset.shown;
    for (const k of this.children) {
      const fallback = k.getAttribute('slot') === 'fallback';
      k.hidden = fallback ? on : !on;
    }
  }
});
