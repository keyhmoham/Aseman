// ---------------------------------------------------------------------------
// Content: Text, Markdown, Image, Icon, Video, AudioPlayer, Card, Badge/Tag,
// Chip, MiniTag, StatusTag, Avatar, AvatarGroup, Callout, CodeBlock, JsonView,
// Link, EmptyState, Loading, Skeleton, Panel, PanelHeader, Section, Scaffold,
// AppBar, MathExpression, Canvas.
// ---------------------------------------------------------------------------

const esc = (s) => asText(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

// ---- media urls -----------------------------------------------------------

/**
 * A media url as the page can load it: https and data: as they are, inline
 * SVG markup as a data: URI, stored files (/v1/files/<id>/content or a bare
 * id) through the preview's API, project files as the sandbox serves them.
 */
function mediaUrl(u) {
  if (u == null) return '';
  let s = asText(u).trim();
  if (s.startsWith('<svg')) return 'data:image/svg+xml;charset=utf-8,' + encodeURIComponent(s);
  if (/^(https?:|data:|blob:)/i.test(s)) return s;
  const file = /^\/?v1\/files\/([0-9a-fA-F]{32})\/content/.exec(s) || /^([0-9a-fA-F]{32})$/.exec(s);
  if (file) return previewPrefix() + '/_aseman/api/file/' + file[1];
  if (s.startsWith('/workspace/')) s = s.slice('/workspace'.length);
  return s;
}
Aseman.mediaUrl = mediaUrl;

// ---- markdown ---------------------------------------------------------------

function mdInline(s) {
  let out = esc(s);
  const codes = [];
  out = out.replace(/`([^`]+)`/g, (_, c) => { codes.push(c); return `\u0000${codes.length - 1}\u0000`; });
  out = out
    .replace(/!\[([^\]]*)\]\(([^)\s]+)(?:\s+&quot;[^&]*&quot;)?\)/g, (_, alt, src) => `<img alt="${alt}" src="${esc(mediaUrl(src.replace(/&amp;/g, '&')))}">`)
    .replace(/\[([^\]]+)\]\(([^)\s]+)\)/g, (_, t, href) => {
      const u = href.replace(/&amp;/g, '&');
      return /^(https?:|mailto:|\/|#|\.)/.test(u) ? `<a href="${esc(u)}" target="${u.startsWith('#') ? '_self' : '_blank'}" rel="noopener">${t}</a>` : t;
    })
    .replace(/(^|[\s(])(https?:\/\/[^\s<)]+)/g, '$1<a href="$2" target="_blank" rel="noopener">$2</a>')
    .replace(/\*\*([^*]+)\*\*|__([^_]+)__/g, (_, a, b) => `<strong>${a ?? b}</strong>`)
    .replace(/(^|[^*])\*([^*\s][^*]*)\*/g, '$1<em>$2</em>')
    .replace(/(^|\W)_([^_\s][^_]*)_(?=\W|$)/g, '$1<em>$2</em>')
    .replace(/~~([^~]+)~~/g, '<del>$1</del>')
    .replace(/==([^=]+)==/g, '<mark>$1</mark>');
  return out.replace(/\u0000(\d+)\u0000/g, (_, i) => `<code>${codes[+i]}</code>`);
}
/** Markdown (headings, lists, tasks, tables, quotes, code, rules, images, links) as HTML. */
function markdown(src) {
  const lines = asText(src).replace(/\r\n?/g, '\n').split('\n');
  const out = [];
  let i = 0;
  const para = [];
  const flush = () => { if (para.length) { out.push(`<p>${para.map(mdInline).join('<br>')}</p>`); para.length = 0; } };
  while (i < lines.length) {
    const line = lines[i];
    let m;
    if (/^\s*$/.test(line)) { flush(); i++; continue; }
    if ((m = /^```\s*(\w+)?/.exec(line))) {
      flush();
      const lang = m[1] || '';
      const body = [];
      i++;
      while (i < lines.length && !/^```/.test(lines[i])) body.push(lines[i++]);
      i++;
      out.push(`<pre data-lang="${esc(lang)}"><code>${highlight(body.join('\n'), lang)}</code></pre>`);
      continue;
    }
    if ((m = /^(#{1,6})\s+(.*)$/.exec(line))) { flush(); out.push(`<h${m[1].length}>${mdInline(m[2].replace(/\s+#+\s*$/, ''))}</h${m[1].length}>`); i++; continue; }
    if (/^\s*([-*_])(\s*\1){2,}\s*$/.test(line)) { flush(); out.push('<hr>'); i++; continue; }
    if (/^\s*>/.test(line)) {
      flush();
      const q = [];
      while (i < lines.length && /^\s*>/.test(lines[i])) q.push(lines[i++].replace(/^\s*>\s?/, ''));
      out.push(`<blockquote>${markdown(q.join('\n'))}</blockquote>`);
      continue;
    }
    if (/^\s*\|.*\|\s*$/.test(line) && i + 1 < lines.length && /^\s*\|?\s*:?-{2,}/.test(lines[i + 1])) {
      flush();
      const cells = (l) => l.trim().replace(/^\||\|$/g, '').split('|').map((c) => c.trim());
      const head = cells(line);
      const aligns = cells(lines[i + 1]).map((c) => (/^:-+:$/.test(c) ? 'center' : /-+:$/.test(c) ? 'right' : 'left'));
      i += 2;
      const rows = [];
      while (i < lines.length && /^\s*\|.*\|\s*$/.test(lines[i])) rows.push(cells(lines[i++]));
      out.push(`<table><thead><tr>${head.map((c, k) => `<th style="text-align:${aligns[k]}">${mdInline(c)}</th>`).join('')}</tr></thead><tbody>${rows.map((r) => `<tr>${r.map((c, k) => `<td style="text-align:${aligns[k] || 'left'}">${mdInline(c)}</td>`).join('')}</tr>`).join('')}</tbody></table>`);
      continue;
    }
    if ((m = /^(\s*)([-*+]|\d+[.)])\s+/.exec(line))) {
      flush();
      const ordered = /\d/.test(m[2]);
      const items = [];
      while (i < lines.length && (m = /^(\s*)([-*+]|\d+[.)])\s+(.*)$/.exec(lines[i]))) {
        let text = m[3];
        i++;
        while (i < lines.length && /^\s{2,}\S/.test(lines[i]) && !/^\s*([-*+]|\d+[.)])\s+/.test(lines[i])) text += ' ' + lines[i++].trim();
        const task = /^\[([ xX])\]\s+(.*)$/.exec(text);
        items.push(task ? `<li style="list-style:none;margin-left:-1.2em"><input type="checkbox" disabled ${task[1] !== ' ' ? 'checked' : ''}> ${mdInline(task[2])}</li>` : `<li>${mdInline(text)}</li>`);
      }
      out.push(ordered ? `<ol>${items.join('')}</ol>` : `<ul>${items.join('')}</ul>`);
      continue;
    }
    para.push(line.trim());
    i++;
  }
  flush();
  return out.join('');
}
const MD_HINT = /(^|\n)\s*(#{1,6}\s|[-*+]\s|\d+[.)]\s|>|```|\|.*\|)|\*\*|__|`|\[[^\]]+\]\(|~~/;
Aseman.markdown = markdown;

// ---- code -----------------------------------------------------------------

const KEYWORDS = /\b(abstract|async|await|break|case|catch|class|const|continue|def|default|defer|delete|do|elif|else|enum|export|extends|false|final|finally|fn|for|from|func|function|go|if|impl|import|in|interface|is|lambda|let|loop|match|mod|module|new|nil|None|null|package|pass|pub|raise|return|select|self|static|struct|super|switch|this|throw|True|true|False|try|type|typeof|undefined|var|void|while|with|yield)\b/g;
function highlight(code, lang) {
  const src = esc(code);
  if (lang === 'text' || lang === 'plain') return src;
  const parts = [];
  const re = /(\/\/[^\n]*|#[^\n]*|\/\*[\s\S]*?\*\/|&quot;(?:[^&]|&(?!quot;))*?&quot;|&#39;(?:[^&]|&(?!#39;))*?&#39;|`[^`]*`|\b\d+(?:\.\d+)?\b)/g;
  let last = 0, m;
  while ((m = re.exec(src))) {
    parts.push(src.slice(last, m.index).replace(KEYWORDS, '<span class="tk-k">$1</span>').replace(/\b([a-zA-Z_]\w*)(?=\()/g, '<span class="tk-f">$1</span>'));
    const t = m[0];
    const isComment = t.startsWith('//') || t.startsWith('/*') || (t.startsWith('#') && !/json|css|html/.test(lang || ''));
    parts.push(`<span class="${isComment ? 'tk-c' : /^\d/.test(t) ? 'tk-n' : t.startsWith('#') ? '' : 'tk-s'}">${t}</span>`);
    last = m.index + t.length;
  }
  parts.push(src.slice(last).replace(KEYWORDS, '<span class="tk-k">$1</span>').replace(/\b([a-zA-Z_]\w*)(?=\()/g, '<span class="tk-f">$1</span>'));
  return parts.join('');
}

// ---- text -----------------------------------------------------------------

/** Text {text|data, variant: h1…h5|body|caption, markdown?, maxLines?, textAlign?, color?, weight?, size?, format?}. */
component('text', (el, p) => {
  // <t-text>Plain words</t-text>: its own text, kept the first time.
  if (el._own == null && !el._rendered) el._own = el.textContent;
  const raw = p.text ?? p.data ?? p.value ?? el._own ?? '';
  const value = p.format ? formatValue(raw, p.format) : typeof raw === 'number' ? formatValue(raw) : asText(raw);
  if (p.variant && !el.hasAttribute('variant')) el.setAttribute('variant', p.variant);
  const md = p.markdown ?? (p.variant !== 'caption' && MD_HINT.test(value));
  if (md) el.innerHTML = markdown(value);
  else el.textContent = value;
  const s = el.style;
  if (p.textAlign || p.align) s.textAlign = p.textAlign || p.align;
  if (p.color) s.color = color(p.color, p.color);
  if (p.weight || p.fontWeight) s.fontWeight = p.weight || p.fontWeight;
  if (p.size || p.fontSize) s.fontSize = px(p.size || p.fontSize);
  if (p.italic) s.fontStyle = 'italic';
  if (p.maxLines) { el.setAttribute('max-lines', ''); s.setProperty('--t-lines', p.maxLines); }
  if (p.softWrap === false || p.overflow === 'ellipsis') { s.whiteSpace = 'nowrap'; s.overflow = 'hidden'; s.textOverflow = 'ellipsis'; }
  if (isMap(p.style)) applyStyle(el, p.style);
  commonStyle(el);
});
/** Markdown {text}: long-form notes. */
component('markdown', (el, p) => {
  if (el._src == null) el._src = el.textContent;
  el.className = 't-md';
  el.innerHTML = markdown(p.text ?? p.value ?? p.markdown ?? el._src);
});

// ---- icons, images, media ---------------------------------------------------

/** Icon {name|icon, size?, color?, svgPath?}. */
component('icon', (el, p) => {
  const name = p.name ?? p.icon ?? el.getAttribute('name') ?? el._own ?? (el._own = el.textContent.trim());
  const i = icon(p.svgPath || name, p.size);
  el.replaceChildren(...i.childNodes);
  if (p.size) el.style.setProperty('--t-icon', px(p.size));
  if (p.color) el.style.color = color(p.color, p.color);
  el.setAttribute('role', p.semanticLabel || p.label ? 'img' : 'presentation');
  if (p.semanticLabel || p.label) el.setAttribute('aria-label', p.semanticLabel || p.label);
});

const IMAGE_SIZES = { icon: [24, 24], avatar: [40, 40], smallFeature: [120, 90], mediumFeature: [null, 180], largeFeature: [null, 260], header: [null, 220] };
/** Image {url|src, fit?, variant?: icon|avatar|smallFeature|mediumFeature|largeFeature|header, height?, alt?, radius?}. */
component('image', (el, p) => {
  const url = mediaUrl(p.url ?? p.src);
  const variant = p.variant || 'mediumFeature';
  if (!el.hasAttribute('variant')) el.setAttribute('variant', variant);
  const [w, hgt] = IMAGE_SIZES[variant] || [null, null];
  if (p.fit) el.style.setProperty('--t-fit', { fill: 'fill', contain: 'contain', cover: 'cover', fitWidth: 'contain', fitHeight: 'contain', none: 'none', scaleDown: 'scale-down' }[p.fit] || p.fit);
  if (el._url === url) return;
  el._url = url;
  const img = h('img', { src: url, alt: asText(p.alt ?? p.description ?? ''), loading: 'lazy', decoding: 'async' });
  if (p.height ?? hgt) img.style.height = px(p.height ?? hgt);
  if (p.width ?? w) img.style.width = px(p.width ?? w);
  if (p.radius != null) img.style.borderRadius = px(p.radius);
  img.onerror = () => el.replaceChildren(h('div', { class: 't-img-fallback', style: { height: px(p.height ?? hgt ?? 120) } }, icon('broken_image')));
  el.replaceChildren(url ? img : h('div', { class: 't-img-fallback', style: { height: px(p.height ?? hgt ?? 120) } }, icon('image')));
});
/** Video {url, autoplay?, loop?, muted?, poster?}. */
component('video', (el, p) => {
  const url = mediaUrl(p.url ?? p.src);
  if (el._url === url) return;
  el._url = url;
  el.replaceChildren(h('video', { src: url, controls: p.controls !== false, autoplay: !!p.autoplay, loop: !!p.loop, muted: !!(p.muted ?? p.autoplay), playsInline: true, poster: p.poster ? mediaUrl(p.poster) : null, preload: 'metadata' }));
});
/** AudioPlayer {url, description?}: the app's play button, progress and time. */
component('audio-player', (el, p) => {
  const url = mediaUrl(p.url ?? p.src);
  if (el._url === url && el._audio) { el.querySelector('.t-audio__desc').textContent = asText(p.description ?? p.title ?? ''); return; }
  el._url = url;
  const audio = new Audio(url);
  audio.preload = 'metadata';
  el._audio = audio;
  const btn = h('button', { class: 't-audio__play', 'aria-label': 'Play' }, icon('play_arrow'));
  const fill = h('div');
  const bar = h('div', { class: 't-audio__bar' }, fill);
  const time = h('span', { class: 't-audio__time' }, '0:00');
  const fmt = (t) => (Number.isFinite(t) ? `${Math.floor(t / 60)}:${String(Math.floor(t % 60)).padStart(2, '0')}` : '0:00');
  btn.onclick = () => (audio.paused ? audio.play() : audio.pause());
  audio.onplay = () => btn.replaceChildren(icon('pause'));
  audio.onpause = audio.onended = () => btn.replaceChildren(icon('play_arrow'));
  audio.ontimeupdate = audio.onloadedmetadata = () => { fill.style.width = `${(audio.currentTime / (audio.duration || 1)) * 100}%`; time.textContent = `${fmt(audio.currentTime)} / ${fmt(audio.duration)}`; };
  bar.onclick = (e) => { if (audio.duration) audio.currentTime = (e.offsetX / bar.clientWidth) * audio.duration; };
  el.replaceChildren(h('div', { class: 't-audio' }, btn, h('div', { class: 't-audio__main' }, h('div', { class: 't-audio__desc' }, asText(p.description ?? p.title ?? '')), bar, time)));
}, { cleanup() { this._audio?.pause(); } });

// ---- cards and surfaces -----------------------------------------------------

/** Card {variant?: outlined|filled|elevated, padding?, action?|call?}: an outlined surface. */
layout('card', (el, P) => {
  if (P('variant') && !el.hasAttribute('variant')) el.setAttribute('variant', P('variant'));
  if (P('padding') != null) el.style.padding = edges(P('padding'));
  if (P('gap') != null) el.style.gap = px(P('gap'));
  boxStyle(el);
  if (P('color') != null) el.style.background = color(P('color'), P('color'));
  if (actionOf(el)) { el.tabIndex = 0; el.setAttribute('role', 'button'); gestures(el); }
});
/** Panel {padding?}: the app's AppPanel (a large outlined surface). */
layout('panel', (el, P) => { if (P('padding') != null) el.style.padding = edges(P('padding')); boxStyle(el); });

/** PanelHeader {title, subtitle?, icon?}: the app's panel title with its tonal icon tile; children trail. */
define('panel-header', class extends TElement {
  render() {
    const p = this.props;
    const kids = this.kids();
    this.className = 't-panel-header';
    this.replaceChildren(
      p.icon ? h('span', { class: 't-panel-header__icon' }, icon(p.icon)) : null,
      h('div', { class: 't-panel-header__text' }, h('div', { class: 't-panel-header__title' }, asText(p.title)), p.subtitle ? h('div', { class: 't-panel-header__subtitle' }, asText(p.subtitle)) : null),
      ...kids);
  }
});

/** Section {title, subtitle?, icon?, trailing?, gap?}: a titled block of its children. */
define('section', class extends TElement {
  render() {
    const p = this.props;
    const kids = this.kids();
    const trailing = kids.filter((k) => k.getAttribute?.('slot') === 'trailing');
    const body = this._body || (this._body = h('div', { class: 't-section__body' }));
    for (const k of kids) if (!trailing.includes(k) && k.parentNode !== body) body.appendChild(k);
    if (p.gap != null) body.style.gap = px(p.gap);
    const head = p.title || p.subtitle || p.icon || trailing.length || p.trailing
      ? h('div', { class: 't-section__head' },
        p.icon ? h('span', { class: 't-section__icon' }, icon(p.icon)) : null,
        h('div', { class: 't-section__titles' }, p.title ? h('div', { class: 't-section__title', role: 'heading', 'aria-level': '3' }, asText(p.title)) : null,
          p.subtitle ? h('div', { class: 't-section__subtitle' }, asText(p.subtitle)) : null),
        typeof p.trailing === 'string' ? h('span', { class: 't-caption' }, p.trailing) : null, ...trailing)
      : null;
    this.replaceChildren(...[head, body].filter(Boolean));
    commonStyle(this);
  }
});

/** Callout {title?, text, severity: info|good|warning|critical, icon?}; children below the text. */
define('callout', class extends TElement {
  render() {
    const p = this.props;
    const kids = this.kids();
    const sev = p.severity || p.status || 'info';
    const c = sev === 'info' ? 'var(--t-series-1)' : statusColor(sev);
    const ic = p.icon || { info: 'info', good: 'check_circle', success: 'check_circle', warning: 'warning_amber', serious: 'report', critical: 'error_outline', error: 'error_outline' }[sev] || 'info';
    const body = h('div', { class: 't-callout__body' },
      p.title ? h('div', { class: 't-callout__title' }, asText(p.title)) : null,
      p.text != null ? h('div', { class: 't-callout__text', html: mdInline(asText(p.text)) }) : null, ...kids);
    this.replaceChildren(h('div', { class: 't-callout', role: sev === 'critical' || sev === 'error' ? 'alert' : 'note', style: { '--t-c': c } }, icon(ic), body));
  }
});

// ---- badges, chips, avatars ---------------------------------------------------

function pill(p) {
  const c = color(p.color ?? p.status, 'var(--t-series-1)');
  const variant = p.variant || 'tonal';
  const span = h('span', { class: 't-pill', 'data-variant': variant, style: { '--t-c': c } });
  if (p.icon) { span.dataset.icon = ''; span.appendChild(icon(p.icon)); }
  span.appendChild(h('span', null, p.format ? formatValue(p.text ?? p.label ?? p.value, p.format) : asText(p.text ?? p.label ?? p.value ?? '')));
  if (variant === 'filled') span.style.setProperty('--t-ink', onFill(c));
  return span;
}
Aseman.pill = pill;
/** Badge / Tag {text, status?|color?, variant?: tonal|filled|outline, icon?}; Elpian Badge {label|count} on its child. */
for (const n of ['badge', 'tag', 'status-tag']) {
  define(n, class extends TElement {
    render() {
      const p = this.props;
      const kids = this.kids();
      if (n === 'badge' && kids.length && (p.label != null || p.count != null) && p.text == null) {
        // Elpian Badge: a count (or a dot) on its child.
        const count = p.count ?? p.label;
        this.replaceChildren(...kids, h('span', { class: 't-count' }, count === true || count === '' ? '' : asText(count)));
        return;
      }
      if (p.text == null && p.label == null && p.value == null && kids.length) this._raw.text = this.textContent.trim();
      this.replaceChildren(pill({ ...p, text: p.text ?? this._raw.text }));
    }
  });
}
/** Chip {label, icon?, selected?, avatar?, action?|call?, onDeleted?}: the app's stadium chip. */
define('chip', class extends TElement {
  render() {
    const p = this.props;
    if (this._label == null) this._label = this.textContent.trim();
    this.className = 't-chip';
    if (p.selected) this.dataset.selected = ''; else delete this.dataset.selected;
    const del = p.onDeleted || p.deletable ? h('button', { class: 't-icon-btn', style: { width: '20px', height: '20px', '--t-icon': '16px', marginRight: '-6px' }, 'aria-label': 'Remove', on: { click: (e) => { e.stopPropagation(); this.emit('t-delete', {}); if (p.onDeleted) runAction(this._raw.onDeleted, this); } } }, icon('close')) : null;
    this.replaceChildren(...[p.avatar ? avatar({ name: p.avatar, size: 22 }) : p.icon ? icon(p.icon) : null, asText(p.label ?? this._label), del].filter(Boolean));
    if (p.backgroundColor) this.style.background = color(p.backgroundColor, p.backgroundColor);
    if (actionOf(this) || p.clickable) { this.tabIndex = 0; this.setAttribute('role', 'button'); this.dataset.clickable = ''; gestures(this); }
  }
});
/** MiniTag {text}: a tiny uppercase tag. */
component('mini-tag', (el, p) => { if (el._t == null) el._t = el.textContent; el.textContent = asText(p.text ?? p.label ?? el._t); if (p.color) { el.style.color = color(p.color); el.style.background = `color-mix(in srgb, ${color(p.color)} 14%, transparent)`; } });

function avatar(p) {
  const name = asText(p.name ?? p.label ?? '');
  const size = asDouble(p.size, 36);
  const words = name.trim().split(/\s+/).filter(Boolean);
  const initials = words.slice(0, 2).map((w) => [...w][0].toUpperCase()).join('');
  const hue = color(p.color, series([...name].reduce((a, c) => a + c.charCodeAt(0), 0) % 8));
  const box = h('span', { class: 't-avatar', title: name || null, style: { '--t-size': size + 'px', '--t-c': hue, '--t-ink': onFill(hue) } }, initials || icon('person', size * 0.6));
  const url = p.url ?? p.image ?? p.src;
  if (url) {
    const img = h('img', { src: mediaUrl(url), alt: name, loading: 'lazy' });
    img.onerror = () => { box.replaceChildren(initials || icon('person', size * 0.6)); };
    box.replaceChildren(img);
  }
  return box;
}
Aseman.avatar = avatar;
/** Avatar {name, url?, size?, color?}: initials on a series hue when there is no picture. */
component('avatar', (el, p) => el.replaceChildren(avatar(p)));
/** AvatarGroup {people: [{name, url?}], max?, size?}. */
component('avatar-group', (el, p) => {
  const people = asList(p.people ?? p.data ?? p.items);
  const max = asInt(p.max, 4);
  const size = asDouble(p.size, 32);
  const shown = people.slice(0, max).map((x) => avatar({ ...(isMap(x) ? x : { name: x }), size }));
  if (people.length > max) shown.push(h('span', { class: 't-avatar t-avatars__more', style: { '--t-size': size + 'px' } }, `+${people.length - max}`));
  el.replaceChildren(h('span', { class: 't-avatars', style: { '--t-size': size + 'px' } }, shown));
});

// ---- code, json -------------------------------------------------------------

/** CodeBlock {code, language?, lineNumbers?, maxHeight?, copy?}. */
component('code-block', (el, p) => {
  if (el._src == null) el._src = el.textContent.replace(/^\n/, '');
  const code = asText(p.code ?? p.value ?? el._src);
  const lines = code.split('\n');
  const pre = h('pre', { 'data-lines': p.lineNumbers ? '' : null });
  if (p.maxHeight) pre.style.maxHeight = px(p.maxHeight);
  if (p.lineNumbers) pre.appendChild(h('span', { class: 't-code__ln', html: lines.map((_, i) => i + 1).join('\n') }));
  pre.appendChild(h('code', { html: highlight(code, p.language || '') }));
  const copy = h('button', { class: 't-icon-btn', 'aria-label': 'Copy', title: 'Copy', on: { click: async () => { await navigator.clipboard.writeText(code); toast('Copied'); } } }, icon('content_copy'));
  el.replaceChildren(h('div', { class: 't-code' }, h('div', { class: 't-code__head' }, h('span', null, p.language || 'code'), p.copy === false ? null : copy), pre));
});

function jsonNode(v, depth, open) {
  if (v === null) return h('span', { class: 't-json__null' }, 'null');
  if (typeof v === 'string') return h('span', { class: 't-json__str' }, JSON.stringify(v));
  if (typeof v === 'number') return h('span', { class: 't-json__num' }, String(v));
  if (typeof v === 'boolean') return h('span', { class: 't-json__bool' }, String(v));
  if (typeof v !== 'object') return h('span', null, asText(v));
  const arr = Array.isArray(v);
  const entries = arr ? v.map((x, i) => [i, x]) : Object.entries(v);
  if (!entries.length) return h('span', null, arr ? '[]' : '{}');
  const d = h('details', { open: depth < open });
  d.appendChild(h('summary', null, arr ? `[${entries.length}]` : `{${entries.length}}`));
  const kids = h('div', { class: 't-json__kids' });
  for (const [k, x] of entries) kids.appendChild(h('div', null, arr ? null : h('span', { class: 't-json__key' }, JSON.stringify(String(k))), arr ? null : ': ', jsonNode(x, depth + 1, open)));
  d.appendChild(kids);
  return d;
}
/** JsonView {value, expanded?: levels}. */
component('json-view', (el, p) => {
  let v = p.value ?? p.data;
  if (typeof v === 'string') { try { v = JSON.parse(v); } catch { /* text */ } }
  el.replaceChildren(h('div', { class: 't-json' }, jsonNode(v, 0, p.expanded === true ? 99 : asInt(p.expanded, 2))));
});

// ---- links ------------------------------------------------------------------

/** Link {text, url? | action?}. */
component('link', (el, p) => {
  if (el._t == null) el._t = el.textContent;
  const text = asText(p.text ?? p.label ?? el._t);
  const a = actionOf(el);
  if (p.url && !a) {
    const u = mediaUrl(p.url);
    el.replaceChildren(h('a', { class: 't-link', href: u, target: p.target || (u.startsWith('#') ? '_self' : '_blank'), rel: 'noopener' }, text));
  } else {
    el.replaceChildren(h('button', { class: 't-link', type: 'button', on: { click: () => busy(el, () => runAction(a, el)) } }, text));
  }
});

// ---- states -----------------------------------------------------------------

/** EmptyState {icon?, title, text?}; children (an action) below. */
define('empty-state', class extends TElement {
  render() {
    const p = this.props;
    const kids = this.kids();
    this.replaceChildren(h('div', { class: 't-empty' }, icon(p.icon || 'inbox'), p.title ? h('div', { class: 't-empty__title' }, asText(p.title)) : null,
      p.text ? h('div', { class: 't-empty__text' }, asText(p.text)) : null, kids.length ? h('div', { style: { marginTop: '8px' } }, kids) : null));
  }
});
/** Loading {text?, size?}. */
component('loading', (el, p) => el.replaceChildren(h('div', { class: 't-loading', role: 'status' }, h('span', { class: 't-spinner', style: { '--t-size': px(p.size ?? 24) } }), p.text ? asText(p.text) : null)));
/** Skeleton {variant?: lines|card|chart|table, lines?}. */
component('skeleton', (el, p) => {
  const v = p.variant || 'lines';
  const n = asInt(p.lines, v === 'table' ? 6 : v === 'lines' ? 3 : 3);
  const bars = Array.from({ length: n }, (_, i) => h('div', { class: 't-skel__bar', style: { width: v === 'lines' || i > 0 ? `${[100, 92, 76, 84, 60][i % 5]}%` : '100%' } }));
  el.replaceChildren(h('div', { class: 't-skel', 'data-variant': v, 'aria-busy': 'true' }, bars));
});

// ---- scaffold, app bar -------------------------------------------------------

/** AppBar {title, leading?, elevation?}; children are its actions. */
define('app-bar', class extends TElement {
  render() {
    const p = this.props;
    const kids = this.kids();
    const lead = p.leading === 'back' ? h('button', { class: 't-icon-btn', 'aria-label': 'Back', on: { click: () => history.back() } }, icon('arrow_back'))
      : p.leading ? icon(p.leading) : null;
    this.replaceChildren(...[lead, h('div', { class: 't-app-bar__title' }, asText(p.title ?? '')), ...kids].filter(Boolean));
    if (p.elevation) this.setAttribute('scrolled', '');
  }
});
/** Scaffold {floatingActionButton?: {icon, label?, action}}: a page with an app bar child and a body. */
define('scaffold', class extends TElement {
  render() {
    const p = this.props;
    const kids = this.kids();
    const bar = kids.filter((k) => k.localName === 't-app-bar');
    const body = this._body || (this._body = h('div', { class: 't-scaffold__body' }));
    for (const k of kids) if (!bar.includes(k) && k.parentNode !== body) body.appendChild(k);
    const fab = p.floatingActionButton ?? (p.fab || p.label || p.text ? { icon: p.fab ?? p.icon ?? 'add', label: p.label ?? p.text, action: this._raw.action, tooltip: p.tooltip, mini: p.mini } : null);
    const fabEl = fab ? h('div', { class: 't-scaffold__fab' }, h('button', { class: 't-fab', 'data-mini': fab.mini ? '' : null, title: fab.tooltip || null, disabled: !!p.disabled,
      on: { click: (e) => busy(e.currentTarget, () => runAction(fab.action ?? actionOf(this), this)) } }, icon(fab.icon || 'add'), fab.label ? asText(fab.label) : null)) : null;
    this.replaceChildren(...bar, body, ...(fabEl ? [fabEl] : []));
  }
});
/** Brand {size?}: the Aseman mark. */
component('brand', (el, p) => {
  const s = asDouble(p.size, 28);
  el.style.display = 'inline-flex'; el.style.alignItems = 'center'; el.style.gap = '8px';
  el.innerHTML = `<svg width="${s}" height="${s}" viewBox="0 0 32 32" aria-hidden="true"><defs><linearGradient id="tg" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#8b7bff"/><stop offset="1" stop-color="#58d7ff"/></linearGradient></defs><rect width="32" height="32" rx="10" fill="url(#tg)"/><path d="M9 21l5-6 4 3 5-7" stroke="#fff" stroke-width="2.6" fill="none" stroke-linecap="round" stroke-linejoin="round"/></svg>${p.label === false ? '' : `<b style="font-weight:900;font-size:${s * 0.62}px;letter-spacing:-.3px">${esc(p.label ?? 'Aseman')}</b>`}`;
});

// ---- math, canvas --------------------------------------------------------------

/** MathExpression {expression|latex|text}: a formula (powers, indices, fractions, Greek letters, roots). */
component('math-expression', (el, p) => {
  let s = esc(p.expression ?? p.latex ?? p.text ?? p.data ?? el._t ?? (el._t = el.textContent));
  const greek = { alpha: 'α', beta: 'β', gamma: 'γ', delta: 'δ', epsilon: 'ε', theta: 'θ', lambda: 'λ', mu: 'μ', pi: 'π', sigma: 'σ', tau: 'τ', phi: 'φ', omega: 'ω', Delta: 'Δ', Sigma: 'Σ', Omega: 'Ω', infty: '∞', times: '×', cdot: '·', pm: '±', leq: '≤', geq: '≥', neq: '≠', approx: '≈', sum: '∑', int: '∫', partial: '∂', to: '→' };
  for (let k = 0; k < 3; k++) s = s.replace(/\\frac\{([^{}]*)\}\{([^{}]*)\}/g, '<span class="t-frac"><span>$1</span><span>$2</span></span>');
  s = s.replace(/\\sqrt\{([^{}]*)\}/g, '√<span style="border-top:1px solid currentColor">$1</span>')
    .replace(/\\([a-zA-Z]+)/g, (m, g) => greek[g] ?? m)
    .replace(/\^\{([^{}]*)\}|\^(\w)/g, (_, a, b) => `<sup>${a ?? b}</sup>`)
    .replace(/_\{([^{}]*)\}|_(\w)/g, (_, a, b) => `<sub>${a ?? b}</sub>`)
    .replace(/\*/g, '·').replace(/[{}]/g, '');
  el.innerHTML = `<span class="t-math">${s}</span>`;
});

/**
 * Canvas {width, height, commands: [{type|op, …}], backgroundColor?}: the
 * Elpian canvas commands (fillRect, strokeRect, arc, lineTo, fillText, …)
 * drawn on a 2D canvas; CachedCanvas keeps its picture between renders.
 */
function drawCommands(ctx, cmds) {
  for (const c of asList(cmds)) {
    if (!isMap(c)) continue;
    const op = c.type ?? c.op ?? c.command;
    const a = asList(c.args);
    const fill = c.fillStyle ?? c.color ?? c.fill;
    if (fill) ctx.fillStyle = color(fill, fill);
    if (c.strokeStyle ?? c.stroke) ctx.strokeStyle = color(c.strokeStyle ?? c.stroke, c.strokeStyle ?? c.stroke);
    if (c.lineWidth != null) ctx.lineWidth = c.lineWidth;
    if (c.font) ctx.font = c.font;
    if (c.globalAlpha != null) ctx.globalAlpha = c.globalAlpha;
    const n = (k, i) => asDouble(c[k] ?? a[i], 0);
    switch (op) {
      case 'clearRect': ctx.clearRect(n('x', 0), n('y', 1), n('width', 2), n('height', 3)); break;
      case 'fillRect': ctx.fillRect(n('x', 0), n('y', 1), n('width', 2), n('height', 3)); break;
      case 'strokeRect': ctx.strokeRect(n('x', 0), n('y', 1), n('width', 2), n('height', 3)); break;
      case 'beginPath': ctx.beginPath(); break;
      case 'closePath': ctx.closePath(); break;
      case 'moveTo': ctx.moveTo(n('x', 0), n('y', 1)); break;
      case 'lineTo': ctx.lineTo(n('x', 0), n('y', 1)); break;
      case 'arc': ctx.arc(n('x', 0), n('y', 1), n('radius', 2), asDouble(c.startAngle ?? a[3], 0), asDouble(c.endAngle ?? a[4], Math.PI * 2)); break;
      case 'circle': ctx.beginPath(); ctx.arc(n('x', 0), n('y', 1), n('radius', 2), 0, Math.PI * 2); fill ? ctx.fill() : ctx.stroke(); break;
      case 'quadraticCurveTo': ctx.quadraticCurveTo(n('cpx', 0), n('cpy', 1), n('x', 2), n('y', 3)); break;
      case 'bezierCurveTo': ctx.bezierCurveTo(n('cp1x', 0), n('cp1y', 1), n('cp2x', 2), n('cp2y', 3), n('x', 4), n('y', 5)); break;
      case 'rect': ctx.rect(n('x', 0), n('y', 1), n('width', 2), n('height', 3)); break;
      case 'roundRect': ctx.beginPath(); ctx.roundRect(n('x', 0), n('y', 1), n('width', 2), n('height', 3), n('radius', 4)); fill ? ctx.fill() : ctx.stroke(); break;
      case 'fill': ctx.fill(); break;
      case 'stroke': ctx.stroke(); break;
      case 'fillText': ctx.fillText(asText(c.text ?? a[0]), n('x', 1), n('y', 2)); break;
      case 'strokeText': ctx.strokeText(asText(c.text ?? a[0]), n('x', 1), n('y', 2)); break;
      case 'save': ctx.save(); break;
      case 'restore': ctx.restore(); break;
      case 'translate': ctx.translate(n('x', 0), n('y', 1)); break;
      case 'rotate': ctx.rotate(n('angle', 0)); break;
      case 'scale': ctx.scale(n('x', 0), asDouble(c.y ?? a[1], n('x', 0))); break;
      case 'setLineDash': ctx.setLineDash(asList(c.segments ?? a[0])); break;
      case 'drawImage': { const img = new Image(); img.onload = () => ctx.drawImage(img, n('x', 1), n('y', 2), ...(c.width ? [c.width, c.height] : [])); img.src = mediaUrl(c.src ?? c.url ?? a[0]); break; }
      default: if (typeof ctx[op] === 'function') ctx[op](...a);
    }
  }
}
for (const n of ['canvas', 'canvas-widget', 'cached-canvas']) {
  component(n, (el, p) => {
    const w = asDouble(p.width, 300), hh = asDouble(p.height, 150);
    const key = JSON.stringify([w, hh, p.commands, p.backgroundColor, isDark()]);
    if (n === 'cached-canvas' && el._key === key) return;
    el._key = key;
    const dpr = window.devicePixelRatio || 1;
    const cv = el._cv || (el._cv = h('canvas'));
    cv.width = w * dpr; cv.height = hh * dpr; cv.style.width = w + 'px'; cv.style.height = hh + 'px';
    const ctx = cv.getContext('2d');
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.clearRect(0, 0, w, hh);
    if (p.backgroundColor) { ctx.fillStyle = color(p.backgroundColor, p.backgroundColor); ctx.fillRect(0, 0, w, hh); }
    ctx.fillStyle = getComputedStyle(el).color; ctx.strokeStyle = ctx.fillStyle;
    ctx.font = '13px ' + getComputedStyle(document.body).fontFamily;
    drawCommands(ctx, p.commands);
    if (cv.parentNode !== el) el.replaceChildren(cv);
    el._ctx = ctx;
  }, { get context() { return this._ctx; } });
}
