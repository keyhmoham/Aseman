import 'dart:async';

import 'package:flutter/material.dart';

import '../../app_dependencies.dart';
import '../../shared/widgets/sky_ui.dart';
import 'call_service.dart';
import 'rtc_session.dart';

/// Full-screen call UI: ringing / active / ended with WebRTC media when
/// [CallService.mediaSupported].
class CallPage extends StatefulWidget {
  const CallPage({
    super.key,
    required this.dependencies,
    required this.callId,
    required this.peerLabel,
    this.video = false,
    this.incoming = false,
    this.initialCall,
    this.iceServers = const [],
    this.alreadyAccepted = false,
  });

  final AppDependencies dependencies;
  final String callId;
  final String peerLabel;
  final bool video;
  final bool incoming;
  final Map<String, dynamic>? initialCall;
  final List<Map<String, dynamic>> iceServers;

  /// True when Accept already ran (e.g. from [CallOverlay]).
  final bool alreadyAccepted;

  static Future<void> open(
    BuildContext context, {
    required AppDependencies dependencies,
    required String callId,
    required String peerLabel,
    bool video = false,
    bool incoming = false,
    Map<String, dynamic>? initialCall,
    List<Map<String, dynamic>> iceServers = const [],
    bool alreadyAccepted = false,
  }) {
    return Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => CallPage(
          dependencies: dependencies,
          callId: callId,
          peerLabel: peerLabel,
          video: video,
          incoming: incoming,
          initialCall: initialCall,
          iceServers: iceServers,
          alreadyAccepted: alreadyAccepted,
        ),
      ),
    );
  }

  @override
  State<CallPage> createState() => _CallPageState();
}

class _CallPageState extends State<CallPage> {
  late final CallService _calls =
      CallService(widget.dependencies.service);
  Timer? _poll;
  String _state = 'ringing';
  String _status = 'Connecting…';
  String _after = '';
  bool _busy = false;
  bool _mediaStarted = false;
  bool _offerSent = false;
  bool _answerSet = false;
  final _seenSignals = <String>{};
  List<Map<String, dynamic>> _iceServers = const [];
  RtcSession? _rtc;
  bool _muted = false;
  bool _cameraOff = false;

  bool get _isCaller => !widget.incoming;

  @override
  void initState() {
    super.initState();
    _iceServers = widget.iceServers;
    final call = widget.initialCall;
    if (call != null) {
      _state = '${call['state'] ?? 'ringing'}';
    }
    if (widget.alreadyAccepted) {
      _state = 'active';
    }
    _status = widget.incoming
        ? (widget.video ? 'Incoming video call' : 'Incoming voice call')
        : 'Calling…';
    final every = CallService.mediaSupported
        ? const Duration(seconds: 1)
        : const Duration(seconds: 2);
    _poll = Timer.periodic(every, (_) => _tick());
    unawaited(_tick());
    if (widget.alreadyAccepted && CallService.mediaSupported) {
      unawaited(_ensureMedia());
    }
  }

  @override
  void dispose() {
    _poll?.cancel();
    unawaited(_rtc?.dispose() ?? Future<void>.value());
    _calls.dispose();
    super.dispose();
  }

  Future<void> _ensureMedia() async {
    if (_mediaStarted || !CallService.mediaSupported) return;
    _mediaStarted = true;
    final session = RtcSession(video: widget.video, iceServers: _iceServers);
    session.onLocalSignal = (kind, payload) {
      unawaited(_calls
          .signal(widget.callId, kind: kind, payload: payload)
          .then((_) {}, onError: (_) {}));
    };
    try {
      await session.startLocal();
      if (!mounted) {
        await session.dispose();
        return;
      }
      setState(() => _rtc = session);
      if (_isCaller && _state == 'active') {
        await _sendOffer();
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _status = 'Media unavailable: $e';
        });
      }
      await session.dispose();
    }
  }

  Future<void> _sendOffer() async {
    final rtc = _rtc;
    if (rtc == null || _offerSent || !_isCaller) return;
    _offerSent = true;
    try {
      final sdp = await rtc.createOffer();
      await _calls.signal(widget.callId, kind: 'offer', payload: sdp);
      if (mounted) setState(() => _status = 'Connecting…');
    } catch (e) {
      _offerSent = false;
      if (mounted) setState(() => _status = 'Offer failed: $e');
    }
  }

  Future<void> _handleSignal(Map<dynamic, dynamic> signal) async {
    final id = '${signal['id'] ?? ''}';
    if (id.isNotEmpty) {
      if (_seenSignals.contains(id)) return;
      _seenSignals.add(id);
      _after = id;
    }
    final kind = '${signal['kind'] ?? ''}';
    final payload = '${signal['payload'] ?? ''}';
    if (payload.isEmpty) return;
    final rtc = _rtc;
    if (rtc == null) return;
    try {
      switch (kind) {
        case 'offer':
          if (_isCaller) return;
          final answer = await rtc.acceptOffer(payload);
          await _calls.signal(widget.callId,
              kind: 'answer', payload: answer);
          if (mounted) {
            setState(() => _status =
                widget.video ? 'Video connected' : 'Voice connected');
          }
        case 'answer':
          if (!_isCaller || _answerSet) return;
          _answerSet = true;
          await rtc.setAnswer(payload);
          if (mounted) {
            setState(() => _status =
                widget.video ? 'Video connected' : 'Voice connected');
          }
        case 'ice':
          await rtc.addIce(payload);
      }
    } catch (e) {
      if (mounted) setState(() => _status = 'Signal error: $e');
    }
  }

  Future<void> _tick() async {
    try {
      final res = await _calls.poll(widget.callId, after: _after);
      if (!mounted) return;
      final servers = CallService.iceServersOf(res);
      if (servers.isNotEmpty && _iceServers.isEmpty) {
        _iceServers = servers;
      }
      final call = res['call'];
      if (call is Map) {
        final state = '${call['state'] ?? ''}';
        if (state.isNotEmpty) _state = state;
        if (state == 'ended') {
          _status = call['end_reason'] == null
              ? 'Call ended'
              : 'Call ended (${call['end_reason']})';
          _poll?.cancel();
          await _rtc?.dispose();
          _rtc = null;
        } else if (state == 'active') {
          if (CallService.mediaSupported) {
            await _ensureMedia();
            if (_isCaller) await _sendOffer();
            _status = _status.startsWith('Video') ||
                    _status.startsWith('Voice')
                ? _status
                : (widget.video ? 'Video connecting…' : 'Voice connecting…');
          } else {
            _status = 'Connected (signaling only on this platform)';
          }
        }
      }
      final signals = res['signals'];
      if (signals is List) {
        for (final s in signals) {
          if (s is Map) await _handleSignal(s);
        }
      }
      setState(() {});
    } catch (_) {}
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _hangUp({required bool decline}) async {
    try {
      if (decline) {
        await _calls.decline(widget.callId);
      } else {
        await _calls.end(widget.callId);
      }
    } finally {
      await _rtc?.dispose();
      _rtc = null;
      if (mounted) Navigator.of(context).maybePop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final ended = _state == 'ended';
    final ringing = _state == 'ringing';
    final rtc = _rtc;
    final remote = rtc?.remoteView;
    final local = rtc?.localView;
    return Scaffold(
      backgroundColor: scheme.surface,
      body: SafeArea(
        child: Column(
          children: [
            Align(
              alignment: Alignment.topRight,
              child: IconButton(
                tooltip: 'Close',
                onPressed: ended
                    ? () => Navigator.of(context).maybePop()
                    : () => _run(() => _hangUp(decline: false)),
                icon: const Icon(Icons.close_rounded),
              ),
            ),
            Expanded(
              child: widget.video &&
                      CallService.mediaSupported &&
                      _state == 'active'
                  ? Stack(
                      fit: StackFit.expand,
                      children: [
                        Positioned.fill(
                          child: remote ??
                              ColoredBox(
                                color: scheme.surfaceContainerHighest,
                                child: Center(
                                  child: Text(_status,
                                      style: TextStyle(
                                          color: scheme.onSurfaceVariant)),
                                ),
                              ),
                        ),
                        if (local != null)
                          Positioned(
                            right: 16,
                            bottom: 16,
                            width: 112,
                            height: 160,
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(12),
                              child: ColoredBox(
                                color: Colors.black87,
                                child: local,
                              ),
                            ),
                          ),
                      ],
                    )
                  : Column(
                      children: [
                        const Spacer(),
                        HaloRing(
                          pad: 3,
                          child: CircleAvatar(
                            radius: 48,
                            backgroundColor: scheme.primaryContainer,
                            child: Icon(
                              widget.video
                                  ? Icons.videocam_rounded
                                  : Icons.call_rounded,
                              size: 40,
                              color: scheme.onPrimaryContainer,
                            ),
                          ),
                        ),
                        const SizedBox(height: 20),
                        Text(widget.peerLabel,
                            style: const TextStyle(
                                fontSize: 24, fontWeight: FontWeight.w800)),
                        const SizedBox(height: 8),
                        Text(_status,
                            style: TextStyle(
                                color: scheme.onSurfaceVariant)),
                        if (!CallService.mediaSupported) ...[
                          const SizedBox(height: 12),
                          Text('Media runs on the mobile/desktop app.',
                              style: TextStyle(
                                  fontSize: 12,
                                  color: scheme.onSurfaceVariant)),
                        ],
                        const Spacer(),
                      ],
                    ),
            ),
            if (_state == 'active' && CallService.mediaSupported)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _RoundAction(
                      color: _muted
                          ? scheme.secondary
                          : scheme.surfaceContainerHighest,
                      icon: _muted
                          ? Icons.mic_off_rounded
                          : Icons.mic_rounded,
                      label: _muted ? 'Unmute' : 'Mute',
                      onPressed: () async {
                        final next = !_muted;
                        await _rtc?.setMuted(next);
                        setState(() => _muted = next);
                      },
                    ),
                    if (widget.video) ...[
                      const SizedBox(width: 24),
                      _RoundAction(
                        color: _cameraOff
                            ? scheme.secondary
                            : scheme.surfaceContainerHighest,
                        icon: _cameraOff
                            ? Icons.videocam_off_rounded
                            : Icons.videocam_rounded,
                        label: _cameraOff ? 'Camera' : 'Camera off',
                        onPressed: () async {
                          final next = !_cameraOff;
                          await _rtc?.setCameraOff(next);
                          setState(() => _cameraOff = next);
                        },
                      ),
                    ],
                  ],
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 36),
              child: ended
                  ? FilledButton(
                      onPressed: () => Navigator.of(context).maybePop(),
                      child: const Text('Done'))
                  : Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        if (widget.incoming &&
                            ringing &&
                            !widget.alreadyAccepted) ...[
                          _RoundAction(
                            color: scheme.error,
                            icon: Icons.call_end_rounded,
                            label: 'Decline',
                            onPressed: _busy
                                ? null
                                : () => _run(() => _hangUp(decline: true)),
                          ),
                          const SizedBox(width: 36),
                          _RoundAction(
                            color: Colors.green,
                            icon: Icons.call_rounded,
                            label: 'Accept',
                            onPressed: _busy
                                ? null
                                : () => _run(() async {
                                      final res = await _calls
                                          .accept(widget.callId);
                                      final ice =
                                          CallService.iceServersOf(res);
                                      if (ice.isNotEmpty) {
                                        _iceServers = ice;
                                      }
                                      setState(() {
                                        _state = 'active';
                                        _status = 'Connected';
                                      });
                                      await _ensureMedia();
                                    }),
                          ),
                        ] else
                          _RoundAction(
                            color: scheme.error,
                            icon: Icons.call_end_rounded,
                            label: 'End',
                            onPressed: _busy
                                ? null
                                : () =>
                                    _run(() => _hangUp(decline: false)),
                          ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RoundAction extends StatelessWidget {
  const _RoundAction({
    required this.color,
    required this.icon,
    required this.label,
    this.onPressed,
  });
  final Color color;
  final IconData icon;
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final on = ThemeData.estimateBrightnessForColor(color) == Brightness.dark
        ? Colors.white
        : Colors.black87;
    return Column(
      children: [
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: color,
            foregroundColor: on,
            shape: const CircleBorder(),
            padding: const EdgeInsets.all(18),
          ),
          onPressed: onPressed,
          child: Icon(icon, size: 28),
        ),
        const SizedBox(height: 8),
        Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
      ],
    );
  }
}

/// Starts a call to [peerId] and opens [CallPage].
Future<void> startDirectCall(
  BuildContext context,
  AppDependencies dependencies, {
  required String peerId,
  required String peerLabel,
  bool video = false,
}) async {
  try {
    final res =
        await CallService(dependencies.service).start(peerId, video: video);
    final call = res['call'];
    if (call is! Map || !context.mounted) return;
    final id = '${call['id'] ?? ''}';
    if (id.isEmpty) return;
    await CallPage.open(
      context,
      dependencies: dependencies,
      callId: id,
      peerLabel: peerLabel,
      video: video,
      initialCall: call.cast<String, dynamic>(),
      iceServers: CallService.iceServersOf(res),
    );
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Call failed: $e')));
    }
  }
}
