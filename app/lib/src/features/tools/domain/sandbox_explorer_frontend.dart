import 'dart:convert';

/// The elpian frontend bundle for the **Sandbox Explorer** — a feature-rich,
/// professional file explorer that drives the space's shared docker sandbox.
///
/// The guest JS renders through the elpian DSL and talks to the sandbox via the
/// host bridge (`sandbox.exec`, `sandbox.upload`, `sandbox.read`, …) that the
/// client services with the user's signed identity. It uses only semantic theme
/// classes (`bg`, `panel-card`, `primary`, `muted`, …) injected by
/// [MiniappTheme], so it follows the host app's color system automatically.
abstract final class SandboxExplorerFrontend {
  static const manifestName = 'Sandbox Explorer';

  /// Full `{manifest, source}` bundle ready to store on a bot's frontend entity.
  static String bundle({String name = manifestName}) => jsonEncode({
        'manifest': {
          'name': name,
          'version': '1.0.0',
          'runtime': 'quickjs',
        },
        'source': source,
      });

  static const source = r'''
var state = {
  cwd: '/',
  entries: [],
  loading: false,
  error: '',
  viewPath: '',
  viewContent: '',
  cmd: '',
  cmdOutput: '',
  pathDraft: '',
  nameDraft: '',
  creating: false,
  cmdMode: false,
  uploading: false,
  status: '',
  started: false
};

// ── host bridge helpers ──────────────────────────────────────────────────
function sbExec(command) {
  var raw = askHost('sandbox.exec', [command]);
  try {
    var p = JSON.parse(raw);
    if (p && p.type === 'string' && p.data && typeof p.data.value === 'string') {
      return { ok: true, out: p.data.value };
    }
    if (p && p.data && p.data.value && p.data.value.error) {
      return { ok: false, out: p.data.value.error.message || 'sandbox error' };
    }
  } catch (e) {}
  return { ok: true, out: String(raw) };
}

function sbRead(path) {
  var raw = askHost('sandbox.read', [path]);
  try {
    var p = JSON.parse(raw);
    if (p && p.type === 'string' && p.data) return p.data.value;
  } catch (e) {}
  return '';
}

function esc(s) { return String(s).replace(/"/g, '\\"'); }

// ── directory listing ────────────────────────────────────────────────────
function list(cwd) {
  var cmd = "cd '" + esc(cwd) + "' 2>/dev/null && for f in * .*; do " +
    "[ \"$f\" = \".\" ] && continue; [ \"$f\" = \"..\" ] && continue; " +
    "if [ -d \"$f\" ]; then t=d; else t=f; fi; s=0; m=0; " +
    "s=$(stat -c%s \"$f\" 2>/dev/null); m=$(stat -c%Y \"$f\" 2>/dev/null); " +
    "printf '%s\\t%s\\t%s\\t%s\\n' \"$f\" \"$t\" \"$s\" \"$m\"; done";
  var res = sbExec(cmd);
  if (!res.ok) { state.error = res.out; state.entries = []; return; }
  var rows = [];
  if (res.out) {
    var lines = res.out.split('\n');
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i];
      if (!line) continue;
      var p = line.split('\t');
      if (p.length < 4) continue;
      rows.push({ n: p[0], t: p[1], s: Number(p[2]) || 0, m: Number(p[3]) || 0 });
    }
  }
  // Directories first, then files, alphabetically.
  rows.sort(function(a, b) {
    if (a.t !== b.t) return a.t === 'd' ? -1 : 1;
    return a.n < b.n ? -1 : (a.n > b.n ? 1 : 0);
  });
  state.entries = rows;
  state.error = '';
}

function humanSize(n) {
  if (n >= 1073741824) return (n / 1073741824).toFixed(1) + ' GB';
  if (n >= 1048576) return (n / 1048576).toFixed(1) + ' MB';
  if (n >= 1024) return (n / 1024).toFixed(0) + ' KB';
  return String(n) + ' B';
}

function parentOf(p) {
  p = String(p);
  if (p === '/' || p === '') return '/';
  var i = p.lastIndexOf('/');
  if (i <= 0) return '/';
  return p.substring(0, i);
}

function joinPath(dir, name) {
  dir = String(dir);
  if (dir === '/') return '/' + name;
  return dir + '/' + name;
}

// ── navigation / actions ─────────────────────────────────────────────────
function reload() {
  state.loading = true; state.viewPath = ''; state.viewContent = ''; state.error = '';
  renderApp();
  list(state.cwd);
  state.loading = false;
  renderApp();
}

function navigateTo(path) {
  state.cwd = path;
  state.viewPath = ''; state.viewContent = ''; state.error = ''; state.cmdOutput = '';
  reload();
}

function openEntry(name) {
  var path = joinPath(state.cwd, name);
  if (name === '..') { navigateTo(parentOf(state.cwd)); return; }
  navigateTo(path);
}

function viewEntry(name) {
  var path = joinPath(state.cwd, name);
  state.viewPath = path;
  state.viewContent = 'loading…';
  renderApp();
  state.viewContent = sbRead(path);
  renderApp();
}

function deleteEntry(name) {
  var path = joinPath(state.cwd, name);
  state.loading = true; state.error = '';
  renderApp();
  var res = sbExec('rm -rf "' + esc(path) + '" 2>&1');
  state.loading = false;
  if (!res.ok) state.error = res.out;
  reload();
}

function createDir() {
  var name = state.nameDraft.replace(/^\s+|\s+$/g, '');
  if (!name) { state.creating = false; renderApp(); return; }
  state.loading = true; state.error = '';
  renderApp();
  var res = sbExec('mkdir -p "' + esc(joinPath(state.cwd, name)) + '" 2>&1');
  state.loading = false; state.creating = false; state.nameDraft = '';
  if (!res.ok) state.error = res.out;
  reload();
}

function uploadHere() {
  if (state.uploading) return;
  state.uploading = true; state.error = '';
  renderApp();
  var raw = askHost('sandbox.upload', [state.cwd]);
  try {
    var p = JSON.parse(raw);
    if (p && p.data && p.data.value && p.data.value.error) {
      state.error = p.data.value.error.message || 'upload failed';
    } else if (p && p.data && p.data.value && p.data.value.name) {
      state.status = 'Uploaded ' + p.data.value.name;
    }
  } catch (e) { state.error = String(e); }
  state.uploading = false;
  reload();
}

function runCommand() {
  var cmd = state.cmd.replace(/^\s+|\s+$/g, '');
  if (!cmd) return;
  state.cmdOutput = '…'; renderApp();
  var res = sbExec('cd "' + esc(state.cwd) + '" 2>/dev/null; ' + cmd);
  state.cmdOutput = res.ok ? (res.out || '(no output)') : ('error: ' + res.out);
  renderApp();
}

// ── event handlers ───────────────────────────────────────────────────────
function onNav(e) {
  var key = e && e.currentTarget ? String(e.currentTarget) : '';
  if (key.indexOf('nav:') === 0) openEntry(key.substring(4));
  else if (key === 'up') navigateTo(parentOf(state.cwd));
  else if (key === 'refresh') reload();
}

function onView(e) {
  var key = e && e.currentTarget ? String(e.currentTarget) : '';
  if (key.indexOf('view:') === 0) viewEntry(key.substring(5));
  else if (key === 'close-view') { state.viewPath = ''; state.viewContent = ''; renderApp(); }
}

function onDelete(e) {
  var key = e && e.currentTarget ? String(e.currentTarget) : '';
  if (key.indexOf('del:') === 0) deleteEntry(key.substring(4));
}

function onTool(e) {
  var key = e && e.currentTarget ? String(e.currentTarget) : '';
  if (key === 'new-folder') { state.creating = !state.creating; renderApp(); }
  else if (key === 'cmd') { state.cmdMode = !state.cmdMode; renderApp(); }
  else if (key === 'upload') uploadHere();
  else if (key === 'name-cancel') { state.creating = false; renderApp(); }
}

function onPathInput(e) {
  if (e && e.value !== undefined) state.pathDraft = String(e.value);
}
function onPathGo() {
  var p = state.pathDraft || state.cwd;
  navigateTo(p);
}
function onNameInput(e) {
  if (e && e.value !== undefined) state.nameDraft = String(e.value);
}
function onNameSubmit() { createDir(); }
function onCmdInput(e) {
  if (e && e.value !== undefined) state.cmd = String(e.value);
}
function onCmdSubmit() { runCommand(); }

// ── rendering ────────────────────────────────────────────────────────────
function text(t, style, cls) {
  var node = { type: 'Text', props: { text: t } };
  if (style) node.props.style = style;
  if (cls) node.className = cls;
  return node;
}

function iconFor(entry) {
  if (entry.t === 'd') return 'folder';
  var n = entry.n.toLowerCase();
  if (n.indexOf('.png') >= 0 || n.indexOf('.jpg') >= 0 || n.indexOf('.gif') >= 0 ||
      n.indexOf('.webp') >= 0 || n.indexOf('.jpeg') >= 0) return 'image';
  if (n.indexOf('.mp4') >= 0 || n.indexOf('.mov') >= 0 || n.indexOf('.webm') >= 0) return 'play_arrow';
  if (n.indexOf('.mp3') >= 0 || n.indexOf('.wav') >= 0 || n.indexOf('.ogg') >= 0 ||
      n.indexOf('.m4a') >= 0) return 'volume_up';
  if (n.indexOf('.pdf') >= 0) return 'receipt';
  if (n.indexOf('.zip') >= 0 || n.indexOf('.tar') >= 0 || n.indexOf('.gz') >= 0) return 'folder_open';
  if (n.indexOf('.js') >= 0 || n.indexOf('.py') >= 0 || n.indexOf('.go') >= 0 ||
      n.indexOf('.dart') >= 0 || n.indexOf('.sh') >= 0 || n.indexOf('.ts') >= 0) return 'code';
  return 'receipt';
}

function fileRow(entry) {
  var isDir = entry.t === 'd';
  var name = entry.n;
  var size = isDir ? '—' : humanSize(entry.s);
  var mtime = entry.m ? new Date(entry.m * 1000).toLocaleDateString() : '';
  var action = isDir ? 'nav:' : 'view:';
  return {
    type: 'Container', className: 'panel-card',
    props: { style: { margin: '2 0', padding: '4 10', borderRadius: '10' } },
    children: [
      {
        type: 'Row', props: { style: { justifyContent: 'space-between', alignItems: 'center' } },
        children: [
          {
            type: 'InkWell', key: action + name,
            props: { style: { padding: '4 0', borderRadius: '8' } },
            events: { tap: isDir ? 'onNav' : 'onView' },
            children: [
              {
                type: 'Row', props: { style: { alignItems: 'center', gap: '8' } },
                children: [
                  { type: 'Icon', props: { icon: iconFor(entry), size: 18, style: { color: isDir ? '#8B7BFF' : '#8EA4BD' } } },
                  text(name, { fontSize: '13', fontWeight: '600' }, 'fg')
                ]
              }
            ]
          },
          {
            type: 'Row', props: { style: { alignItems: 'center', gap: '12' } },
            children: [
              text(size, { fontSize: '11' }, 'muted'),
              text(mtime, { fontSize: '11' }, 'muted'),
              {
                type: 'InkWell', key: 'del:' + name, props: { style: { padding: '4', borderRadius: '8' } },
                events: { tap: 'onDelete' },
                children: [ { type: 'Icon', props: { icon: 'delete', size: 15, style: { color: '#FF6B79' } } } ]
              }
            ]
          }
        ]
      }
    ]
  };
}

function breadcrumbs() {
  var parts = state.cwd.split('/');
  var acc = '';
  var chips = [];
  for (var i = 0; i < parts.length; i++) {
    if (parts[i] === '') continue;
    acc = acc + '/' + parts[i];
    if (acc !== state.cwd) {
      chips.push({
        type: 'InkWell', key: 'nav:' + acc, props: { style: { padding: '4 6', borderRadius: '6' } },
        events: { tap: 'onNav' },
        children: [ text(parts[i], { fontSize: '11', fontWeight: '600' }, 'accent') ]
      });
    } else {
      chips.push(text(parts[i], { fontSize: '12', fontWeight: '700' }, 'fg'));
    }
  }
  return {
    type: 'Row', props: { style: { alignItems: 'center', gap: '4', flexWrap: 'wrap' } },
    children: chips
  };
}

function pathBar() {
  return {
    type: 'Container', className: 'panel-card',
    props: { style: { padding: '8', borderRadius: '10', margin: '0 0 8 0' } },
    children: [
      {
        type: 'Row', props: { style: { alignItems: 'center', gap: '6' } },
        children: [
          {
            type: 'InkWell', key: 'up', props: { style: { padding: '4', borderRadius: '8' } },
            events: { tap: 'onNav' },
            children: [ { type: 'Icon', props: { icon: 'arrow_upward', size: 16 } } ]
          },
          { type: 'TextField', key: 'path-field', props: { hint: 'Path' },
            events: { input: 'onPathInput', submit: 'onPathGo' } },
          {
            type: 'Button', className: 'btn-primary', props: { text: 'Go' },
            events: { tap: 'onPathGo' }
          }
        ]
      },
      breadcrumbs()
    ]
  };
}

function toolbar() {
  var mkIcon = function(key, icon) {
    return {
      type: 'InkWell', key: key, props: { style: { padding: '6', borderRadius: '8' } },
      events: { tap: 'onTool' },
      children: [ { type: 'Icon', props: { icon: icon, size: 18 } } ]
    };
  };
  return {
    type: 'Row', props: { style: { justifyContent: 'space-between', alignItems: 'center' } },
    children: [
      {
        type: 'Row', props: { style: { alignItems: 'center', gap: '6' } },
        children: [
          mkIcon('new-folder', 'folder_open'),
          mkIcon('upload', 'upload'),
          mkIcon('cmd', 'terminal')
        ]
      },
      {
        type: 'Row', props: { style: { alignItems: 'center', gap: '10' } },
        children: [
          text(state.entries.length + ' items', { fontSize: '11' }, 'muted'),
          mkIcon('refresh', 'refresh')
        ]
      }
    ]
  };
}

function createBar() {
  if (!state.creating) return { type: 'SizedBox', props: {} };
  return {
    type: 'Container', className: 'panel-card',
    props: { style: { padding: '8', borderRadius: '10', margin: '6 0' } },
    children: [
      {
        type: 'Row', props: { style: { alignItems: 'center', gap: '6' } },
        children: [
          { type: 'TextField', key: 'name-field', props: { hint: 'Folder name' },
            events: { input: 'onNameInput', submit: 'onNameSubmit' } },
          { type: 'Button', className: 'btn-primary', props: { text: 'Create' },
            events: { tap: 'onNameSubmit' } },
          { type: 'Button', className: 'btn-ghost', props: { text: 'Cancel' },
            events: { tap: 'onTool' } }
        ]
      }
    ]
  };
}

function terminalBar() {
  if (!state.cmdMode) return { type: 'SizedBox', props: {} };
  return {
    type: 'Container', className: 'panel-card',
    props: { style: { padding: '8', borderRadius: '10', margin: '6 0' } },
    children: [
      { type: 'TextField', key: 'cmd-field', props: { hint: 'Run a shell command…' },
        events: { input: 'onCmdInput', submit: 'onCmdSubmit' } },
      { type: 'Container', props: { style: { padding: '6', margin: '4 0 0 0' } },
        children: [ text(state.cmdOutput, { fontSize: '11' }) ] }
    ]
  };
}

function viewPanel() {
  if (!state.viewPath) return { type: 'SizedBox', props: {} };
  return {
    type: 'Container', className: 'panel-card',
    props: { style: { padding: '10', borderRadius: '10', margin: '6 0' } },
    children: [
      {
        type: 'Row', props: { style: { justifyContent: 'space-between', alignItems: 'center' } },
        children: [
          text(state.viewPath, { fontSize: '12', fontWeight: '700' }, 'fg'),
          {
            type: 'InkWell', key: 'close-view', props: { style: { padding: '4', borderRadius: '8' } },
            events: { tap: 'onView' },
            children: [ { type: 'Icon', props: { icon: 'close', size: 16 } } ]
          }
        ]
      },
      { type: 'Container', props: { style: { padding: '6', margin: '4 0 0 0' } },
        children: [ text(state.viewContent, { fontSize: '12' }) ] }
    ]
  };
}

function statusBar() {
  var status = state.status;
  if (state.uploading) status = 'Uploading…';
  if (state.loading) status = 'Working…';
  return {
    type: 'Row', props: { style: { justifyContent: 'space-between', alignItems: 'center' } },
    children: [
      text(status || 'Ready', { fontSize: '11' }, 'muted'),
      text(state.cwd, { fontSize: '11' }, 'muted')
    ]
  };
}

function errorBanner() {
  if (!state.error) return { type: 'SizedBox', props: {} };
  return {
    type: 'Container',
    props: { style: { padding: '8', margin: '6 0', borderRadius: '8', backgroundColor: '#FF6B79' } },
    children: [ text(state.error, { fontSize: '12', color: '#FFFFFF' }) ]
  };
}

function fileList() {
  var children = [];
  if (state.cwd !== '/') {
    children.push({
      type: 'InkWell', key: 'nav:..', props: { style: { padding: '6 10', borderRadius: '8' } },
      events: { tap: 'onNav' },
      children: [
        { type: 'Row', props: { style: { alignItems: 'center', gap: '8' } },
          children: [ { type: 'Icon', props: { icon: 'arrow_upward', size: 16 } },
                      text('..', { fontSize: '12', fontWeight: '600' }, 'fg') ] }
      ]
    });
  }
  if (state.loading) {
    children.push({
      type: 'Row', props: { style: { padding: '14', justifyContent: 'center', alignItems: 'center', gap: '8' } },
      children: [ { type: 'CircularProgressIndicator', props: {} },
                  text('Loading…', { fontSize: '12' }, 'muted') ]
    });
  } else if (state.entries.length === 0 && !state.error) {
    children.push({
      type: 'Container', props: { style: { padding: '26' } },
      children: [ text('Empty directory', { fontSize: '12' }, 'muted') ]
    });
  } else {
    for (var i = 0; i < state.entries.length; i++) children.push(fileRow(state.entries[i]));
  }
  return {
    type: 'ListView', props: { style: { padding: '2', gap: '2' } },
    children: children
  };
}

function MainComponent() {
  return {
    type: 'Container', className: 'bg',
    props: { style: { padding: '12' } },
    children: [
      text('Sandbox Explorer', { fontSize: '16', fontWeight: '800' }, 'fg'),
      text('Shared workspace sandbox', { fontSize: '11' }, 'muted'),
      { type: 'Divider', className: 'divider', props: { style: { margin: '8 0' } } },
      toolbar(),
      pathBar(),
      createBar(),
      terminalBar(),
      errorBanner(),
      viewPanel(),
      fileList(),
      { type: 'Divider', className: 'divider', props: { style: { margin: '8 0' } } },
      statusBar()
    ]
  };
}

function renderApp() { askHost('render', JSON.stringify(MainComponent())); }

// Boot.
state.pathDraft = state.cwd;
renderApp();
list(state.cwd);
renderApp();
''';
}
