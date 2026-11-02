import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

/// Native WebRTC session for a voice or video call.
///
/// ICE servers come from users.call_start / call_accept when present; otherwise
/// public STUN. Signaling (offer / answer / ice) is exchanged via CallService.
class RtcSession {
  RtcSession({this.video = false, List<Map<String, dynamic>>? iceServers})
      : _iceServers = iceServers ?? const [];

  final bool video;
  final List<Map<String, dynamic>> _iceServers;

  RTCPeerConnection? _pc;
  MediaStream? _local;
  final _localRenderer = RTCVideoRenderer();
  final _remoteRenderer = RTCVideoRenderer();
  bool _renderersReady = false;
  bool muted = false;
  bool cameraOff = false;
  bool hasRemote = false;

  /// Invoked for local SDP / ICE that must be sent through call_signal.
  void Function(String kind, String payload)? onLocalSignal;

  bool get mediaAvailable => !kIsWeb;

  Widget? get localView {
    if (!video || !_renderersReady || cameraOff) return null;
    return RTCVideoView(_localRenderer, mirror: true);
  }

  Widget? get remoteView {
    if (!_renderersReady || !hasRemote) return null;
    return RTCVideoView(_remoteRenderer);
  }

  List<Map<String, dynamic>> get _iceConfig {
    if (_iceServers.isNotEmpty) {
      return [
        for (final s in _iceServers)
          {
            'urls': s['urls'] ?? s['url'] ?? const <String>[],
            if (s['username'] != null) 'username': s['username'],
            if (s['credential'] != null) 'credential': s['credential'],
          },
      ];
    }
    return const [
      {
        'urls': [
          'stun:stun.cloudflare.com:3478',
          'stun:stun.l.google.com:19302',
        ],
      },
    ];
  }

  Future<void> startLocal() async {
    if (kIsWeb) {
      throw UnsupportedError(
          'WebRTC media is not available on web (use the mobile or desktop app)');
    }
    await _localRenderer.initialize();
    await _remoteRenderer.initialize();
    _renderersReady = true;

    _local = await navigator.mediaDevices.getUserMedia({
      'audio': true,
      'video': video
          ? {
              'facingMode': 'user',
              'width': 640,
              'height': 480,
            }
          : false,
    });
    _localRenderer.srcObject = _local;

    _pc = await createPeerConnection({
      'iceServers': _iceConfig,
      'sdpSemantics': 'unified-plan',
    });
    _pc!.onIceCandidate = (c) {
      if (c.candidate == null || c.candidate!.isEmpty) return;
      onLocalSignal?.call(
        'ice',
        jsonEncode({
          'candidate': c.candidate,
          'sdpMid': c.sdpMid,
          'sdpMLineIndex': c.sdpMLineIndex,
        }),
      );
    };
    _pc!.onTrack = (ev) {
      if (ev.streams.isEmpty) return;
      _remoteRenderer.srcObject = ev.streams.first;
      hasRemote = true;
    };

    for (final track in _local!.getTracks()) {
      await _pc!.addTrack(track, _local!);
    }
  }

  Future<String> createOffer() async {
    final pc = _pc;
    if (pc == null) throw StateError('call startLocal first');
    final offer = await pc.createOffer({
      'offerToReceiveAudio': 1,
      'offerToReceiveVideo': video ? 1 : 0,
    });
    await pc.setLocalDescription(offer);
    return offer.sdp ?? '';
  }

  Future<String> acceptOffer(String sdp) async {
    final pc = _pc;
    if (pc == null) throw StateError('call startLocal first');
    await pc.setRemoteDescription(RTCSessionDescription(sdp, 'offer'));
    final answer = await pc.createAnswer({
      'offerToReceiveAudio': 1,
      'offerToReceiveVideo': video ? 1 : 0,
    });
    await pc.setLocalDescription(answer);
    return answer.sdp ?? '';
  }

  Future<void> setAnswer(String sdp) async {
    final pc = _pc;
    if (pc == null) throw StateError('call startLocal first');
    await pc.setRemoteDescription(RTCSessionDescription(sdp, 'answer'));
  }

  Future<void> addIce(String candidateJson) async {
    final pc = _pc;
    if (pc == null) return;
    try {
      final m = jsonDecode(candidateJson);
      if (m is! Map) return;
      final candidate = '${m['candidate'] ?? ''}';
      if (candidate.isEmpty) return;
      await pc.addCandidate(RTCIceCandidate(
        candidate,
        m['sdpMid'] as String?,
        (m['sdpMLineIndex'] as num?)?.toInt(),
      ));
    } catch (_) {}
  }

  Future<void> setMuted(bool value) async {
    muted = value;
    for (final t in _local?.getAudioTracks() ?? const []) {
      t.enabled = !value;
    }
  }

  Future<void> setCameraOff(bool value) async {
    cameraOff = value;
    for (final t in _local?.getVideoTracks() ?? const []) {
      t.enabled = !value;
    }
  }

  Future<void> dispose() async {
    onLocalSignal = null;
    try {
      for (final t in _local?.getTracks() ?? const []) {
        await t.stop();
      }
      await _local?.dispose();
    } catch (_) {}
    _local = null;
    try {
      await _pc?.close();
    } catch (_) {}
    _pc = null;
    try {
      await _localRenderer.dispose();
      await _remoteRenderer.dispose();
    } catch (_) {}
    _renderersReady = false;
    hasRemote = false;
  }
}
