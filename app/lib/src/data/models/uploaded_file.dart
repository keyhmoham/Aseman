import 'dart:typed_data';

/// A file stored in a space/room, as returned by the spaces.file_* actions.
/// The [contentUrl] is a full URL that streams the raw bytes with the correct
/// Content-Type so media (photos, gifs, audio, voice, video, documents) can be
/// previewed directly by <img>/players without downloading the base64 payload.
class UploadedFile {
  const UploadedFile({
    required this.id,
    required this.name,
    required this.mime,
    required this.size,
    this.ownerId = '',
    this.spaceId = '',
    this.roomId = '',
    this.public = false,
    this.contentUrl = '',
    this.createdAt,
    this.bytes,
  });

  final String id;
  final String name;
  final String mime;
  final int size;
  final String ownerId;
  final String spaceId;
  final String roomId;
  final bool public;
  final String contentUrl;
  final DateTime? createdAt;

  /// Decoded payload when the file was fetched with data (file_get with_data
  /// / file_download).
  final Uint8List? bytes;

  bool get isImage => mime.startsWith('image/');
  bool get isGif => mime == 'image/gif';
  bool get isVideo => mime.startsWith('video/');
  bool get isPlayableAudio => mime.startsWith('audio/');

  /// Voice notes are audio recordings (webm/ogg/mp4/m4a/aac/opus/wav) often
  /// named voice_*/voice-note*; treated as playable audio in-app.
  bool get isVoice =>
      isPlayableAudio &&
      (name.toLowerCase().contains('voice') ||
          name.toLowerCase().contains('voice_note') ||
          ['webm', 'ogg', 'opus', 'm4a', 'aac', 'wav', 'mp4', 'mp3', 'amr']
              .contains(extension));

  String get extension {
    final i = name.lastIndexOf('.');
    return i >= 0 && i + 1 < name.length
        ? name.substring(i + 1).toLowerCase()
        : '';
  }

  String get humanSize {
    if (size >= 1 << 30) return '${(size / (1 << 30)).toStringAsFixed(1)} GB';
    if (size >= 1 << 20) return '${(size / (1 << 20)).toStringAsFixed(1)} MB';
    if (size >= 1 << 10) return '${(size / (1 << 10)).toStringAsFixed(1)} KB';
    return '$size B';
  }

  factory UploadedFile.fromJson(Map<String, dynamic> json) => UploadedFile(
        id: json['file_id'] as String? ?? json['id'] as String? ?? '',
        name: json['name'] as String? ?? '',
        mime: json['mime'] as String? ?? '',
        size: (json['size'] as num?)?.toInt() ?? 0,
        ownerId: json['owner_id'] as String? ?? '',
        spaceId: json['space_id'] as String? ?? '',
        roomId: json['room_id'] as String? ?? '',
        public: json['public'] as bool? ?? false,
        contentUrl: json['content_url'] as String? ?? '',
        createdAt: DateTime.tryParse(json['created_at'] as String? ?? ''),
      );
}
