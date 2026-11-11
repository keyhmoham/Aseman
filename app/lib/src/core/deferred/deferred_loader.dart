import 'dart:async';

/// Loads a deferred library once. The first [ensure] loads it; once loaded,
/// [ensure] returns synchronously, so code that opens the library's screens
/// does not wait for (or re-enter) the loader again.
///
/// Give each deferred import one loader, kept beside the import, and call
/// the library's members only after [ensure] completed.
class DeferredLoader {
  DeferredLoader(this._load);

  final Future<void> Function() _load;
  Future<void>? _loading;
  bool _loaded = false;

  bool get isLoaded => _loaded;

  /// Null once loaded; otherwise the load in flight (started if need be).
  /// A failed load is forgotten, so the next call tries again.
  Future<void>? ensure() {
    if (_loaded) return null;
    return _loading ??= _load().then(
      (_) {
        _loaded = true;
      },
      onError: (Object error, StackTrace stack) {
        _loading = null;
        Error.throwWithStackTrace(error, stack);
      },
    );
  }
}
