// ---------------------------------------------------------------------------
// Boot: the stylesheet (added next to this script when the page did not link
// it), the app's theme, and the list of components.
// ---------------------------------------------------------------------------

(function boot() {
  const script = document.currentScript;
  if (!document.querySelector('link[href*="aseman-ui.css"]') && !document.querySelector('style[data-aseman-ui]')) {
    const href = script && script.src ? script.src.replace(/aseman-ui(\.min)?\.js(\?.*)?$/, 'aseman-ui.css') : previewPrefix() + '/_aseman/kit/aseman-ui.css';
    const link = h('link', { rel: 'stylesheet', href, 'data-aseman-ui': '' });
    (document.head || document.documentElement).prepend(link);
  }
  initTheme();
  Aseman.components = Object.keys(defined).sort();
  Aseman.ready = new Promise((resolve_) => {
    if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', () => resolve_(Aseman), { once: true });
    else resolve_(Aseman);
  });
  document.dispatchEvent(new CustomEvent('aseman:ready', { detail: Aseman }));
})();
