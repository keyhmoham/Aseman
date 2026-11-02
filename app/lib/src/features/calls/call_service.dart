import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../data/services/aseman_service.dart';

/// Signaling for voice/video calls. Media (WebRTC) runs on native targets via
/// [RtcSession]; the node only exchanges offer / answer / ICE via users.call_*.
class CallService {
  CallService(this.service);

  final AsemanService service;

  /// WebRTC media is gated off on web (stub session); signaling UI still works.
  static bool get mediaSupported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.macOS ||
          defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.linux);

  Timer? _incomingPoll;
  final _incoming = StreamController<Map<String, dynamic>?>.broadcast();

  Stream<Map<String, dynamic>?> get incoming => _incoming.stream;

  void startIncomingPoll({Duration every = const Duration(seconds: 3)}) {
    _incomingPoll?.cancel();
    _incomingPoll = Timer.periodic(every, (_) => _checkIncoming());
    unawaited(_checkIncoming());
  }

  void stopIncomingPoll() {
    _incomingPoll?.cancel();
    _incomingPoll = null;
  }

  Future<void> _checkIncoming() async {
    try {
      final res = await service.callIncoming();
      final call = res['call'];
      _incoming.add(call is Map ? call.cast<String, dynamic>() : null);
    } catch (_) {
      // Ignore transient poll errors.
    }
  }

  Future<Map<String, dynamic>> start(String peerId, {bool video = false}) =>
      service.callStart(peerId, video: video);

  Future<Map<String, dynamic>> accept(String id) => service.callAccept(id);

  Future<Map<String, dynamic>> decline(String id) => service.callDecline(id);

  Future<Map<String, dynamic>> end(String id) => service.callEnd(id);

  Future<Map<String, dynamic>> poll(String id, {String after = ''}) =>
      service.callPoll(id, after: after);

  Future<Map<String, dynamic>> signal(
    String id, {
    required String kind,
    required String payload,
  }) =>
      service.callSignal(id, kind: kind, payload: payload);

  /// ICE servers from a call_start / call_accept / call_poll payload.
  static List<Map<String, dynamic>> iceServersOf(Map<String, dynamic>? res) {
    final raw = res?['ice_servers'];
    if (raw is! List) return const [];
    return [
      for (final s in raw)
        if (s is Map) s.cast<String, dynamic>(),
    ];
  }

  void dispose() {
    stopIncomingPoll();
    unawaited(_incoming.close());
  }
}
