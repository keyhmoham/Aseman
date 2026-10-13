import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tradera/src/core/network/api_client.dart';
import 'package:tradera/src/data/models/space.dart';
import 'package:tradera/src/data/models/uploaded_file.dart';
import 'package:tradera/src/data/services/tradera_service.dart';

class _FileStubClient extends TraderaApiClient {
  _FileStubClient() : super(baseUrl: 'http://localhost:8080');

  final Map<String, dynamic> files = {};
  int seq = 0;

  @override
  Future<ApiResponse> call(
    String namespace,
    String action, {
    Map<String, dynamic> body = const {},
    Duration? requestTimeout,
  }) async {
    switch (action) {
      case 'file_upload':
        final id = 'file-${seq++}';
        final rec = <String, dynamic>{
          'file_id': id,
          'id': id,
          'owner_id': 'me',
          'space_id': body['space'],
          'room_id': body['room'] ?? '',
          'name': body['name'],
          'mime': body['mime'],
          'size': base64Decode(body['data'] as String).length,
          'content_url': '/v1/files/$id/content',
          'created_at': '2026-10-01T00:00:00Z',
        };
        files[id] = rec;
        return ApiResponse(200, rec);
      case 'file_get':
        final id = body['file'] as String? ?? '';
        final rec = Map<String, dynamic>.of(files[id]! as Map<String, dynamic>);
        if (body['with_data'] == true) {
          rec['data'] = base64Encode(utf8.encode('hello world'));
        }
        return ApiResponse(200, rec);
      case 'file_list':
        final list =
            files.values.where((f) => f['space_id'] == body['space']).toList();
        return ApiResponse(200, {'files': list});
      case 'file_delete':
        files.remove(body['file']);
        return const ApiResponse(200, {'ok': true});
      default:
        return const ApiResponse(200, <String, dynamic>{});
    }
  }
}

void main() {
  test('uploadFile stores bytes and returns metadata with content_url',
      () async {
    final client = _FileStubClient();
    final service = TraderaService(client);

    final f = await service.uploadFile(
      'space-1',
      roomId: 'room-1',
      name: 'chart.png',
      mime: 'image/png',
      bytes: Uint8List.fromList([1, 2, 3, 4]),
    );

    expect(f.id, isNotEmpty);
    expect(f.name, 'chart.png');
    expect(f.mime, 'image/png');
    expect(f.size, 4);
    expect(f.spaceId, 'space-1');
    expect(f.roomId, 'room-1');
    expect(f.contentUrl, '/v1/files/${f.id}/content');
    expect(f.isImage, isTrue);
    expect(f.humanSize, '4 B');
  });

  test('downloadFile returns decoded payload', () async {
    final client = _FileStubClient();
    final service = TraderaService(client);
    final f = await service.uploadFile(
      'space-1',
      name: 'notes.txt',
      mime: 'text/plain',
      bytes: Uint8List.fromList([1, 2, 3]),
    );

    final bytes = await service.downloadFile(f.id);
    expect(utf8.decode(bytes), 'hello world');
  });

  test('fetchSpaceFiles lists uploaded files and deleteFile removes them',
      () async {
    final client = _FileStubClient();
    final service = TraderaService(client);
    await service.uploadFile('space-1',
        name: 'a.png', mime: 'image/png', bytes: Uint8List.fromList([1]));
    await service.uploadFile('space-1',
        name: 'b.mp4', mime: 'video/mp4', bytes: Uint8List.fromList([2]));

    final list = await service.fetchSpaceFiles('space-1');
    expect(list, hasLength(2));

    await service.deleteFile(list[0].id);
    final after = await service.fetchSpaceFiles('space-1');
    expect(after, hasLength(1));
  });

  test('RoomMessage.fromJson parses attachment metadata', () {
    final msg = RoomMessage.fromJson({
      'id': 'm1',
      'space_id': 'space-1',
      'room_id': 'room-1',
      'sender_id': 'user-1',
      'body': 'here you go',
      'created_at': '2026-10-01T00:00:00Z',
      'mentions': '[]',
      'attachments': [
        {
          'file_id': 'file-1',
          'id': 'file-1',
          'name': 'report.pdf',
          'mime': 'application/pdf',
          'size': 2048,
          'content_url': '/v1/files/file-1/content',
          'created_at': '2026-10-01T00:00:00Z',
        },
      ],
    });

    expect(msg.attachments, hasLength(1));
    final f = msg.attachments.single;
    expect(f, isA<UploadedFile>());
    expect(f.name, 'report.pdf');
    expect(f.mime, 'application/pdf');
    expect(f.humanSize, '2.0 KB');
    expect(f.extension, 'pdf');
    expect(f.isVideo, isFalse);
    expect(f.isImage, isFalse);
    expect(f.isPlayableAudio, isFalse);
  });
}
