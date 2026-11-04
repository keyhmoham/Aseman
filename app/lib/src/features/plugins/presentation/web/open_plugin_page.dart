/// Opens a web plugin's page in the system browser where the app cannot
/// frame it (Windows and Linux desktops).
library;

export 'open_plugin_page_io.dart'
    if (dart.library.js_interop) 'open_plugin_page_web.dart';
