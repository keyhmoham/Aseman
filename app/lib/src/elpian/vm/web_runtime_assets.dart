/// The web runtimes the Elpian VM and QuickJS need in a browser: ES modules
/// shipped as app assets (`pubspec.yaml`) and imported on first use by
/// `web_runtime_loader_web.dart`, so the page does not load them up front.
abstract final class ElpianWebRuntimeAssets {
  /// The asset paths, as `pubspec.yaml` declares them.
  static const wasmLoader = 'assets/elpian/web_runtime/elpian_wasm_loader.js';
  static const quickJsRuntime =
      'assets/elpian/web_runtime/quickjs_web_runtime.js';

  static const all = [wasmLoader, quickJsRuntime];

  /// Where a Flutter web build serves an asset, relative to the page (the
  /// build nests the asset catalog under `assets/`).
  static String url(String asset) => 'assets/$asset';
}
