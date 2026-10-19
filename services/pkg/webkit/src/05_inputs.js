// ---------------------------------------------------------------------------
// Inputs: Button, IconButton, TextField, CheckBox, Switch, Radio, Slider,
// RangeSlider, ChoicePicker, DateTimeInput, Dropdown, SearchField,
// NumberStepper, SegmentedControl, SegmentedTabBar, Form. Values are bound
// two-way ({"path": "/form/x"} or bind-value="/form/x"); an input's action
// (or call="tool/microtool") runs after a change, its context getting {value}.
// ---------------------------------------------------------------------------

let fieldSeq = 0;
const fid = () => `t-f${++fieldSeq}`;

/** The first failing check's message ({condition|call+args, message}), or null. */
function failingCheck(el) {
  const checks = el._raw.checks;
  if (!Array.isArray(checks)) return null;
  const scope = scopeOf(el);
  for (const c of checks) {
    if (!isMap(c)) continue;
    const cond = c.condition ?? (c.call ? { call: c.call, args: c.args } : null);
    if (cond == null) continue;
    if (!asBool(resolve(cond, scope))) return asText(resolve(c.message, scope) ?? 'Check the form');
  }
  return null;
}

/** Runs an input's action after a change, with {value} in its context. */
function changed(el, value) {
  el.dispatchEvent(new Event('change', { bubbles: true }));
  el.emit('t-input', { value });
  const a = actionOf(el);
  if (!a) return;
  clearTimeout(el._actTimer);
  const run = () => busy(el, () => runAction(isMap(a) && a.call && !a.args ? { ...a, args: { value } } : a, el, { value }));
  // Text-like inputs wait until typing pauses.
  if (el._debounce) el._actTimer = setTimeout(run, el._debounce); else run();
}

function fieldWrap(el, p, control, opts = {}) {
  const id = el._fid || (el._fid = fid());
  control.id ||= id;
  const err = el._error;
  const wrap = h('div', { class: 't-field' + (err ? ' t-invalid' : '') },
    p.label != null && opts.label !== false ? h('label', { class: 't-field__label', for: control.id }, asText(p.label)) : null,
    opts.box === false ? control : h('div', { class: 't-field__box' }, opts.prefix || null, control, opts.suffix || null),
    err ? h('div', { class: 't-field__error', role: 'alert' }, err) : p.helper || p.helperText ? h('div', { class: 't-field__helper' }, asText(p.helper ?? p.helperText)) : null);
  return wrap;
}

// ---- buttons ----------------------------------------------------------------

/**
 * Button {text|label|child, variant?: primary|default|borderless|tonal|
 * destructive|elevated, icon?, action? | call="tool/microtool" args into,
 * fullWidth?, disabled?, checks?, size?}. While its action runs it shows a
 * spinner; a failure is shown as a toast.
 */
define('button', class extends TElement {
  render() {
    const p = this.props;
    const kids = this.kids();
    const failure = failingCheck(this);
    const variant = p.variant || (this.getAttribute('type') === 'submit' ? 'primary' : 'default');
    const btn = this._btn || (this._btn = h('button', { class: 't-btn', type: this.getAttribute('type') === 'submit' ? 'submit' : 'button' }));
    btn.dataset.variant = variant;
    if (p.size) btn.dataset.size = p.size;
    btn.disabled = !!p.disabled || !!failure;
    btn.title = failure || p.tooltip || '';
    const label = p.text ?? p.label;
    btn.replaceChildren(...[p.icon ? icon(p.icon) : null, ...(label != null ? [asText(label)] : kids)].filter((x) => x != null));
    if (!btn.isConnected) this.appendChild(btn);
    if (p.fullWidth) this.setAttribute('full-width', '');
    if (p.color) { btn.style.background = color(p.color, p.color); btn.style.color = onFill(color(p.color, p.color)); btn.style.borderColor = 'transparent'; }
    if (isMap(p.style)) applyStyle(btn, p.style);
    if (!this._wired) {
      this._wired = true;
      btn.addEventListener('click', (e) => {
        if (btn.type === 'submit') return; // the form submits
        e.preventDefault();
        const a = actionOf(this);
        this.emit('t-press', {});
        if (a) busy(btn, () => runAction(a, this));
      });
    }
    commonStyle(this);
  }
  get button() { return this._btn; }
});

/** IconButton {icon, tooltip, action, variant?: standard|filled|tonal|outlined, selected?, size?}. */
define('icon-button', class extends TElement {
  render() {
    const p = this.props;
    const btn = this._btn || (this._btn = h('button', { class: 't-icon-btn', type: 'button' }));
    btn.dataset.variant = p.variant || 'standard';
    if (p.selected) btn.dataset.selected = ''; else delete btn.dataset.selected;
    btn.disabled = !!p.disabled || !!failingCheck(this);
    btn.setAttribute('aria-label', asText(p.tooltip ?? p.label ?? p.icon));
    btn.replaceChildren(icon(p.selected && p.selectedIcon ? p.selectedIcon : p.icon ?? 'more_horiz'));
    if (p.size) { btn.style.width = btn.style.height = px(p.size); btn.style.setProperty('--t-icon', px(asDouble(p.size, 40) * 0.55)); }
    if (p.color) btn.style.color = color(p.color, p.color);
    if (!btn.isConnected) {
      this.appendChild(btn);
      btn.addEventListener('click', () => { const a = actionOf(this); this.emit('t-press', {}); if (a) busy(btn, () => runAction(a, this)); });
      if (p.tooltip) attachTooltip(btn, () => asText(this.p('tooltip')));
    }
  }
});

// ---- text fields ---------------------------------------------------------------

/**
 * TextField {label, value: {"path"}, variant?: shortText|longText|number|
 * obscured, placeholder?, helper?, prefixIcon?, checks?, action?}; Elpian
 * TextField {hint, multiline, maxLines, keyboardType, obscureText, min, max}.
 */
define('text-field', class extends TElement {
  init() { this._debounce = 450; }
  render() {
    const p = this.props;
    const variant = p.variant || (p.multiline || asInt(p.maxLines, 1) > 1 ? 'longText' : p.obscureText ? 'obscured' : p.keyboardType === 'number' ? 'number' : 'shortText');
    const long = variant === 'longText';
    const input = this._in && this._in.localName === (long ? 'textarea' : 'input') ? this._in : (this._in = h(long ? 'textarea' : 'input'));
    if (!long) input.type = variant === 'obscured' ? (this._shown ? 'text' : 'password') : variant === 'number' ? 'number' : p.type || 'text';
    if (long) input.rows = asInt(p.maxLines, 4);
    input.placeholder = asText(p.placeholder ?? p.hint ?? '');
    input.disabled = !!p.disabled;
    input.name = p.name || '';
    if (p.min != null) input.min = p.min;
    if (p.max != null) input.max = p.max;
    if (p.step != null) input.step = p.step;
    if (p.maxLength) input.maxLength = p.maxLength;
    if (p.autocomplete) input.autocomplete = p.autocomplete;
    const v = p.value;
    const text = v == null ? '' : asText(v);
    if (document.activeElement !== input && input.value !== text) input.value = text;
    if (!this._wired) {
      this._wired = true;
      input.addEventListener('input', () => {
        const val = variant === 'number' ? (input.value === '' ? null : asNum(input.value)) : input.value;
        this._touched = true;
        this._error = null;
        this.write('value', val);
        changed(this, val);
      });
      input.addEventListener('blur', () => { if (this._touched) { this._error = failingCheck(this); this.update(); } });
      input.addEventListener('keydown', (e) => {
        if (e.key === 'Enter' && !long) { const a = actionOf(this, 'onSubmit') ?? (this._raw.submit ? actionOf(this) : null); if (a) { e.preventDefault(); busy(this, () => runAction(a, this, { value: input.value })); } }
      });
    }
    const prefix = p.prefixIcon || p.icon ? h('span', { class: 't-field__prefix' }, icon(p.prefixIcon || p.icon)) : null;
    // Rebuilt only when its frame changes: moving the input would drop focus.
    const key = JSON.stringify([p.label, p.helper, p.helperText, this._error, variant, p.prefixIcon || p.icon, this._shown]);
    if (key === this._key && input.isConnected) return;
    this._key = key;
    const suffix = variant === 'obscured' ? h('span', { class: 't-field__suffix' }, h('button', { class: 't-icon-btn', type: 'button', 'aria-label': this._shown ? 'Hide' : 'Show',
      on: { click: () => { this._shown = !this._shown; this.update(); } } }, icon(this._shown ? 'visibility_off' : 'visibility'))) : null;
    this.replaceChildren(fieldWrap(this, p, input, { prefix, suffix }));
  }
  get value() { return this._in ? this._in.value : this.p('value'); }
  set value(v) { this.write('value', v); }
  focus() { this._in?.focus(); }
});

/** SearchField {value: {"path"}, placeholder?, action?}: a pill search box; its action runs as you type (debounced) and on Enter. */
define('search-field', class extends TElement {
  init() { this._debounce = 350; }
  render() {
    const p = this.props;
    const input = this._in || (this._in = h('input', { type: 'search', 'aria-label': asText(p.label ?? p.placeholder ?? 'Search') }));
    input.placeholder = asText(p.placeholder ?? 'Search');
    const text = asText(p.value ?? '');
    if (document.activeElement !== input && input.value !== text) input.value = text;
    if (!this._wired) {
      this._wired = true;
      input.addEventListener('input', () => { this.write('value', input.value); changed(this, input.value); });
      input.addEventListener('keydown', (e) => { if (e.key === 'Enter') { clearTimeout(this._actTimer); const a = actionOf(this); if (a) busy(this, () => runAction(a, this, { value: input.value })); } });
    }
    const key = JSON.stringify([p.label, p.helper]);
    if (key === this._key && input.isConnected) return;
    this._key = key;
    const w = fieldWrap(this, p, input, { prefix: h('span', { class: 't-field__prefix' }, icon('search')) });
    w.classList.add('t-search');
    this.replaceChildren(w);
  }
  get value() { return this._in?.value ?? ''; }
});

// ---- toggles -------------------------------------------------------------------

/** CheckBox {label, value: {"path"}, action?, tristate?}; Elpian Checkbox {value}. */
define('checkbox', class extends TElement {
  render() {
    const p = this.props;
    const input = this._in || (this._in = h('input', { type: 'checkbox' }));
    input.checked = asBool(p.value ?? p.checked);
    input.indeterminate = p.value == null && !!p.tristate;
    input.disabled = !!p.disabled;
    if (!this._wired) { this._wired = true; input.addEventListener('change', () => { this.write('value', input.checked); changed(this, input.checked); }); }
    this.replaceChildren(h('label', { class: 't-check' }, input, p.label != null ? h('span', null, asText(p.label)) : null));
  }
  get value() { return this._in?.checked; }
});
define('check-box', class extends (customElements.get('t-checkbox')) {});
/** Switch {label, value: {"path"}, action?}: the Material 3 switch. */
define('switch', class extends TElement {
  render() {
    const p = this.props;
    const input = this._in || (this._in = h('input', { type: 'checkbox', role: 'switch' }));
    input.checked = asBool(p.value ?? p.checked);
    input.disabled = !!p.disabled;
    if (!this._wired) { this._wired = true; input.addEventListener('change', () => { this.write('value', input.checked); changed(this, input.checked); }); }
    this.replaceChildren(h('label', { class: 't-switch' }, input, h('span', { class: 't-switch__track' }, h('span', { class: 't-switch__thumb' })), p.label != null ? h('span', null, asText(p.label)) : null));
  }
  get value() { return this._in?.checked; }
});
/** Radio {value, groupValue: {"path"}, label?}: selected when groupValue equals value. */
define('radio', class extends TElement {
  render() {
    const p = this.props;
    const input = this._in || (this._in = h('input', { type: 'radio' }));
    input.name = asText(p.name ?? JSON.stringify(this._raw.groupValue ?? ''));
    input.checked = JSON.stringify(p.groupValue) === JSON.stringify(p.value) && p.value !== undefined;
    input.disabled = !!p.disabled;
    if (!this._wired) { this._wired = true; input.addEventListener('change', () => { if (input.checked) { this.write('groupValue', this.p('value')); changed(this, this.p('value')); } }); }
    this.replaceChildren(h('label', { class: 't-radio' }, input, p.label != null ? h('span', null, asText(p.label)) : null));
  }
});

// ---- sliders --------------------------------------------------------------------

/** Slider {label?, value: {"path"}, min, max, step?, format?, action?}. */
define('slider', class extends TElement {
  init() { this._debounce = 250; }
  render() {
    const p = this.props;
    const min = asDouble(p.min, 0), max = asDouble(p.max, 100);
    const v = asDouble(p.value, min);
    const input = this._in || (this._in = h('input', { type: 'range', class: 't-range-input' }));
    input.min = min; input.max = max; input.step = p.step ?? (max - min <= 1 ? 0.01 : p.divisions ? (max - min) / p.divisions : 1);
    input.disabled = !!p.disabled;
    if (document.activeElement !== input) input.value = v;
    const fillPct = () => input.style.setProperty('--t-fill', `${((asDouble(input.value, min) - min) / (max - min || 1)) * 100}%`);
    fillPct();
    const shown = this.querySelector('.t-slider__value');
    const key = JSON.stringify([p.label, p.showValue, min, max]);
    if (key === this._key && input.isConnected) { if (shown && document.activeElement !== input) shown.textContent = formatValue(v, p.format); return; }
    this._key = key;
    const out = h('span', { class: 't-slider__value' }, formatValue(v, p.format));
    if (!this._wired) {
      this._wired = true;
      input.addEventListener('input', () => { fillPct(); const n = asNum(input.value); this.querySelector('.t-slider__value').textContent = formatValue(n, this.p('format')); this.write('value', n); changed(this, n); });
    }
    input.setAttribute('aria-label', asText(p.label ?? 'Value'));
    this.replaceChildren(h('div', { class: 't-slider' }, h('div', { class: 't-slider__head' }, h('span', { class: 't-field__label' }, asText(p.label ?? '')), p.showValue === false ? null : out), input));
  }
});
/** RangeSlider {label?, value: {"path"} → [low, high], min, max, step?, format?, action?}. */
define('range-slider', class extends TElement {
  init() { this._debounce = 250; }
  render() {
    const p = this.props;
    const min = asDouble(p.min, 0), max = asDouble(p.max, 100);
    const [lo0, hi0] = asList(p.value ?? [min, max]);
    let lo = asDouble(lo0, min), hi = asDouble(hi0, max);
    const step = p.step ?? (max - min <= 1 ? 0.01 : 1);
    const key = JSON.stringify([p.label, p.format, min, max, step]);
    if (key === this._key && this._paint) { if (!this.contains(document.activeElement)) this._paint(lo, hi); return; }
    this._key = key;
    const a = h('input', { type: 'range', min, max, step, value: lo, 'aria-label': 'Minimum' });
    const b = h('input', { type: 'range', min, max, step, value: hi, 'aria-label': 'Maximum' });
    const fill = h('div', { class: 't-range2__fill' });
    const head = h('span', { class: 't-slider__value' });
    const paint = () => {
      const pa = ((lo - min) / (max - min || 1)) * 100, pb = ((hi - min) / (max - min || 1)) * 100;
      fill.style.left = pa + '%'; fill.style.width = pb - pa + '%';
      head.textContent = `${formatValue(lo, p.format)} – ${formatValue(hi, p.format)}`;
    };
    this._paint = (l, hh) => { lo = l; hi = hh; a.value = l; b.value = hh; paint(); };
    const set = () => { lo = Math.min(asDouble(a.value, min), asDouble(b.value, max)); hi = Math.max(asDouble(a.value, min), asDouble(b.value, max)); paint(); this.write('value', [lo, hi]); changed(this, [lo, hi]); };
    a.oninput = b.oninput = set;
    paint();
    this.replaceChildren(h('div', { class: 't-slider' }, h('div', { class: 't-slider__head' }, h('span', { class: 't-field__label' }, asText(p.label ?? '')), head),
      h('div', { class: 't-range2' }, h('div', { class: 't-range2__track' }), fill, a, b)));
  }
});

// ---- choices -----------------------------------------------------------------------

const optionsOf = (p) => asList(p.options ?? p.items ?? p.choices).map((o) => (isMap(o) ? { label: asText(o.label ?? o.title ?? o.value), value: o.value ?? o.label, icon: o.icon, description: o.description } : { label: asText(o), value: o }));
const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);

/** ChoicePicker {label, options: [{label, value}], value: {"path"}, variant?: mutuallyExclusive|multipleSelection}: chips. */
define('choice-picker', class extends TElement {
  render() {
    const p = this.props;
    const multiple = p.variant === 'multipleSelection' || p.multiple === true;
    const cur = p.value;
    const selected = (v) => (multiple ? asList(cur).some((x) => same(x, v)) : same(cur, v) || (Array.isArray(cur) && cur.length === 1 && same(cur[0], v)));
    const chips = optionsOf(p).map((o) => h('button', { class: 't-choice', type: 'button', 'aria-pressed': String(selected(o.value)),
      on: { click: () => {
        let next;
        if (multiple) { const l = asList(this.p('value')); next = selected(o.value) ? l.filter((x) => !same(x, o.value)) : [...l, o.value]; }
        else next = Array.isArray(this._raw.value) || (isMap(this._raw.value) && Array.isArray(this.p('value'))) ? [o.value] : o.value;
        this.write('value', next); changed(this, next);
      } } }, o.icon ? icon(o.icon, 18) : null, o.label));
    this.replaceChildren(fieldWrap(this, p, h('div', { class: 't-choices', role: multiple ? 'group' : 'radiogroup' }, chips), { box: false }));
  }
});
/** SegmentedControl {options: [{label, value, icon?}], value: {"path"}, multiple?, fullWidth?}: Material segmented buttons. */
define('segmented-control', class extends TElement {
  render() {
    const p = this.props;
    const multiple = !!p.multiple;
    const cur = p.value;
    const opts = optionsOf(p);
    const on = (v) => (multiple ? asList(cur).some((x) => same(x, v)) : same(cur, v));
    const seg = h('div', { class: 't-segmented', role: 'group', 'aria-label': asText(p.label ?? '') },
      opts.map((o) => h('button', { type: 'button', 'aria-pressed': String(on(o.value)), 'data-icon': o.icon ? '' : null,
        on: { click: () => {
          const next = multiple ? (on(o.value) ? asList(this.p('value')).filter((x) => !same(x, o.value)) : [...asList(this.p('value')), o.value]) : o.value;
          this.write('value', next); changed(this, next);
        } } }, o.icon ? icon(o.icon) : null, o.label)));
    this.replaceChildren(p.label ? fieldWrap(this, p, seg, { box: false }) : seg);
  }
});
/** SegmentedTabBar {tabs: [{label, value, icon?}], value: {"path"}}: the app's pill tab bar. */
define('segmented-tab-bar', class extends TElement {
  render() {
    const p = this.props;
    const opts = optionsOf({ options: p.tabs ?? p.options });
    const cur = p.value ?? opts[0]?.value;
    this.replaceChildren(h('div', { class: 't-tabbar', role: 'tablist' }, opts.map((o) => h('button', { type: 'button', role: 'tab', 'aria-selected': String(same(cur, o.value)),
      on: { click: () => { this.write('value', o.value); changed(this, o.value); } } }, o.icon ? icon(o.icon) : null, o.label))));
  }
});
/** Dropdown {label, options: [{label, value}], value: {"path"}, placeholder?, action?}. */
define('dropdown', class extends TElement {
  render() {
    const p = this.props;
    const sel = this._sel || (this._sel = h('select'));
    const opts = optionsOf(p);
    sel.replaceChildren(...(p.placeholder || p.value == null ? [h('option', { value: '', disabled: true, selected: p.value == null }, asText(p.placeholder ?? 'Select…'))] : []),
      ...opts.map((o, i) => h('option', { value: String(i), selected: same(p.value, o.value) }, o.label)));
    sel.disabled = !!p.disabled;
    if (!this._wired) { this._wired = true; sel.addEventListener('change', () => { const o = optionsOf(this.props)[Number(sel.value)]; if (!o) return; this.write('value', o.value); changed(this, o.value); }); }
    this.replaceChildren(fieldWrap(this, p, sel));
  }
});
/** NumberStepper {label?, value: {"path"}, min?, max?, step?, format?, action?}. */
define('number-stepper', class extends TElement {
  init() { this._debounce = 300; }
  render() {
    const p = this.props;
    const step = asDouble(p.step, 1);
    const min = p.min == null ? -Infinity : asDouble(p.min, 0), max = p.max == null ? Infinity : asDouble(p.max, 0);
    const v = asDouble(p.value, Number.isFinite(min) ? min : 0);
    const set = (n) => { n = Math.max(min, Math.min(max, Number((n).toFixed(8)))); this.write('value', n); changed(this, n); };
    const input = h('input', { type: 'number', value: v, step, 'aria-label': asText(p.label ?? 'Quantity'), on: { change: (e) => set(asDouble(e.target.value, v)) } });
    const box = h('div', { class: 't-stepper' },
      h('button', { class: 't-icon-btn', type: 'button', 'aria-label': 'Decrease', disabled: v - step < min, on: { click: () => set(v - step) } }, icon('remove')),
      input,
      h('button', { class: 't-icon-btn', type: 'button', 'aria-label': 'Increase', disabled: v + step > max, on: { click: () => set(v + step) } }, icon('add')));
    this.replaceChildren(p.label ? fieldWrap(this, p, box, { box: false }) : box);
  }
});
/** DateTimeInput {label?, value: {"path"} (ISO), enableDate?, enableTime?, min?, max?}. */
define('date-time-input', class extends TElement {
  render() {
    const p = this.props;
    const date = p.enableDate !== false, time = !!p.enableTime;
    const type = date && time ? 'datetime-local' : time ? 'time' : 'date';
    const input = this._in && this._in.type === type ? this._in : (this._in = h('input', { type }));
    const d = asDate(p.value);
    const two = (x) => String(x).padStart(2, '0');
    const local = d ? (type === 'time' ? `${two(d.getHours())}:${two(d.getMinutes())}` : `${d.getFullYear()}-${two(d.getMonth() + 1)}-${two(d.getDate())}${type === 'datetime-local' ? `T${two(d.getHours())}:${two(d.getMinutes())}` : ''}`)
      : typeof p.value === 'string' && type === 'time' ? p.value : '';
    if (document.activeElement !== input) input.value = local;
    if (p.min) input.min = p.min;
    if (p.max) input.max = p.max;
    if (!this._wired) {
      this._wired = true;
      input.addEventListener('change', () => {
        let out = input.value;
        if (out && type === 'datetime-local') out = new Date(out).toISOString();
        this.write('value', out || null); changed(this, out || null);
      });
    }
    this.replaceChildren(fieldWrap(this, p, input));
  }
});

/**
 * Form {action | call="tool/microtool" into=…, into?}: submits its fields.
 * Native inputs with a name, and t-* inputs with a name, become the args:
 *   <t-form call="Orders/place" into="/order"> … <t-button type="submit" text="Place"> </t-form>
 */
define('form', class extends TElement {
  render() {
    if (this._form) return;
    const kids = this.kids();
    const form = (this._form = h('form', { class: 't-column', novalidate: true }));
    append(form, kids);
    form.addEventListener('submit', (e) => {
      e.preventDefault();
      const args = {};
      for (const f of form.querySelectorAll('[name]')) {
        const name = f.getAttribute('name');
        if (f instanceof TElement) args[name] = f.value ?? f.p('value');
        else if (f.type === 'checkbox') args[name] = f.checked;
        else if (f.type === 'radio') { if (f.checked) args[name] = f.value; }
        else if (f.type === 'number' || f.type === 'range') args[name] = asNum(f.value);
        else if (f.localName !== 'button') args[name] = f.value;
      }
      const failing = [...form.querySelectorAll('t-text-field')].map((f) => { f._touched = true; f._error = failingCheck(f); f.update(); return f._error; }).find(Boolean);
      if (failing) return;
      const submit = form.querySelector('t-button[type=submit] .t-btn, button[type=submit]') || form;
      let a = actionOf(this);
      if (isMap(a) && a.call) a = { ...a, args: { ...resolve(asMap(a.args), scopeOf(this)), ...args } };
      this.emit('t-submit', { values: args });
      if (a) busy(submit, () => runAction(a, this, { values: args, ...args }).then((r) => { if (this.hasAttribute('reset')) form.reset(); return r; }));
    });
    this.replaceChildren(form);
  }
});
/** FormField {label, helper?}: a label and helper around its own control. */
define('form-field', class extends TElement {
  render() {
    const p = this.props;
    const kids = this.kids();
    this.replaceChildren(h('div', { class: 't-field' }, p.label ? h('span', { class: 't-field__label' }, asText(p.label)) : null, ...kids, p.helper ? h('span', { class: 't-field__helper' }, asText(p.helper)) : null));
  }
});
