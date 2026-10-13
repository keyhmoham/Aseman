import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

/// Saves [bytes] under [name] in the platform downloads (falling back to the
/// app documents directory) and returns the saved file path.
Future<String> fileSaver(String name, Uint8List bytes) async {
  try {
    Directory? dir = await getDownloadsDirectory();
    dir ??= await getApplicationDocumentsDirectory();
    final safe = name.replaceAll(RegExp(r'[/\\\x00]'), '_');
    final file = File('${dir.path}${Platform.pathSeparator}$safe');
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  } catch (_) {
    return '';
  }
}
