/// The window a person signs in to an MCP tool's provider in: a popup on the
/// web (the provider sends it back to /oauth.html), an in-app web view that
/// catches the redirect on Android, iOS, macOS and Windows, and the browser
/// with the returned address pasted back elsewhere.
library;

export 'oauth_window_io.dart'
    if (dart.library.js_interop) 'oauth_window_web.dart';
