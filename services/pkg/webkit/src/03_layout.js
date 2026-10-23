// ---------------------------------------------------------------------------
// Layout: Surface Spec Row/Column/List/Grid/Wrap/Stack/Box/Center/Spacer/AspectRatio/
// Scroll and every Elpian layout, gesture and animation widget (Container,
// Padding, SizedBox, Expanded, Transform, GestureDetector, Dismissible,
// Draggable, AnimatedContainer, Shimmer, Pulse…). Their children are the
// element's own; a <template> child repeats per item of `each`.
// ---------------------------------------------------------------------------

const px = (v) => (v == null || v === '' ? null : typeof v === 'number' ? v + 'px' : /^\d+(\.\d+)?$/.test(v) ? v + 'px' : String(v));
const edges = (v) => (v == null ? null : cssValue('padding', v));
let listSeq = 0;

/**
 * Repeats the element's <template> once per item of [list]: each copy
 * resolves relative bindings ("name", ".") against its item.
 */
function repeat(host, list, path) {
  const tpl = host._tpl || (host._tpl = [...host.children].find((c) => c.localName === 'template'));
  if (!tpl) return false;
  if (path == null) {
    host._listPath ||= `/__lists/${++listSeq}`;
    path = host._listPath;
    const prev = Aseman.data.data.__lists?.[host._listPath.split('/').pop()];
    if (JSON.stringify(prev) !== JSON.stringify(list)) {
      const was = Tracker.active; Tracker.active = null;
      Aseman.data.set(path, list);
      Tracker.active = was;
    }
  }
  const items = asList(list);
  const old = host._copies || [];
  const copies = [];
  for (let i = 0; i < items.length; i++) {
    const scope = `${path}/${i}`;
    let copy = old[i];
    if (!copy || copy._scope !== scope) {
      copy = document.createElement('t-scope');
      copy.style.display = 'contents';
      copy._scope = scope;
      copy.appendChild(tpl.content.cloneNode(true));
    }
    copies.push(copy);
  }
  for (const c of old.slice(items.length)) c.remove();
  // The copies follow the template, in order.
  let anchor = tpl;
  for (const c of copies) {
    if (anchor.nextSibling !== c) host.insertBefore(c, anchor.nextSibling);
    anchor = c;
  }
  host._copies = copies;
  if (!items.length && host.hasAttribute('empty')) {
    host._empty ||= h('div', { class: 't-empty' }, h('div', { class: 't-empty__text' }, host.getAttribute('empty')));
    host.appendChild(host._empty);
  } else host._empty?.remove();
  return true;
}
/** The list an element repeats: its `each` prop (a binding or a literal), and the path when bound. */
function eachOf(el, prop = 'each') {
  const raw = el._raw[prop];
  if (raw == null) return null;
  if (typeof raw === 'string' && raw.startsWith('/')) return { list: Aseman.data.get(raw), path: raw };
  if (isMap(raw) && typeof raw.path === 'string') {
    const path = joinPath(scopeOf(el), raw.path);
    return { list: Aseman.data.get(path), path };
  }
  return { list: resolve(raw, scopeOf(el)), path: null };
}

/** Applies the props every element takes (weight, flex, box sizing, styles). */
function commonStyle(el) {
  const s = el.style;
  const weight = el.p('weight') ?? null;
  if (weight != null && weight !== '') s.flex = `${asDouble(weight, 1)} 1 0`;
  const st = el.p('styles') ?? el.p('css');
  if (isMap(st)) applyStyle(el, st);
}
function boxStyle(el) {
  const s = el.style;
  const P = (k) => el.p(k);
  if (P('padding') != null) s.padding = edges(P('padding'));
  if (P('margin') != null) s.margin = edges(P('margin'));
  for (const k of ['width', 'height', 'minWidth', 'maxWidth', 'minHeight', 'maxHeight']) if (P(k) != null) s[k] = px(P(k));
  if (P('color') != null) s.background = color(P('color'), P('color'));
  if (P('backgroundColor') != null) s.background = color(P('backgroundColor'), P('backgroundColor'));
  if (P('gradient') != null) s.backgroundImage = `linear-gradient(${P('gradientAngle') ?? 135}deg, ${asList(P('gradient')).map((c) => color(c, c)).join(', ')})`;
  if (P('borderRadius') != null || P('radius') != null) {
    const r = P('borderRadius') ?? P('radius');
    s.borderRadius = { card: 'var(--t-radius-card)', inner: 'var(--t-radius-inner)', control: 'var(--t-radius-control)', pill: '999px' }[r] || px(r);
  }
  if (P('borderColor') != null) s.border = `${px(P('borderWidth') ?? 1)} solid ${color(P('borderColor'), P('borderColor'))}`;
  if (P('elevation') != null) s.boxShadow = `var(--t-shadow-${Math.max(1, Math.min(4, Math.round(asDouble(P('elevation'), 1) / 2) || 1))})`;
  if (P('alignment') != null) setAlignment(el, P('alignment'));
  if (P('opacity') != null) s.opacity = P('opacity');
  if (P('clip') === true) s.overflow = 'hidden';
}

class LayoutElement extends TElement {
  render() {
    commonStyle(this);
    this.layout?.();
    const e = eachOf(this);
    if (e) repeat(this, e.list, e.path);
  }
}
function layout(name, fn) {
  return define(name, class extends LayoutElement { layout() { fn(this, (k, d) => this.p(k, d)); } });
}

function flexLayout(el, P, dir) {
  const s = el.style;
  s.flexDirection = (dir ?? (P('direction') === 'horizontal' || P('scrollDirection') === 'horizontal' ? 'row' : null)) || s.flexDirection || '';
  const j = P('justify') ?? P('mainAxisAlignment'), a = P('align') ?? P('crossAxisAlignment');
  if (j) s.justifyContent = JUSTIFY[j] || j;
  if (a) s.alignItems = ALIGN[a] || a;
  const gap = P('gap') ?? P('spacing');
  if (gap != null) s.gap = px(gap);
  if (P('reverse')) s.flexDirection += '-reverse';
  if (P('wrap') === true) s.flexWrap = 'wrap';
  if (P('mainAxisSize') === 'min') s.display = 'inline-flex';
  boxStyle(el);
}
for (const n of ['column', 'col', 'list', 'list-view']) layout(n, (el, P) => {
  flexLayout(el, P, P('direction') === 'horizontal' || P('scrollDirection') === 'horizontal' ? 'row' : 'column');
  if (P('scrollable') !== false && (P('direction') === 'horizontal' || P('scrollDirection') === 'horizontal')) el.style.overflowX = 'auto';
  if (P('maxHeight') != null) el.style.overflowY = 'auto';
});
layout('row', (el, P) => flexLayout(el, P, 'row'));
layout('wrap', (el, P) => {
  const s = el.style;
  if (P('spacing') != null) s.columnGap = px(P('spacing'));
  if (P('runSpacing') != null) s.rowGap = px(P('runSpacing'));
  if (P('gap') != null) s.gap = px(P('gap'));
  const j = P('justify') ?? P('alignment');
  if (j) s.justifyContent = JUSTIFY[j] || j;
  boxStyle(el);
});
/**
 * For {each}: its <template> once per item. (AG-UI surfaces give it a
 * builder instead, which makes each item's component.)
 */
define('for', class extends LayoutElement {
  render() {
    commonStyle(this);
    this.style.display = 'contents';
    const e = eachOf(this);
    if (!e) return;
    if (!this._build) { repeat(this, e.list, e.path); return; }
    const n = asList(e.list).length;
    this._copies ||= [];
    while (this._copies.length > n) this._copies.pop().remove();
    while (this._copies.length < n) { const c = this._build(this._copies.length); this._copies.push(c); this.appendChild(c); }
  }
});

/** Grid {columns? | minColumnWidth? (+maxColumns), gap, runGap}; Elpian GridView {crossAxisCount}. */
function gridLayout(el, P) {
  const s = el.style;
  const gap = P('gap') ?? P('crossAxisSpacing') ?? 12;
  const runGap = P('runGap') ?? P('mainAxisSpacing') ?? gap;
  s.columnGap = px(gap); s.rowGap = px(runGap);
  const cols = P('columns') ?? P('crossAxisCount');
  if (cols != null && P('minColumnWidth') == null) {
    // Never more columns than children.
    const n = Math.max(1, Math.min(asInt(cols, 2), el._copies?.length || [...el.children].filter((c) => c.localName !== 'template').length || 1));
    s.gridTemplateColumns = `repeat(${n}, minmax(0, 1fr))`;
  } else {
    const min = asDouble(P('minColumnWidth'), 220);
    const max = P('maxColumns');
    const g = asDouble(gap, 12);
    const floor = max ? `max(${min}px, calc((100% - ${(asInt(max, 4) - 1) * g}px) / ${asInt(max, 4)}))` : `${min}px`;
    s.gridTemplateColumns = `repeat(auto-fit, minmax(min(${floor}, 100%), 1fr))`;
  }
  if (P('childAspectRatio') != null) for (const c of el.children) c.style.aspectRatio = P('childAspectRatio');
  if (P('align')) s.alignItems = ALIGN[P('align')] || P('align');
  boxStyle(el);
}
layout('grid', gridLayout);
layout('grid-view', gridLayout);
layout('responsive-grid', gridLayout);

layout('stack', (el, P) => {
  const a = P('alignment') ?? 'topLeft';
  const m = { topLeft: 'start start', topCenter: 'start center', topRight: 'start end', centerLeft: 'center start', center: 'center center',
    centerRight: 'center end', bottomLeft: 'end start', bottomCenter: 'end center', bottomRight: 'end end' }[a] || 'start start';
  el.style.placeItems = m;
  if (P('height') != null) el.style.height = px(P('height'));
  if (P('fit') === 'expand') for (const c of el.children) { c.style.width = '100%'; c.style.height = '100%'; }
  boxStyle(el);
});
layout('indexed-stack', (el, P) => {
  const i = asInt(P('index'), 0);
  [...el.children].filter((c) => c.localName !== 'template').forEach((c, k) => { if (k === i) c.setAttribute('data-active', ''); else c.removeAttribute('data-active'); });
  boxStyle(el);
});

// Boxes: Surface Spec Box, Elpian Container / DecoratedBox / Padding / SizedBox / ConstrainedBox / LimitedBox / OverflowBox.
for (const n of ['box', 'container', 'decorated-box', 'padding', 'sized-box', 'constrained-box', 'limited-box', 'overflow-box', 'baseline', 'scope', 'hero']) {
  layout(n, (el, P) => {
    boxStyle(el);
    if (n === 'sized-box' && (P('width') === 'infinity' || P('expand'))) el.style.width = '100%';
    if (n === 'overflow-box') el.style.overflow = 'visible';
    if (n === 'baseline' && P('baseline') != null) el.style.paddingTop = px(P('baseline'));
    if (n === 'hero' && P('tag')) el.style.viewTransitionName = 't-hero-' + String(P('tag')).replace(/[^a-z0-9_-]/gi, '');
  });
}
layout('center', (el, P) => { boxStyle(el); if (P('widthFactor')) el.style.width = `calc(${P('widthFactor')} * 100%)`; });
layout('align', (el, P) => { el.style.display = 'flex'; setAlignment(el, P('alignment', 'center')); boxStyle(el); });
layout('spacer', (el, P) => {
  const size = P('size') ?? P('width') ?? P('height');
  if (size != null) { el.style.flex = `0 0 ${px(size)}`; el.style.width = el.style.height = px(size); }
  else el.style.flex = `${asDouble(P('flex'), 1)} 1 0`;
});
layout('expanded', (el, P) => { el.style.flex = `${asDouble(P('flex'), 1)} 1 0`; boxStyle(el); });
layout('flexible', (el, P) => { el.style.flex = `${asDouble(P('flex'), 1)} 1 auto`; if (P('fit') === 'tight') el.style.flexBasis = '0'; boxStyle(el); });
layout('aspect-ratio', (el, P) => { el.style.aspectRatio = String(P('ratio') ?? P('aspectRatio') ?? 1); boxStyle(el); });
layout('scroll', (el, P) => {
  const horizontal = P('direction') === 'horizontal';
  el.style.overflowX = horizontal ? 'auto' : 'hidden';
  el.style.overflowY = horizontal ? 'hidden' : 'auto';
  if (P('maxHeight') != null) el.style.maxHeight = px(P('maxHeight'));
  if (P('height') != null) el.style.height = px(P('height'));
  if (P('gap') != null) el.style.gap = px(P('gap'));
  if (!horizontal && el.children.length > 1) { el.style.display = 'flex'; el.style.flexDirection = 'column'; el.style.gap ||= '12px'; }
});
layout('fractionally-sized-box', (el, P) => {
  if (P('widthFactor') != null) el.style.width = `${asDouble(P('widthFactor'), 1) * 100}%`;
  if (P('heightFactor') != null) el.style.height = `${asDouble(P('heightFactor'), 1) * 100}%`;
  boxStyle(el);
});
layout('fitted-box', (el, P) => {
  boxStyle(el);
  // Scale the child down to fit (BoxFit.scaleDown/contain).
  const c = el.firstElementChild;
  if (!c) return;
  requestAnimationFrame(() => {
    c.style.transform = '';
    const sw = el.clientWidth / Math.max(1, c.scrollWidth), sh = el.clientHeight ? el.clientHeight / Math.max(1, c.scrollHeight) : sw;
    const k = P('fit') === 'cover' ? Math.max(sw, sh) : Math.min(sw, sh, P('fit') === 'contain' || P('fit') === 'fill' ? Infinity : 1);
    if (Number.isFinite(k) && k > 0 && k !== 1) { c.style.transform = `scale(${k})`; c.style.transformOrigin = 'center'; }
  });
});
layout('clip-rrect', (el, P) => { el.style.borderRadius = px(P('borderRadius') ?? P('radius') ?? 16); boxStyle(el); });
layout('opacity', (el, P) => { el.style.opacity = P('opacity', 1); });
layout('animated-opacity', (el, P) => { el.style.opacity = P('opacity', 1); duration(el, P); });
layout('transform', (el, P) => {
  const t = [];
  if (P('translate') != null) { const [x, y] = asList(P('translate')); t.push(`translate(${px(x ?? 0)}, ${px(y ?? 0)})`); }
  if (P('translateX') != null) t.push(`translateX(${px(P('translateX'))})`);
  if (P('translateY') != null) t.push(`translateY(${px(P('translateY'))})`);
  if (P('rotate') != null || P('angle') != null) { const r = P('rotate') ?? P('angle'); t.push(typeof r === 'number' ? `rotate(${P('angle') != null ? r + 'rad' : r + 'deg'})` : `rotate(${r})`); }
  if (P('scale') != null) t.push(`scale(${P('scale')})`);
  if (P('skewX') != null) t.push(`skewX(${P('skewX')}deg)`);
  if (P('matrix') != null) t.push(`matrix3d(${asList(P('matrix')).join(',')})`);
  el.style.transform = t.join(' ');
  if (P('origin')) el.style.transformOrigin = P('origin');
  boxStyle(el);
});
layout('rotated-box', (el, P) => { el.style.rotate = `${asInt(P('quarterTurns'), 0) * 90}deg`; });
layout('positioned', (el, P) => { for (const k of ['top', 'left', 'right', 'bottom', 'width', 'height']) if (P(k) != null) el.style[k] = px(P(k)); });
layout('animated-positioned', (el, P) => { for (const k of ['top', 'left', 'right', 'bottom', 'width', 'height']) if (P(k) != null) el.style[k] = px(P(k)); duration(el, P); });

function duration(el, P) {
  const d = P('duration') ?? P('transitionDuration') ?? P('animationDuration');
  if (d != null) el.style.setProperty('--t-duration', typeof d === 'number' ? d + 'ms' : d);
  const c = P('curve') ?? P('transitionCurve');
  if (c) el.style.setProperty('--t-curve', CURVES[c] || c);
}
// Implicit animations: the CSS transition animates every change of their props.
for (const n of ['animated-container', 'animated-padding', 'animated-align', 'animated-size', 'animated-default-text-style']) {
  layout(n, (el, P) => {
    duration(el, P); boxStyle(el);
    if (n === 'animated-align') { el.style.display = 'flex'; setAlignment(el, P('alignment', 'center')); }
    if (n === 'animated-default-text-style' && isMap(P('textStyle'))) applyStyle(el, P('textStyle'));
  });
}
layout('animated-scale', (el, P) => { duration(el, P); el.style.transform = `scale(${P('scale', 1)})`; });
layout('animated-rotation', (el, P) => { duration(el, P); el.style.transform = `rotate(${asDouble(P('turns'), 0) * 360}deg)`; });
layout('animated-slide', (el, P) => { duration(el, P); const [x, y] = asList(P('offset', [0, 0])); el.style.transform = `translate(${asDouble(x, 0) * 100}%, ${asDouble(y, 0) * 100}%)`; });
layout('animated-gradient', (el, P) => {
  const cs = asList(P('colors') ?? P('gradientColors') ?? ['#3987e5', '#9085e9', '#e87ba4', '#3987e5']).map((c) => color(c, c));
  el.style.backgroundImage = `linear-gradient(135deg, ${cs.join(', ')})`;
  duration(el, P); boxStyle(el);
});
layout('pulse', (el, P) => { duration(el, P); if (P('scaleBegin') != null) el.style.setProperty('--t-from', P('scaleBegin')); if (P('scaleEnd') != null) el.style.setProperty('--t-to', P('scaleEnd')); });
layout('shimmer', (el, P) => { boxStyle(el); duration(el, P); });
layout('staggered-animation', (el, P) => {
  duration(el, P);
  const delay = asDouble(P('staggerDelay') ?? P('delay'), 100);
  [...el.children].forEach((c, i) => { c.style.animationDelay = `${i * delay}ms`; });
});

/** Explicit transitions (FadeTransition, ScaleTransition…): play once when shown, or follow a value prop. */
const ENTER = {
  'fade-transition': [{ opacity: 0 }, { opacity: 1 }],
  'scale-transition': [{ transform: 'scale(.8)', opacity: 0 }, { transform: 'scale(1)', opacity: 1 }],
  'slide-transition': [{ transform: 'translateY(24px)', opacity: 0 }, { transform: 'none', opacity: 1 }],
  'rotation-transition': [{ transform: 'rotate(-90deg)', opacity: 0 }, { transform: 'none', opacity: 1 }],
  'size-transition': [{ clipPath: 'inset(0 0 100% 0)' }, { clipPath: 'inset(0 0 0 0)' }],
};
for (const [n, frames] of Object.entries(ENTER)) {
  define(n, class extends LayoutElement {
    layout() {
      const P = (k, d) => this.p(k, d);
      const v = P('value') ?? P('opacity') ?? P('scale') ?? P('turns');
      if (v != null) {
        duration(this, P);
        this.style.transition = 'all var(--t-duration, 300ms) var(--t-curve, ease)';
        if (n === 'fade-transition') this.style.opacity = v;
        else if (n === 'scale-transition') this.style.transform = `scale(${v})`;
        else if (n === 'rotation-transition') this.style.transform = `rotate(${asDouble(v, 0) * 360}deg)`;
        else if (n === 'slide-transition') { const [x, y] = asList(P('offset', [0, 0])); this.style.transform = `translate(${asDouble(x, 0) * 100}%, ${asDouble(y, 0) * 100}%)`; }
        return;
      }
      if (!this._played) {
        this._played = true;
        const ms = asDouble(P('duration') ?? P('animationDuration'), 400);
        this.animate(frames, { duration: ms, easing: CURVES[P('curve')] || 'cubic-bezier(.2,0,0,1)', fill: 'both' });
      }
    }
  });
}
/** TweenAnimationBuilder {tweenType: opacity|scale|rotation|translateX|translateY, from, to, duration}. */
define('tween-animation-builder', class extends LayoutElement {
  layout() {
    const P = (k, d) => this.p(k, d);
    const type = P('tweenType', 'opacity');
    const from = asDouble(P('from') ?? P('begin') ?? P('animationFrom'), 0), to = asDouble(P('to') ?? P('end') ?? P('animationTo'), 1);
    const f = (v) => (type === 'scale' ? { transform: `scale(${v})` } : type === 'rotation' ? { transform: `rotate(${v * 360}deg)` }
      : type === 'translateX' ? { transform: `translateX(${v}px)` } : type === 'translateY' ? { transform: `translateY(${v}px)` } : { opacity: v });
    const key = `${type}${from}${to}`;
    if (this._key !== key) {
      this._key = key;
      this.animate([f(from), f(to)], { duration: asDouble(P('duration') ?? P('animationDuration'), 300), easing: CURVES[P('curve')] || 'linear', fill: 'forwards' });
    }
  }
});
/** AnimatedSwitcher: cross-fades when its child changes. */
define('animated-switcher', class extends LayoutElement {
  init() {
    this._mo = new MutationObserver(() => {
      const c = this.lastElementChild;
      if (c) c.animate([{ opacity: 0, transform: this.p('transitionType') === 'scale' ? 'scale(.9)' : 'none' }, { opacity: 1, transform: 'none' }],
        { duration: asDouble(this.p('duration'), 250), easing: 'ease-out' });
    });
    this._mo.observe(this, { childList: true });
  }
});
/** AnimatedCrossFade {showFirst}: the first or the second child, cross-faded. */
define('animated-cross-fade', class extends LayoutElement {
  layout() {
    const first = asBool(this.p('showFirst', true));
    this.style.display = 'grid';
    [...this.children].forEach((c, i) => {
      c.style.gridArea = '1 / 1';
      c.style.transition = `opacity ${asDouble(this.p('duration'), 300)}ms ease`;
      const on = (i === 0) === first;
      c.style.opacity = on ? '1' : '0';
      c.style.pointerEvents = on ? '' : 'none';
      c.setAttribute('aria-hidden', on ? 'false' : 'true');
    });
  }
});

/** GestureDetector / InkWell: taps (action or call), double taps and long presses. */
function gestures(el) {
  if (el._gest) return;
  el._gest = true;
  let timer = null, long = false;
  const fire = (prop, extra) => { const a = actionOf(el, prop); if (a) busy(el, () => runAction(a, el, extra)); el.emit('t-' + (prop === 'action' ? 'tap' : prop), extra); };
  el.addEventListener('click', (e) => { if (long) { long = false; return; } if (!el.p('disabled')) fire('action', { x: e.offsetX, y: e.offsetY }); });
  el.addEventListener('dblclick', () => { if (el._raw.onDoubleTap) fire('onDoubleTap'); });
  el.addEventListener('pointerdown', () => { timer = setTimeout(() => { long = true; if (el._raw.onLongPress) fire('onLongPress'); }, 550); });
  for (const ev of ['pointerup', 'pointerleave', 'pointercancel']) el.addEventListener(ev, () => clearTimeout(timer));
  el.addEventListener('keydown', (e) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); fire('action'); } });
}
for (const n of ['gesture-detector', 'inkwell']) {
  layout(n, (el, P) => {
    boxStyle(el);
    if (!el.hasAttribute('tabindex')) el.tabIndex = 0;
    el.setAttribute('role', 'button');
    if (P('hoverColor')) el.style.setProperty('--t-hover', color(P('hoverColor'), P('hoverColor')));
    gestures(el);
  });
}

/** Dismissible {direction: horizontal|endToStart|startToEnd|up|down, action}: swipe away. */
define('dismissible', class extends LayoutElement {
  init() {
    let x0 = null, dx = 0;
    this.addEventListener('pointerdown', (e) => { x0 = e.clientX; dx = 0; this.setPointerCapture(e.pointerId); this.style.transition = 'none'; });
    this.addEventListener('pointermove', (e) => {
      if (x0 == null) return;
      dx = e.clientX - x0;
      const dir = this.p('direction', 'horizontal');
      if ((dir === 'endToStart' && dx > 0) || (dir === 'startToEnd' && dx < 0)) dx = 0;
      this.style.transform = `translateX(${dx}px)`;
      this.style.opacity = String(1 - Math.min(0.7, Math.abs(dx) / Math.max(1, this.offsetWidth)));
    });
    this.addEventListener('pointerup', () => {
      if (x0 == null) return;
      x0 = null;
      this.style.transition = '';
      if (Math.abs(dx) > this.offsetWidth * asDouble(this.p('threshold'), 0.4)) {
        this.style.transform = `translateX(${dx > 0 ? '' : '-'}110%)`; this.style.opacity = '0';
        setTimeout(() => {
          this.style.maxHeight = this.offsetHeight + 'px';
          requestAnimationFrame(() => { this.style.maxHeight = '0'; this.style.overflow = 'hidden'; this.style.margin = '0'; });
          const a = actionOf(this) ?? this._raw.onDismissed;
          this.emit('t-dismiss', { direction: dx > 0 ? 'startToEnd' : 'endToStart' });
          if (a) runAction(a, this, { direction: dx > 0 ? 'startToEnd' : 'endToStart' });
          setTimeout(() => { if (this.p('remove', true)) this.remove(); }, asDouble(this.p('resizeDuration'), 300));
        }, asDouble(this.p('movementDuration'), 200));
      } else { this.style.transform = ''; this.style.opacity = ''; }
    });
  }
});
/** Draggable {data}: drags its data to DragTargets. */
define('draggable', class extends LayoutElement {
  init() {
    this.draggable = true;
    this.addEventListener('dragstart', (e) => {
      this.dataset.dragging = '';
      e.dataTransfer.setData('application/x-aseman', JSON.stringify(this.p('data') ?? null));
      e.dataTransfer.effectAllowed = 'move';
      Aseman._dragging = this.p('data');
      this.emit('t-drag-start', { data: this.p('data') });
    });
    this.addEventListener('dragend', () => { delete this.dataset.dragging; Aseman._dragging = undefined; this.emit('t-drag-end', {}); });
  }
  layout() { if (this.p('feedbackOpacity') != null) this.style.setProperty('--t-drag-opacity', this.p('feedbackOpacity')); }
});
/** DragTarget {accepts?: [values], action}: runs its action with {data} when something is dropped on it. */
define('drag-target', class extends LayoutElement {
  init() {
    const ok = () => { const acc = this.p('accepts') ?? this.p('accept'); return acc == null || asList(acc).some((a) => JSON.stringify(a) === JSON.stringify(Aseman._dragging) || (isMap(Aseman._dragging) && Aseman._dragging.type === a)); };
    this.addEventListener('dragover', (e) => { if (ok()) { e.preventDefault(); this.dataset.over = ''; } });
    this.addEventListener('dragleave', () => delete this.dataset.over);
    this.addEventListener('drop', (e) => {
      e.preventDefault(); delete this.dataset.over;
      let data = null;
      try { data = JSON.parse(e.dataTransfer.getData('application/x-aseman')); } catch { data = Aseman._dragging; }
      this.emit('t-drop', { data });
      const a = actionOf(this) ?? this._raw.onAccept;
      if (a) busy(this, () => runAction(a, this, { data, value: data }));
    });
  }
});

/** Divider {axis?: vertical, thickness?, color?, indent?}; VerticalDivider. */
layout('divider', (el, P) => {
  const vertical = P('axis') === 'vertical';
  const side = vertical ? 'borderLeft' : 'borderTop';
  if (P('thickness') != null || P('color') != null) el.style[side] = `${px(P('thickness') ?? 1)} solid ${color(P('color'), 'var(--t-outline-variant)')}`;
  if (P('indent') != null) el.style[vertical ? 'marginTop' : 'marginLeft'] = px(P('indent'));
  if (P('height') != null && !vertical) el.style.margin = `${asDouble(P('height'), 8) / 2}px 0`;
});
layout('vertical-divider', (el, P) => {
  if (P('thickness') != null || P('color') != null) el.style.borderLeft = `${px(P('thickness') ?? 1)} solid ${color(P('color'), 'var(--t-outline-variant)')}`;
  if (P('width') != null) el.style.margin = `0 ${asDouble(P('width'), 8) / 2}px`;
});

Object.assign(Aseman, { repeat });
