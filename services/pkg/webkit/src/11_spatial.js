// ---------------------------------------------------------------------------
// Extra Surface Spec elements: chrome, chat, 2D/3D — rich enough for agent
// web consoles; professional pages still prefer charts/tables from the kit.
// ---------------------------------------------------------------------------

component('app-bar', (e, p) => {
  e.className = 't-app-bar';
  e.replaceChildren(
    el('row', { justify: 'spaceBetween', align: 'center' },
      el('column', { gap: 2 },
        el('text', { text: p.title ?? '', variant: 'h4' }),
        p.subtitle ? el('text', { text: p.subtitle, variant: 'caption' }) : null),
    ),
  );
});
component('navigation-rail', (e, p) => {
  const dests = asList(p.destinations);
  e.replaceChildren(...dests.map((d) => el('button', { text: asText(d.label), icon: d.icon, variant: 'borderless', fullWidth: true })));
});
component('drawer', (e) => { e.className = 't-drawer'; });
component('bottom-nav', (e, p) => {
  e.className = 't-bottom-nav';
  e.replaceChildren(...asList(p.destinations).map((d) => el('button', { text: asText(d.label), icon: d.icon, variant: 'borderless' })));
});
component('breadcrumb', (e, p) => {
  e.replaceChildren(...asList(p.items).flatMap((it, i) => i ? [document.createTextNode(' / '), el('link', { text: asText(it.label) })] : [el('link', { text: asText(it.label) })]));
});
component('command-palette', (e, p) => {
  e.replaceChildren(el('search-field', { placeholder: p.placeholder ?? 'Search…' }),
    ...asList(p.items).map((it) => el('button', { text: asText(it.label), icon: it.icon, variant: 'borderless', fullWidth: true })));
});
component('fab', (e, p) => el('icon-button', { icon: p.icon ?? 'add', variant: 'filled' }));
component('sidebar', (e) => { e.className = 't-sidebar'; e.style.minWidth = '200px'; });
component('form-field', (e, p) => {
  e.replaceChildren(p.label ? el('text', { text: asText(p.label), variant: 'caption' }) : null);
});
component('autocomplete', (e, p) => el('text-field', { label: p.label, value: p.value }));
component('chip-input', (e, p) => {
  e.replaceChildren(...asList(p.value).map((v) => el('chip', { text: asText(v) })));
});
component('tag-input', (e, p) => {
  e.replaceChildren(...asList(p.value).map((v) => el('chip', { text: asText(v) })));
});
component('color-picker', (e, p) => {
  const sw = asList(p.swatches).length ? asList(p.swatches) : ['#2563EB', '#F59E0B', '#10B981', '#EF4444'];
  e.replaceChildren(...sw.map((c) => h('span', { style: { display: 'inline-block', width: '24px', height: '24px', borderRadius: '50%', background: asText(c), marginRight: '6px' } })));
});
component('file-picker', (e, p) => el('button', { text: p.label ?? 'Choose file', icon: 'attach_file', variant: 'tonal' }));
component('code-editor', (e, p) => {
  const ta = h('textarea', { class: 't-code-editor', style: { width: '100%', minHeight: '120px', fontFamily: 'monospace' } });
  ta.value = asText(p.value);
  e.replaceChildren(ta);
});
component('rich-text-editor', (e, p) => el('text-field', { label: p.label, value: p.value, variant: 'longText' }));
component('canvas', (e, p) => {
  e.style.height = px(p.height ?? 200);
  e.style.background = 'var(--t-surface-variant, #eee)';
  e.style.borderRadius = '8px';
});
component('drawing-pad', (e, p) => { e.style.height = px(p.height ?? 220); e.style.border = '1px dashed var(--t-outline, #ccc)'; });
component('map2-d', (e, p) => {
  e.style.height = px(p.height ?? 220);
  e.style.background = 'var(--t-surface-variant, #e8eef5)';
  e.style.borderRadius = '8px';
  e.replaceChildren(...asList(p.markers).map((m) => el('badge', { text: asText(m.label ?? '•') })));
});
component('annotation-layer', (e) => { e.style.position = 'relative'; });
component('pdfviewer', (e, p) => {
  e.style.height = px(p.height ?? 320);
  e.replaceChildren(el('callout', { title: 'PDF', text: asText(p.url), severity: 'info' }));
});
/** 3D scene (Three.js when available; otherwise a rich placeholder). */
define('scene3-d', class extends TElement {
  render() {
    const p = this.props;
    this.style.height = px(p.height ?? 280);
    this.style.position = 'relative';
    this.style.borderRadius = '12px';
    this.style.overflow = 'hidden';
    this.style.background = 'linear-gradient(135deg, var(--t-surface-variant, #1e293b), var(--t-surface, #0f172a))';
    if (window.THREE && p.src) {
      this._bootThree(p);
      return;
    }
    this.replaceChildren(
      h('div', { style: { display: 'flex', height: '100%', alignItems: 'center', justifyContent: 'center', flexDirection: 'column', color: 'var(--t-on-surface, #fff)', gap: '8px' } },
        el('icon', { name: 'view_in_ar' }),
        el('text', { text: 'Scene3D', variant: 'h5' }),
        p.src ? el('text', { text: asText(p.src), variant: 'caption' }) : null,
      ),
    );
  }
  _bootThree(p) {
    if (this._three) return;
    const canvas = h('canvas', { style: { width: '100%', height: '100%' } });
    this.replaceChildren(canvas);
    const renderer = new THREE.WebGLRenderer({ canvas, antialias: true });
    const scene = new THREE.Scene();
    const camera = new THREE.PerspectiveCamera(50, 1, 0.1, 100);
    camera.position.z = 3;
    const light = new THREE.DirectionalLight(0xffffff, 1);
    light.position.set(2, 2, 3);
    scene.add(light, new THREE.AmbientLight(0xffffff, 0.4));
    const mesh = new THREE.Mesh(new THREE.BoxGeometry(1, 1, 1), new THREE.MeshStandardMaterial({ color: 0x2563eb }));
    scene.add(mesh);
    const resize = () => {
      const w = this.clientWidth || 300, h = this.clientHeight || 280;
      renderer.setSize(w, h, false);
      camera.aspect = w / h; camera.updateProjectionMatrix();
    };
    resize();
    const tick = () => {
      if (!this.isConnected) return;
      mesh.rotation.y += 0.01; mesh.rotation.x += 0.005;
      renderer.render(scene, camera);
      requestAnimationFrame(tick);
    };
    tick();
    this._three = { renderer, scene, camera, mesh };
    this._ro = new ResizeObserver(resize); this._ro.observe(this);
  }
  cleanup() { this._ro?.disconnect(); this._three = null; }
});
component('model3-d', (e, p) => {
  const s = document.createElement('t-scene3-d');
  s._raw = { src: p.src, height: p.height, autoRotate: p.autoRotate };
  s._attrsRead = true;
  e.replaceChildren(s);
});
component('orbit-view', (e, p) => {
  const s = document.createElement('t-scene3-d');
  s._raw = { src: p.src, height: p.height, camera: { yaw: p.yaw, pitch: p.pitch, distance: p.distance } };
  s._attrsRead = true;
  e.replaceChildren(s);
});
component('chat-card', (e, p) => {
  e.className = 't-card';
  if (p.title) e.prepend(el('text', { text: p.title, variant: 'h5' }));
});
component('inline-panel', (e) => { e.style.padding = '8px'; });
component('confirm-bar', (e, p) => {
  e.replaceChildren(
    p.message ? el('text', { text: p.message }) : null,
    el('row', { gap: 8 },
      el('button', { text: p.cancelLabel ?? 'Cancel', variant: 'borderless' }),
      el('button', { text: p.confirmLabel ?? 'Confirm', variant: 'primary' }),
    ),
  );
});
component('suggestion-chips', (e, p) => {
  e.replaceChildren(...asList(p.items).map((it) => el('chip', { text: asText(it.label) })));
});
component('animated-visibility', (e) => { e.style.transition = 'opacity .2s'; });
component('shared-axis', (e) => {});
component('hero', (e) => {});
