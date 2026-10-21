import 'package:flutter/material.dart';

import '../../../data/services/tradera_service.dart';
import '../data/workspace_files.dart';
import '../domain/file_types.dart';
import 'file_viewer.dart' show formatBytes;

/// The space's workspace as a tree of folders and files, each folder read
/// when first opened. Tapping a file calls [onOpen].
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
              ? const _Note(
                  icon: Icons.folder_open_outlined,
                  text:
                      'No files yet. Files agents and people make in the workspace show up here.',
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
    return Material(
      color: selected ? scheme.primaryContainer : Colors.transparent,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => e.isDirectory ? _toggle(e) : widget.onOpen(e),
        child: Padding(
          padding: EdgeInsets.fromLTRB(indent, 5, 8, 5),
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
                    fontWeight: e.isDirectory
                        ? FontWeight.w700
                        : FontWeight.w500,
                    color: selected ? scheme.onPrimaryContainer : null,
                  ),
                ),
              ),
              if (!e.isDirectory && e.size > 0)
                Text(
                  formatBytes(e.size),
                  style: TextStyle(fontSize: 9, color: scheme.onSurfaceVariant),
                ),
            ],
          ),
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
  const _Note({required this.icon, required this.text, this.onRetry});
  final IconData icon;
  final String text;
  final VoidCallback? onRetry;
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
          ],
        ),
      ),
    );
  }
}
