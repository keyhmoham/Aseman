/// The frame an MCP App runs in: a sandboxed `<iframe>` on the web, a web
/// view on Android, iOS and macOS.
library;

export 'mcp_app_frame_io.dart'
    if (dart.library.js_interop) 'mcp_app_frame_web.dart';
