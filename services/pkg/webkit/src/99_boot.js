// ---------------------------------------------------------------------------
// Boot: the stylesheet (added next to this script when the page did not link
// it), the app's theme, and the list of components.
// ---------------------------------------------------------------------------

(function boot() {
  const script = document.currentScript;
  if (!document.querySelector('link[href*="tradera-ui.css"]') && !document.querySelector('style[data-tradera-ui]')) {
    const href = script && script.src ? script.src.replace(/tradera-ui(\.min)?\.js(\?.*)?$/, 'tradera-ui.css') : previewPrefix() + '/_tradera/kit/tradera-ui.css';
    const link = h('link', { rel: 'stylesheet', href, 'data-tradera-ui': '' });
    (document.head || document.documentElement).prepend(link);
  }
  initTheme();
  Tradera.components = Object.keys(defined).sort();
  Tradera.ready = new Promise((resolve_) => {
    if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', () => resolve_(Tradera), { once: true });
    else resolve_(Tradera);
  });
  document.dispatchEvent(new CustomEvent('tradera:ready', { detail: Tradera }));
})();
