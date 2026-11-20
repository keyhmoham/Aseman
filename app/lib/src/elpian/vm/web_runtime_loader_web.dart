import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'web_runtime_assets.dart';

Future<void>? _loading;

/// Dynamically imports the Elpian WASM loader and QuickJS runtime modules,
/// then runs [ensureElpianWasm] so `@JS('elpian_wasm_*')` symbols exist.
Future<void> ensureElpianWebRuntimes() => _loading ??= _ensure();

Future<void> _ensure() async {
  await Future.wait([
    for (final asset in ElpianWebRuntimeAssets.all)
      _importModule(ElpianWebRuntimeAssets.url(asset)),
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
  // `import()` takes a URL or a specifier starting with "./", "../" or "/": a
  // path like "assets/assets/elpian/…" is a bare specifier and the browser
  // rejects it ("was not remapped to anything"). So the page-relative [url]
  // is resolved against the document's base URI (the `<base href>` Flutter
  // writes) into a full URL first, which also holds when the app is served
  // from a sub-path.
  final promise = globalContext.callMethod(
    'eval'.toJS,
    'import(new URL(${_jsString(url)}, document.baseURI).href)'.toJS,
  );
  if (promise == null || !promise.isA<JSPromise>()) {
    throw StateError('Failed to start dynamic import for $url');
  }
  await (promise as JSPromise).toDart;
}

String _jsString(String value) =>
    '"${value.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';
