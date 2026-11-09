import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

/// Same-origin module URLs (Flutter asset catalog nests under `assets/`).
const _wasmLoader =
    'assets/assets/elpian/web_runtime/elpian_wasm_loader.js';
const _quickJsRuntime =
    'assets/assets/elpian/web_runtime/quickjs_web_runtime.js';

Future<void>? _loading;

/// Dynamically imports the Elpian WASM loader and QuickJS runtime modules,
/// then runs [ensureElpianWasm] so `@JS('elpian_wasm_*')` symbols exist.
Future<void> ensureElpianWebRuntimes() => _loading ??= _ensure();

Future<void> _ensure() async {
  await Future.wait([
    _importModule(_wasmLoader),
    _importModule(_quickJsRuntime),
  ]);

  final ensure = globalContext.getProperty('ensureElpianWasm'.toJS);
  if (ensure != null) {
    final result = (ensure as JSFunction).callAsFunction();
    if (result != null && result.isA<JSPromise>()) {
      await (result as JSPromise).toDart;
    }
  }
}

Future<void> _importModule(String url) async {
  // Dynamic import via eval keeps us on dart:js_interop without package:web.
  final promise = globalContext.callMethod(
    'eval'.toJS,
    'import(${_jsString(url)})'.toJS,
  );
  if (promise == null || !promise.isA<JSPromise>()) {
    throw StateError('Failed to start dynamic import for $url');
  }
  await (promise as JSPromise).toDart;
}

String _jsString(String value) =>
    '"${value.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';
