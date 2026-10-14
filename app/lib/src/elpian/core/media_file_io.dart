import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';

/// A temporary file holding [bytes] (one per content, reused).
Future<File> _temp(Uint8List bytes, String mime) async {
  final dir = Directory('${(await getTemporaryDirectory()).path}/elpian_media');
  if (!dir.existsSync()) dir.createSync(recursive: true);
  final ext =
      mime.contains('/') ? mime.split('/').last.split(';').first : 'bin';
  final file = File('${dir.path}/${sha1.convert(bytes)}.$ext');
  if (!file.existsSync() || file.lengthSync() != bytes.length) {
    await file.writeAsBytes(bytes, flush: true);
  }
  return file;
}

/// A video controller playing [bytes].
Future<VideoPlayerController> videoControllerForBytes(
        Uint8List bytes, String mime) async =>
    VideoPlayerController.file(await _temp(bytes, mime));

/// A URI an audio player opens for [bytes].
Future<Uri> mediaUriForBytes(Uint8List bytes, String mime) async =>
    (await _temp(bytes, mime)).uri;
