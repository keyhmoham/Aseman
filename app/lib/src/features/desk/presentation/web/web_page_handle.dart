/// What the desk does with a web page's frame once it is up.
abstract class WebPageHandle {
  /// Loads the page again.
  Future<void> reload();

  /// Sends the app's theme to the page (Aseman's web UI kit follows it).
  void setTheme(Map<String, dynamic> theme);
}

/// Called by a frame as it loads ([error] when the page could not load).
typedef WebPageStatus = void Function({bool loading, String? error});
