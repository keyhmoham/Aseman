/// The frame a web page runs in on the desk: an `<iframe>` on the web, a
/// native web view (flutter_inappwebview) on Android, iOS, macOS and Windows.
library;

export 'web_page_frame_io.dart'
    if (dart.library.js_interop) 'web_page_frame_web.dart';
export 'web_page_handle.dart';
