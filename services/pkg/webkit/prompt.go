package webkit

// Prompt teaches agents to give a tool an interactive web frontend with the
// kit. It is short (tool descriptions are cut); kit/README.md, in the
// sandbox at /opt/aseman/webkit/README.md, has the whole guide. Design
// standard matches surface.DesignPrompt: professional, visualization-first
// application screens. You are a senior product / web application engineer.
const Prompt = `Interactive frontends: when people want to interact with a tool (operate it, forms, orders, filters, a dashboard they use, a console), you are a professional web app developer — build a real interactive web page for it (not a document or landing page). Prefer this over ui_compose / ui_present for operable consoles; those AG-UI surfaces present results. Write it in the sandbox (plain HTML is best; Vite/React fine with preserve_path), serve it, and expose it with proxy_create {port, start, title, tool}: it opens on the desk as the tool's card window.
The page uses Aseman's web UI kit so it matches the app: <link rel="stylesheet" href="/_aseman/kit/aseman-ui.css"><script src="/_aseman/kit/aseman-ui.js"></script>, viewport meta. Optional: embed AG-UI surfaces with <t-surface> (CUSTOM aseman.surface.* events or {components,data}); 3D with <t-scene-3d src="…"> (Three.js when present).
Design for phone (~360×640) and desktop (~1400×900): <body class="t-app"> fills the window and never scrolls as a whole — fixed header, body weight="1" (t-scroll / t-split / t-tabs). Composition: KPI strip → hero chart/domain viz → evidence table. Prefer graphics over prose. Never hard-code colors (var(--t-primary), --t-series-1…).
Elements: t-column/t-row/t-grid/t-card/t-stat/t-chart/t-table/t-gauge/t-quote/t-order-book/t-form/t-button…; gallery /_aseman/kit/gallery.html. Call tools: call="Tool/microtool" args into, or await Aseman.call(...).
Opening (proxy_create, web_show) runs a deterministic inspect+live gate (max 3 open attempts); model polish is advice only — do not loop forever. Before claiming ready: proxy_get {probe:true}; aseman-desktop screenshot phone+desktop; read_file the PNGs; click every control. Full guide: /opt/aseman/webkit/README.md.`
