/// Bytes as something a media player opens: a temporary file on devices, a
/// `data:` URI on the web.
library;

export 'media_file_web.dart' if (dart.library.io) 'media_file_io.dart';
