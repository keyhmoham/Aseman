import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../../../core/utils/context_extensions.dart';
import '../../../data/services/tradera_service.dart';
import '../data/workspace_files.dart';
import '../domain/file_types.dart';
import 'file_actions.dart';
import 'file_viewer.dart' show formatBytes;

/// The largest file uploaded from here.
const _uploadLimit = 48 << 20;

/// The space's workspace as a tree of folders and files, each folder read
/// when first opened. Tapping a file calls [onOpen]. Files and folders are
/// made, uploaded, renamed and deleted from its menus, while the computer
/// sleeps too: it is not woken for its files.
class WorkspaceFileTree extends StatefulWidget {
  const WorkspaceFileTree({
    super.key,
    required this.service,
    required this.spaceId,
    required this.onOpen,
    this.selected = '',
  });

  final TraderaService service;
  final String spaceId;
  final ValueChanged<WorkspaceEntry> onOpen;

  /// The path of the file open now, highlighted.
  final String selected;

  @override
  State<WorkspaceFileTree> createState() => _WorkspaceFileTreeState();
}

class _WorkspaceFileTreeState extends State<WorkspaceFileTree> {
  final _children = <String, List<WorkspaceEntry>>{};
  final _errors = <String, String>{};
  final _expanded = <String>{};
  final _loading = <String>{};

  WorkspaceFiles get _files => WorkspaceFiles(widget.service, widget.spaceId);

  @override
  void initState() {
    super.initState();
    _read(WorkspaceFiles.root);
  }

  @override
  void didUpdateWidget(covariant WorkspaceFileTree old) {
    super.didUpdateWidget(old);
    if (old.spaceId != widget.spaceId) _reset();
  }

  void _reset() {
    setState(() {
      _children.clear();
      _errors.clear();
      _expanded.clear();
    });
    _read(WorkspaceFiles.root);
  }

  /// Reads the root and every open folder again.
  Future<void> _refresh() async {
    await Future.wait([
      _read(WorkspaceFiles.root),
      for (final f in _expanded) _read(f),
    ]);
  }

  Future<void> _read(String folder) async {
    setState(() => _loading.add(folder));
    try {
      final entries = await _files.list(folder);
      if (!mounted) return;
      setState(() {
        _children[folder] = entries;
        _errors.remove(folder);
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _errors[folder] = '$e');
    } finally {
      if (mounted) setState(() => _loading.remove(folder));
    }
  }

  static String _parentOf(String path) {
    final i = path.lastIndexOf('/');
    return i <= 0 ? WorkspaceFiles.root : path.substring(0, i);
  }

  bool _taken(String folder, String name) =>
      _children[folder]?.any((e) => e.name == name) ?? false;

  /// Reads [folder] again after a change, and opens it.
  Future<void> _changed(String folder) async {
    if (folder != WorkspaceFiles.root) setState(() => _expanded.add(folder));
    await _read(folder);
  }

  Future<void> _newFile(String folder) async {
    final name = await askFileName(
      context,
      title: 'New file',
      action: 'Create',
      hint: 'notes.md',
    );
    if (name == null || !mounted) return;
    if (_taken(folder, name)) {
      context.showMessage('$name is already there.');
      return;
    }
    final path = '$folder/$name';
    final made = await runWorkspaceChange(
      context,
      ({required wake}) => _files.write(path, Uint8List(0), wake: wake),
    );
    if (!made || !mounted) return;
    await _changed(folder);
    widget.onOpen(WorkspaceEntry(name: name, path: path, isDirectory: false));
  }

  Future<void> _newFolder(String folder) async {
    final name = await askFileName(
      context,
      title: 'New folder',
      action: 'Create',
      hint: 'docs',
    );
    if (name == null || !mounted) return;
    if (_taken(folder, name)) {
      context.showMessage('$name is already there.');
      return;
    }
    final made = await runWorkspaceChange(
      context,
      ({required wake}) => _files.mkdir('$folder/$name', wake: wake),
    );
    if (made && mounted) await _changed(folder);
  }

  Future<void> _upload(String folder) async {
    final picked = await openFiles();
    if (picked.isEmpty || !mounted) return;
    var count = 0;
    for (final file in picked) {
      if (await file.length() > _uploadLimit) {
        if (mounted) {
          context.showMessage('${file.name} is too large to upload here.');
        }
        continue;
      }
      final bytes = await file.readAsBytes();
      if (!mounted) return;
      final path = '$folder/${file.name}';
      if (await runWorkspaceChange(
        context,
        ({required wake}) => _files.write(path, bytes, wake: wake),
      )) {
        count++;
      }
      if (!mounted) return;
    }
    if (count > 0) {
      context.showMessage(count == 1 ? 'Uploaded' : 'Uploaded $count files');
      await _changed(folder);
    }
  }

  Future<void> _rename(WorkspaceEntry e) async {
    final name = await askFileName(
      context,
      title: 'Rename',
      action: 'Rename',
      initial: e.name,
    );
    if (name == null || name == e.name || !mounted) return;
    final folder = _parentOf(e.path);
    if (_taken(folder, name)) {
      context.showMessage('$name is already there.');
      return;
    }
    final to = '$folder/$name';
    final moved = await runWorkspaceChange(
      context,
      ({required wake}) => _files.move(e.path, to, wake: wake),
    );
    if (!moved || !mounted) return;
    setState(() {
      if (_expanded.remove(e.path)) _expanded.add(to);
      _children.remove(e.path);
    });
    await _changed(folder);
  }

  Future<void> _delete(WorkspaceEntry e) async {
    if (!await confirmFileDelete(context, e) || !mounted) return;
    final deleted = await runWorkspaceChange(
      context,
      ({required wake}) => _files.delete(e.path, wake: wake),
      done: '${e.name} deleted',
    );
    if (!deleted || !mounted) return;
    setState(() {
      _expanded.removeWhere((p) => p == e.path || p.startsWith('${e.path}/'));
      _children.removeWhere(
        (p, _) => p == e.path || p.startsWith('${e.path}/'),
      );
    });
    await _changed(_parentOf(e.path));
  }

  /// What can be done in [folder]: make a file or folder, or upload.
  List<PopupMenuEntry<VoidCallback>> _folderItems(String folder) => [
    PopupMenuItem(
      value: () => _newFile(folder),
      child: const ListTile(
        dense: true,
        leading: Icon(Icons.note_add_outlined),
        title: Text('New file'),
      ),
    ),
    PopupMenuItem(
      value: () => _newFolder(folder),
      child: const ListTile(
        dense: true,
        leading: Icon(Icons.create_new_folder_outlined),
        title: Text('New folder'),
      ),
    ),
    PopupMenuItem(
      value: () => _upload(folder),
      child: const ListTile(
        dense: true,
        leading: Icon(Icons.upload_file_rounded),
        title: Text('Upload files'),
      ),
    ),
  ];

  /// The menu of a file or folder, where it was pressed.
  Future<void> _menu(WorkspaceEntry e, Offset at) async {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final chosen = await showMenu<VoidCallback>(
      context: context,
      position: RelativeRect.fromRect(
        at & const Size(1, 1),
        Offset.zero & overlay.size,
      ),
      items: [
        if (e.isDirectory) ...[
          ..._folderItems(e.path),
          const PopupMenuDivider(),
        ] else
          PopupMenuItem(
            value: () => widget.onOpen(e),
            child: const ListTile(
              dense: true,
              leading: Icon(Icons.open_in_new_rounded),
              title: Text('Open'),
            ),
          ),
        PopupMenuItem(
          value: () => _rename(e),
          child: const ListTile(
            dense: true,
            leading: Icon(Icons.drive_file_rename_outline_rounded),
            title: Text('Rename'),
          ),
        ),
        PopupMenuItem(
          value: () => _delete(e),
          child: const ListTile(
            dense: true,
            leading: Icon(Icons.delete_outline_rounded),
            title: Text('Delete'),
          ),
        ),
      ],
    );
    chosen?.call();
  }

  void _toggle(WorkspaceEntry folder) {
    setState(() {
      if (!_expanded.remove(folder.path)) _expanded.add(folder.path);
    });
    if (_expanded.contains(folder.path) &&
        !_children.containsKey(folder.path)) {
      _read(folder.path);
    }
  }

  /// The visible rows, depth first.
  List<_Row> _rows() {
    final rows = <_Row>[];
    void add(String folder, int depth) {
      if (_errors[folder] case final error?
          when folder != WorkspaceFiles.root) {
        rows.add(_Row.message(depth, error));
        return;
      }
      final entries = _children[folder];
      if (entries == null) {
        if (_loading.contains(folder) && folder != WorkspaceFiles.root) {
          rows.add(_Row.loading(depth));
        }
        return;
      }
      if (entries.isEmpty && folder != WorkspaceFiles.root) {
        rows.add(_Row.message(depth, 'Empty folder'));
      }
      for (final e in entries) {
        // What holds a folder made while the computer slept.
        if (!e.isDirectory && e.name == '.keep') continue;
        rows.add(_Row.entry(depth, e));
        if (e.isDirectory && _expanded.contains(e.path)) add(e.path, depth + 1);
      }
    }

    add(WorkspaceFiles.root, 0);
    return rows;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final rootError = _errors[WorkspaceFiles.root];
    final rootEntries = _children[WorkspaceFiles.root];
    final rows = _rows();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(Icons.dns_outlined, size: 14, color: scheme.onSurfaceVariant),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                '/workspace',
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 11,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
            PopupMenuButton<VoidCallback>(
              tooltip: 'New',
              icon: const Icon(Icons.add_rounded, size: 18),
              style: IconButton.styleFrom(visualDensity: VisualDensity.compact),
              onSelected: (action) => action(),
              itemBuilder: (_) => _folderItems(WorkspaceFiles.root),
            ),
            IconButton(
              tooltip: 'Collapse folders',
              visualDensity: VisualDensity.compact,
              onPressed: _expanded.isEmpty
                  ? null
                  : () => setState(() => _expanded.clear()),
              icon: const Icon(Icons.unfold_less_rounded, size: 17),
            ),
            IconButton(
              tooltip: 'Refresh files',
              visualDensity: VisualDensity.compact,
              onPressed: _refresh,
              icon: const Icon(Icons.refresh_rounded, size: 17),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Expanded(
          child: rootEntries == null && rootError == null
              ? const Center(child: CircularProgressIndicator())
              : rootError != null && rootEntries == null
              ? _Note(
                  icon: Icons.cloud_off_outlined,
                  text: rootError,
                  onRetry: _refresh,
                )
              : rows.isEmpty
              ? _Note(
                  icon: Icons.folder_open_outlined,
                  text:
                      'No files yet. Files agents and people make in the workspace show up here.',
                  action: ('New file', () => _newFile(WorkspaceFiles.root)),
                )
              : RefreshIndicator(
                  onRefresh: _refresh,
                  child: ListView.builder(
                    padding: const EdgeInsets.only(bottom: 12),
                    itemCount: rows.length,
                    itemBuilder: (context, i) => _tile(context, rows[i]),
                  ),
                ),
        ),
      ],
    );
  }

  Widget _tile(BuildContext context, _Row row) {
    final scheme = Theme.of(context).colorScheme;
    final indent = 4.0 + row.depth * 14;
    final e = row.entry;
    if (e == null) {
      return Padding(
        padding: EdgeInsets.fromLTRB(indent + 22, 6, 8, 6),
        child: row.loading
            ? const Align(
                alignment: Alignment.centerLeft,
                child: SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              )
            : Text(
                row.message,
                style: TextStyle(
                  fontSize: 10,
                  fontStyle: FontStyle.italic,
                  color: scheme.onSurfaceVariant,
                ),
              ),
      );
    }
    final open = _expanded.contains(e.path);
    final type = FileType.of(e.name);
    final selected = !e.isDirectory && e.path == widget.selected;
    return _HoverRow(
      selected: selected,
      onTap: () => e.isDirectory ? _toggle(e) : widget.onOpen(e),
      onMenu: (at) => _menu(e, at),
      builder: (hovered, menuButton) => Padding(
        padding: EdgeInsets.fromLTRB(indent, 5, hovered ? 2 : 8, 5),
        child: Row(
          children: [
            SizedBox(
              width: 18,
              child: e.isDirectory
                  ? AnimatedRotation(
                      turns: open ? .25 : 0,
                      duration: const Duration(milliseconds: 160),
                      child: Icon(
                        Icons.chevron_right_rounded,
                        size: 17,
                        color: scheme.onSurfaceVariant,
                      ),
                    )
                  : null,
            ),
            const SizedBox(width: 2),
            Icon(
              e.isDirectory
                  ? (open ? Icons.folder_open_rounded : Icons.folder_rounded)
                  : type.icon,
              size: 17,
              color: e.isDirectory ? FileType.folder : type.color,
            ),
            const SizedBox(width: 7),
            Expanded(
              child: Text(
                e.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: e.isDirectory ? FontWeight.w700 : FontWeight.w500,
                  color: selected ? scheme.onPrimaryContainer : null,
                ),
              ),
            ),
            if (hovered)
              menuButton
            else if (!e.isDirectory && e.size > 0)
              Text(
                formatBytes(e.size),
                style: TextStyle(fontSize: 9, color: scheme.onSurfaceVariant),
              ),
          ],
        ),
      ),
    );
  }
}

/// A row of the tree: tapped to open, its menu on a right click, a long
/// press, or the button shown while the pointer is over it.
class _HoverRow extends StatefulWidget {
  const _HoverRow({
    required this.selected,
    required this.onTap,
    required this.onMenu,
    required this.builder,
  });
  final bool selected;
  final VoidCallback onTap;
  final ValueChanged<Offset> onMenu;
  final Widget Function(bool hovered, Widget menuButton) builder;
  @override
  State<_HoverRow> createState() => _HoverRowState();
}

class _HoverRowState extends State<_HoverRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final menuButton = Builder(
      builder: (button) => SizedBox(
        width: 26,
        height: 20,
        child: IconButton(
          tooltip: 'More',
          padding: EdgeInsets.zero,
          iconSize: 16,
          onPressed: () {
            final box = button.findRenderObject()! as RenderBox;
            widget.onMenu(box.localToGlobal(box.size.bottomLeft(Offset.zero)));
          },
          icon: const Icon(Icons.more_horiz_rounded),
        ),
      ),
    );
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Material(
        color: widget.selected ? scheme.primaryContainer : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: widget.onTap,
          onLongPress: () {
            final box = context.findRenderObject()! as RenderBox;
            widget.onMenu(box.localToGlobal(box.size.centerLeft(Offset.zero)));
          },
          onSecondaryTapUp: (d) => widget.onMenu(d.globalPosition),
          child: widget.builder(_hovered, menuButton),
        ),
      ),
    );
  }
}

class _Row {
  const _Row.entry(this.depth, WorkspaceEntry this.entry)
    : loading = false,
      message = '';
  const _Row.loading(this.depth) : entry = null, loading = true, message = '';
  const _Row.message(this.depth, this.message) : entry = null, loading = false;
  final int depth;
  final WorkspaceEntry? entry;
  final bool loading;
  final String message;
}

class _Note extends StatelessWidget {
  const _Note({
    required this.icon,
    required this.text,
    this.onRetry,
    this.action,
  });
  final IconData icon;
  final String text;
  final VoidCallback? onRetry;
  final (String, VoidCallback)? action;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 28, color: scheme.onSurfaceVariant),
            const SizedBox(height: 8),
            Text(
              text,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 10, color: scheme.onSurfaceVariant),
            ),
            if (onRetry != null)
              TextButton(onPressed: onRetry, child: const Text('Try again')),
            if (action != null) ...[
              const SizedBox(height: 8),
              FilledButton.tonalIcon(
                onPressed: action!.$2,
                icon: const Icon(Icons.note_add_outlined, size: 17),
                label: Text(action!.$1),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
