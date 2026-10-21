/// An HTML file rendered in the app: a sandboxed `<iframe srcdoc>` on the
/// web, a native web view (flutter_inappwebview) on Android, iOS, macOS and
/// Windows. The page runs isolated from the app: it never shares its origin.
library;

export 'html_preview_io.dart'
    if (dart.library.js_interop) 'html_preview_web.dart';
