import 'dart:typed_data';

/// Web has no writable filesystem; return an empty path so the caller triggers
/// a browser download instead.
Future<String> fileSaver(String name, Uint8List bytes) async => '';
