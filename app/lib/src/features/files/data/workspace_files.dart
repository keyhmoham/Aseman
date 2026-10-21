import 'dart:convert';
import 'dart:typed_data';

import '../../../data/services/tradera_service.dart';

/// A file or folder of a space's shared workspace.
class WorkspaceEntry {
  const WorkspaceEntry({
    required this.name,
    required this.path,
    required this.isDirectory,
    this.size = 0,
  });

  final String name;

  /// Its full path, `/workspace/…`.
  final String path;
  final bool isDirectory;
  final int size;
}

/// The workspace's answer when a folder or file cannot be read: missing, or
/// the computer asleep or never started.
class WorkspaceFileUnavailable implements Exception {
  const WorkspaceFileUnavailable(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Lists and reads the files of a space's shared workspace
/// (`spaces.sandbox_files`), which takes paths relative to /workspace.
class WorkspaceFiles {
  const WorkspaceFiles(this.service, this.spaceId);

  final TraderaService service;
  final String spaceId;

  static const root = '/workspace';

  /// [path] relative to the workspace, as the node takes it.
  static String relative(String path) => path == root
      ? ''
      : path.startsWith('$root/')
      ? path.substring(root.length + 1)
      : path.replaceFirst(RegExp('^/+'), '');

  Future<Map<String, dynamic>> _call(String operation, String path) async {
    final res = await service.invokeAction(
      'spaces',
      'sandbox_files',
      body: {'space': spaceId, 'operation': operation, 'path': relative(path)},
      timeout: const Duration(minutes: 2),
    );
    final map = res is Map ? res.cast<String, dynamic>() : <String, dynamic>{};
    if (map['ok'] == false) {
      throw WorkspaceFileUnavailable(
        '${map['error'] ?? 'The workspace could not be read.'}',
      );
    }
    return map;
  }

  /// The folder's entries, folders first, each in name order.
  Future<List<WorkspaceEntry>> list([String folder = root]) async {
    final res = await _call('list', folder);
    final base = folder == root || folder.isEmpty
        ? root
        : folder.startsWith(root)
        ? folder
        : '$root/${relative(folder)}';
    final entries = [
      for (final e
          in (res['items'] ??
                  res['files'] ??
                  res['entries'] ??
                  const <dynamic>[])
              as List)
        if (e is Map && '${e['name'] ?? ''}'.isNotEmpty)
          WorkspaceEntry(
            name: '${e['name']}',
            path: '$base/${e['name']}',
            isDirectory:
                e['type'] == 'dir' ||
                e['type'] == 'directory' ||
                e['directory'] == true,
            size: (e['size'] as num?)?.toInt() ?? 0,
          ),
    ];
    entries.sort(
      (a, b) => a.isDirectory != b.isDirectory
          ? (a.isDirectory ? -1 : 1)
          : a.name.toLowerCase().compareTo(b.name.toLowerCase()),
    );
    return entries;
  }

  /// The file's bytes.
  Future<Uint8List> read(String path) async {
    final res = await _call('read', path);
    final b64 = res['data_base64'];
    if (b64 is String && b64.isNotEmpty) return base64Decode(b64);
    return Uint8List.fromList(utf8.encode('${res['content'] ?? ''}'));
  }
}
