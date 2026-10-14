import 'dart:convert';
import 'dart:typed_data';

import 'package:video_player/video_player.dart';

Uri _data(Uint8List bytes, String mime) => Uri.parse(
    'data:${mime.isEmpty ? 'application/octet-stream' : mime};base64,${base64.encode(bytes)}');

/// A video controller playing [bytes].
Future<VideoPlayerController> videoControllerForBytes(
        Uint8List bytes, String mime) async =>
    VideoPlayerController.networkUrl(_data(bytes, mime));

/// A URI an audio player opens for [bytes].
Future<Uri> mediaUriForBytes(Uint8List bytes, String mime) async =>
    _data(bytes, mime);
