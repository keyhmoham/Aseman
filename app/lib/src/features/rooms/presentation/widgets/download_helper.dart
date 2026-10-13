import 'dart:typed_data';

import 'file_saver_stub.dart' if (dart.library.io) 'file_saver_io.dart';

/// Saves [bytes] under [name] to the platform downloads directory and returns
/// the saved path. Returns an empty string when the platform cannot save (web
/// callers should trigger a browser download via a data:/content URL instead).
Future<String> saveBytes(String name, Uint8List bytes) =>
    fileSaver(name, bytes);
