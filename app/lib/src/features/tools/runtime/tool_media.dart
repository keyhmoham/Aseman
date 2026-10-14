import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../../data/services/tradera_service.dart';
import '../../../elpian/core/media.dart';

/// Reads a file of the space's project computer (`/workspace/...`) as bytes.
typedef SandboxRead = Future<Uint8List> Function(String path);

/// Where the media a tool's frontend shows comes from, in a space:
///
/// * the project computer's files: `/workspace/...`, `workspace://...`,
///   `sandbox://...`, `file:///workspace/...` and paths relative to
///   `/workspace` (`out/chart.png`), read through the node;
/// * the node's stored files: `/v1/files/{id}/content`, `attachment://{id}`,
///   `file://{id}`, `file:{id}` or a bare file id, fetched as the person;
/// * the node's own URLs (`/v1/proxy/...`, other root-relative paths and
///   absolute URLs on the node), with the person's credentials;
/// * anything else (other hosts, `data:` URIs, inline SVG) as the engine
///   loads it.
class ToolMedia {
  ToolMedia({
    required this.baseUrl,
    required this.headers,
    required this.fileUrl,
    required this.readSandbox,
    this.proxyUrl,
  });

  /// The space's media resolver, one per space (its file cache shared by the
  /// frontends shown there).
  static ToolMedia forSpace(TraderaService service, String spaceId) {
    final key = '${identityHashCode(service)}/$spaceId';
    final media = _spaces.remove(key) ?? ToolMedia.of(service, spaceId);
    _spaces[key] = media;
    while (_spaces.length > 8) {
      _spaces.remove(_spaces.keys.first);
    }
    return media;
  }

  static final Map<String, ToolMedia> _spaces = {};

  factory ToolMedia.of(TraderaService service, String spaceId) => ToolMedia(
        baseUrl: service.client.baseUrl,
        headers: service.authHeaders,
        fileUrl: service.fileContentUrl,
        proxyUrl: service.proxyUrl,
        readSandbox: (path) async {
          final out = await service.actionMap('spaces', 'sandbox_files',
              body: {'space': spaceId, 'operation': 'read', 'path': path},
              timeout: const Duration(minutes: 2));
          if (out['ok'] == false) {
            throw StateError(
                (out['error'] ?? 'could not read $path').toString());
          }
          final b64 = out['data_base64'];
          if (b64 is String && b64.isNotEmpty) return base64.decode(b64);
          final content = out['content'];
          if (content is String)
            return Uint8List.fromList(utf8.encode(content));
          throw StateError('could not read $path');
        },
      );

  final String baseUrl;
  final Map<String, String> Function() headers;
  final String Function(String fileId) fileUrl;
  final String Function(String proxyPath)? proxyUrl;
  final SandboxRead readSandbox;

  /// Project files read lately (a frontend draws the same image again on
  /// every rebuild and refill).
  final Map<String, Future<Uint8List>> _files = {};
  static const _keep = 48;

  static final _fileId = RegExp(r'^[0-9a-fA-F]{32}$');
  static final _filePath = RegExp(r'^/v1/files/([0-9a-fA-F]{32})/content$');
  static final _scheme = RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*:');

  /// The [ElpianMediaResolver] of this space.
  FutureOr<ElpianMedia?> call(String src) {
    src = src.trim();
    if (src.isEmpty) return null;
    final lower = src.toLowerCase();
    if (lower.startsWith('data:') ||
        lower.startsWith('asset:') ||
        lower.startsWith('<')) {
      return null;
    }

    // Stored files.
    final id = fileIdOf(src);
    if (id != null) {
      return ElpianMedia.network(fileUrl(id),
          headers: headers(), mime: ElpianMedia.mimeOfName(src));
    }

    // The project computer's files.
    final path = workspacePathOf(src);
    if (path != null) return _sandbox(path);

    // The node's own URLs.
    final base = baseUrl.replaceFirst(RegExp(r'/$'), '');
    if (src.startsWith('/')) {
      if (src.startsWith('/v1/proxy/') && proxyUrl != null) {
        try {
          return ElpianMedia.network(proxyUrl!(src));
        } catch (_) {}
      }
      return ElpianMedia.network('$base$src', headers: headers());
    }
    if (base.isNotEmpty && src.startsWith('$base/')) {
      return call(src.substring(base.length));
    }
    // Other hosts load as the engine loads them, without the person's
    // credentials.
    return null;
  }

  /// The stored file [src] names, if it names one.
  static String? fileIdOf(String src) {
    final uri = Uri.tryParse(src);
    if (_fileId.hasMatch(src)) return src.toLowerCase();
    for (final prefix in const ['attachment://', 'file://', 'file:']) {
      if (src.toLowerCase().startsWith(prefix)) {
        final rest = src.substring(prefix.length).split(RegExp(r'[/?#]')).first;
        if (_fileId.hasMatch(rest)) return rest.toLowerCase();
      }
    }
    final path = uri?.path ?? src;
    final m = _filePath.firstMatch(path);
    if (m != null && (uri == null || !uri.hasScheme || uri.path == path)) {
      return m.group(1)!.toLowerCase();
    }
    return null;
  }

  /// The project-computer path [src] names (`/workspace/...`), if it names one.
  static String? workspacePathOf(String src) {
    String? path;
    final lower = src.toLowerCase();
    for (final prefix in const [
      'workspace://',
      'sandbox://',
      'computer://',
      'file://',
      'sandbox:',
      'workspace:',
    ]) {
      if (lower.startsWith(prefix)) {
        path = src.substring(prefix.length);
        break;
      }
    }
    if (path == null) {
      if (src.startsWith('/workspace/') || src == '/workspace') {
        path = src;
      } else if (!src.startsWith('/') &&
          !src.startsWith('//') &&
          !_scheme.hasMatch(src) &&
          src.contains('.')) {
        // A relative path: the project's own files.
        path = src.startsWith('./') ? src.substring(2) : src;
      } else {
        return null;
      }
    }
    path = Uri.decodeFull(path.split('#').first.split('?').first);
    if (!path.startsWith('/')) path = '/workspace/$path';
    if (!path.startsWith('/workspace')) path = '/workspace$path';
    if (path.split('/').any((s) => s == '..')) return null;
    return path;
  }

  Future<ElpianMedia> _sandbox(String path) async {
    final pending = _files.remove(path) ??
        readSandbox(path).catchError((Object e) {
          _files.remove(path);
          throw e;
        });
    _files[path] = pending; // most recent last
    while (_files.length > _keep) {
      _files.remove(_files.keys.first)?.ignore();
    }
    final bytes = await pending;
    var mime = ElpianMedia.mimeOfName(path);
    if (mime.isEmpty) mime = ElpianMedia.sniff(bytes);
    return ElpianMedia.memory(bytes, mime: mime);
  }

  @visibleForTesting
  int get cachedFiles => _files.length;
}
