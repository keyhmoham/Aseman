import 'package:flutter/widgets.dart';

/// Web / unsupported target: no native WebRTC plugin. Methods throw clearly.
class RtcSession {
  RtcSession({this.video = false, List<Map<String, dynamic>>? iceServers});

  final bool video;
  bool get mediaAvailable => false;
  bool muted = false;
  bool cameraOff = false;
  bool get hasRemote => false;

  Widget? get localView => null;
  Widget? get remoteView => null;

  static const _msg =
      'WebRTC media is not available on this platform (use the mobile or desktop app)';

  Future<void> startLocal() async => throw UnsupportedError(_msg);

  Future<String> createOffer() async => throw UnsupportedError(_msg);

  Future<String> acceptOffer(String sdp) async => throw UnsupportedError(_msg);

  Future<void> setAnswer(String sdp) async => throw UnsupportedError(_msg);

  Future<void> addIce(String candidateJson) async =>
      throw UnsupportedError(_msg);

  void Function(String kind, String payload)? onLocalSignal;

  Future<void> setMuted(bool value) async {
    muted = value;
  }

  Future<void> setCameraOff(bool value) async {
    cameraOff = value;
  }

  Future<void> dispose() async {}
}
