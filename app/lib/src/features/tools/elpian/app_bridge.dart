import 'dart:async';
import 'dart:convert';

import 'package:file_selector/file_selector.dart';

import '../../../data/services/tradera_service.dart';
import '../../../elpian/elpian.dart';
import 'host_values.dart';

/// Bridges an app's elpian frontend to its backend bot through the user's
/// signed identity.
///
/// An app frontend (dart/JS compiled for the elpian sandbox) calls host
/// APIs that are serviced here:
///
///   * `server.call(name, args)`  → `message.ask` to the bot's backend, waiting
///     for the reply (request/response, user-signed).
///   * `host.request(name, args)` → same as `server.call` (alias).
///   * `host.send(name, args)`    → `message.send` fire-and-forget packet to the
///     backend bot.
///   * `ctx.user()`               → the signed-in user's context (id, handle).
///
/// When a [spaceId] is provided the sandbox bridge is also exposed so an
/// app can drive the space's shared docker sandbox:
///
///   * `sandbox.exec(command)`    → runs a shell command, returns its output.
///   * `sandbox.status()`         → the sandbox bot status.
///   * `sandbox.start()`/`sandbox.stop()`.
///   * `sandbox.write(path, b64)` → decodes base64 and writes it to a file.
///   * `sandbox.read(path)`       → returns a file's text content (capped).
///
/// The backend wasm VM receives the request with the user's identity on every
/// call, so a bot backend can serve per-user data and enforce per-user policy.
class AppHostBridge {
  AppHostBridge(this.service,
      {required this.botId, this.userId = '', this.spaceId = ''});

  final TraderaService service;
  final String botId;
  final String userId;
  final String spaceId;

  Map<String, HostCallHandler> buildHostHandlers() => {
        'server.call': _serverCall,
        'host.request': _serverCall,
        'host.send': _hostSend,
        'ctx.user': _ctxUser,
        'kv.get': _kvGet,
        'kv.set': _kvSet,
        if (spaceId.isNotEmpty) ..._sandboxHandlers(),
      };

  Map<String, HostCallHandler> _sandboxHandlers() => {
        'sandbox.exec': _sandboxExec,
        'sandbox.status': _sandboxStatus,
        'sandbox.start': _sandboxStart,
        'sandbox.stop': _sandboxStop,
        'sandbox.write': _sandboxWrite,
        'sandbox.upload': _sandboxUpload,
        'sandbox.read': _sandboxRead,
      };

  FutureOr<String> _serverCall(String apiName, String payload) async {
    try {
      final decoded = _unwrapArgs(payload);
      final name = decoded.isNotEmpty ? decoded[0].toString() : '';
      final args = decoded.length > 1 ? decoded[1] : <String, dynamic>{};
      final request = jsonEncode({'op': name, 'args': args});
      final reply = await service.askBot(botId, request);
      return _typed('object', _tryDecode(reply));
    } catch (e) {
      return _typed('object', {
        'error': {'code': 'backend_error', 'message': e.toString()},
      });
    }
  }

  FutureOr<String> _hostSend(String apiName, String payload) async {
    try {
      final decoded = _unwrapArgs(payload);
      final name = decoded.isNotEmpty ? decoded[0].toString() : '';
      final args = decoded.length > 1 ? decoded[1] : <String, dynamic>{};
      await service.sendPacket(
        botId,
        name,
        payload: jsonEncode({'op': name, 'args': args}),
      );
      return _typed('object', {'ok': true});
    } catch (e) {
      return _typed('object', {
        'error': {'code': 'backend_error', 'message': e.toString()},
      });
    }
  }

  FutureOr<String> _ctxUser(String apiName, String payload) => _typed(
        'object',
        {
          'id': userId,
          if (service.session != null) 'handle': service.session!.handle,
          if (service.session != null)
            'home_space_id': service.session!.homeSpaceId,
        },
      );

  // ── sandbox bridge (shared per-space docker sandbox) ─────────────────────

  FutureOr<String> _sandboxExec(String apiName, String payload) async {
    try {
      final decoded = _unwrapArgs(payload);
      final command = decoded.isNotEmpty ? decoded[0].toString() : '';
      final out = await service.sandboxExec(spaceId, command);
      return _typed('string', out);
    } catch (e) {
      return _typed('object', {
        'error': {'code': 'sandbox_error', 'message': e.toString()},
      });
    }
  }

  FutureOr<String> _sandboxStatus(String apiName, String payload) async {
    try {
      return _typed('object', await service.sandboxStatus(spaceId));
    } catch (e) {
      return _typed('object', {
        'error': {'code': 'sandbox_error', 'message': e.toString()},
      });
    }
  }

  FutureOr<String> _sandboxStart(String apiName, String payload) async {
    try {
      return _typed('object', await service.sandboxStart(spaceId));
    } catch (e) {
      return _typed('object', {
        'error': {'code': 'sandbox_error', 'message': e.toString()},
      });
    }
  }

  FutureOr<String> _sandboxStop(String apiName, String payload) async {
    try {
      return _typed('object', await service.sandboxStop(spaceId));
    } catch (e) {
      return _typed('object', {
        'error': {'code': 'sandbox_error', 'message': e.toString()},
      });
    }
  }

  FutureOr<String> _sandboxWrite(String apiName, String payload) async {
    try {
      final decoded = _unwrapArgs(payload);
      final path = decoded.isNotEmpty ? decoded[0].toString() : '';
      final b64 = decoded.length > 1 ? decoded[1].toString() : '';
      if (path.isEmpty || b64.isEmpty) {
        return _typed('object', {
          'error': {
            'code': 'invalid_argument',
            'message': 'path and data required'
          },
        });
      }
      final out = await service.sandboxExec(
          spaceId, "printf '%s' '${b64.trim()}' | base64 -d > ${_shq(path)}");
      return _typed('object', {'ok': true, 'output': out});
    } catch (e) {
      return _typed('object', {
        'error': {'code': 'sandbox_error', 'message': e.toString()},
      });
    }
  }

  /// Picks a file on the client (file dialog), base64-encodes it and writes it
  /// into the sandbox at [dir]. Returns the uploaded file name.
  FutureOr<String> _sandboxUpload(String apiName, String payload) async {
    try {
      final decoded = _unwrapArgs(payload);
      final dir = decoded.isNotEmpty ? decoded[0].toString() : '';
      final XFile? picked = await openFile();
      if (picked == null) {
        return _typed('object', {
          'error': {'code': 'cancelled', 'message': 'upload cancelled'},
        });
      }
      final bytes = await picked.readAsBytes();
      final b64 = base64Encode(bytes);
      final target = dir == '/' ? '/${picked.name}' : '$dir/${picked.name}';
      await service.sandboxExec(
          spaceId, "printf '%s' '${b64}' | base64 -d > ${_shq(target)}");
      return _typed(
          'object', {'ok': true, 'name': picked.name, 'size': bytes.length});
    } catch (e) {
      return _typed('object', {
        'error': {'code': 'sandbox_error', 'message': e.toString()},
      });
    }
  }

  FutureOr<String> _sandboxRead(String apiName, String payload) async {
    try {
      final decoded = _unwrapArgs(payload);
      final path = decoded.isNotEmpty ? decoded[0].toString() : '';
      final out = await service.sandboxExec(
          spaceId, 'head -c 16384 ${_shq(path)} 2>&1');
      return _typed('string', out);
    } catch (e) {
      return _typed('object', {
        'error': {'code': 'sandbox_error', 'message': e.toString()},
      });
    }
  }

  /// Single-quotes a value for a POSIX shell (the sandbox runs busybox sh).
  static String _shq(String s) => "'${s.replaceAll("'", "'\\''")}'";

  FutureOr<String> _kvGet(String apiName, String payload) {
    final decoded = _unwrapArgs(payload);
    final key = decoded.isNotEmpty ? decoded[0].toString() : '';
    return _typed('object', {'key': key, 'value': null});
  }

  FutureOr<String> _kvSet(String apiName, String payload) =>
      _typed('object', {'ok': true});

  static List<dynamic> _unwrapArgs(String payload) => HostValues.args(payload);

  static dynamic _tryDecode(String raw) => HostValues.decode(raw);

  static String _typed(String type, dynamic value) =>
      HostValues.reply(type, value);
}
