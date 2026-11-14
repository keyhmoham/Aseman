import 'dart:convert';
import 'dart:typed_data';

import '../../../data/services/aseman_service.dart';

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

/// A change the workspace's stored files cannot take while the computer
/// sleeps (a file too large, or what the provider cannot do without it):
/// made again with `wake`, it wakes the computer and goes through it.
class WorkspaceNeedsComputer implements Exception {
  const WorkspaceNeedsComputer(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Lists and reads the files of a space's shared workspace
/// (`spaces.sandbox_files`), which takes paths relative to /workspace.
class WorkspaceFiles {
  const WorkspaceFiles(this.service, this.spaceId);

  final AsemanService service;
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

  /// Changes the workspace. Files are changed while the computer sleeps
  /// (it is not woken for them); what needs it throws
  /// [WorkspaceNeedsComputer] unless [wake] allows waking it.
  Future<void> _change(
    String operation,
    String path, {
    String? to,
    Uint8List? data,
    bool wake = false,
  }) async {
    // Expo sandbox_files: list|read|write|mkdir|delete|preview with
    // path/content/data_base64 — no wake flag. Wake via spaces.computer first.
    if (wake) {
      await service.invokeAction(
        'spaces',
        'computer',
        body: {'space': spaceId, 'operation': 'provision'},
        timeout: const Duration(minutes: 5),
      );
    }
    final res = await service.invokeAction(
      'spaces',
      'sandbox_files',
      body: {
        'space': spaceId,
        'operation': operation,
        'path': relative(path),
        if (to != null) 'to': relative(to),
        if (data != null) 'data_base64': base64Encode(data),
      },
      timeout: Duration(minutes: wake ? 5 : 2),
    );
    final map = res is Map ? res.cast<String, dynamic>() : <String, dynamic>{};
    if (map['ok'] == false) {
      final message = '${map['error'] ?? 'The workspace could not be changed.'}';
      if (map['asleep'] == true) throw WorkspaceNeedsComputer(message);
      throw WorkspaceFileUnavailable(message);
    }
  }

  /// Saves a file (made with its folders when new).
  Future<void> write(String path, Uint8List data, {bool wake = false}) =>
      _change('write', path, data: data, wake: wake);

  /// Makes a folder (and its parents).
  Future<void> mkdir(String path, {bool wake = false}) =>
      _change('mkdir', path, wake: wake);

  /// Moves or renames a file or folder; [to] must not exist yet.
  Future<void> move(String from, String to, {bool wake = false}) =>
      _change('move', from, to: to, wake: wake);

  /// Deletes a file or a folder with everything in it.
  Future<void> delete(String path, {bool wake = false}) =>
      _change('delete', path, wake: wake);

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
