/// Ensures Elpian WASM + QuickJS browser runtimes are available.
///
/// On native/stub targets this is a no-op. On web the module scripts are
/// imported the first time an Elpian/QuickJS guest starts, keeping them off
/// the Flutter bootstrap critical path.
export 'web_runtime_loader_stub.dart'
    if (dart.library.js_interop) 'web_runtime_loader_web.dart';
