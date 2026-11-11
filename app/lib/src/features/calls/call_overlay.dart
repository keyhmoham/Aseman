import 'dart:async';

import 'package:flutter/material.dart';

import '../../app_dependencies.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_shape.dart';
import '../../core/theme/theme_chrome.dart';
import '../../core/theme/theme_roles.dart';
import '../../core/theme/theme_ui_spec.dart';
import '../../shared/widgets/avatar_face.dart';
import '../../shared/widgets/sky_ui.dart';
import '../../shared/widgets/theme_slot_host.dart';
import 'call_page.dart' deferred as call_page;
import 'call_service.dart';
import '../../core/deferred/deferred_loader.dart';

/// The call screen, loaded when a call is first answered.
final _callPage = DeferredLoader(() => call_page.loadLibrary());

/// Loads the screen an answered call opens.
Future<void> loadIncomingCallScreen() async => _callPage.ensure();

/// Host wrapper that polls for incoming calls while signed in and shows an
/// Accept / Decline banner when one is ringing.
class CallOverlay extends StatefulWidget {
  const CallOverlay({
    super.key,
    required this.dependencies,
    required this.child,
  });

  final AppDependencies dependencies;
  final Widget child;

  @override
  State<CallOverlay> createState() => _CallOverlayState();
}

class _CallOverlayState extends State<CallOverlay> {
  late final CallService _calls =
      CallService(widget.dependencies.service);
  StreamSubscription<Map<String, dynamic>?>? _sub;
  Map<String, dynamic>? _ringing;
  bool _opening = false;

  @override
  void initState() {
    super.initState();
    _calls.startIncomingPoll();
    _sub = _calls.incoming.listen(_onIncoming);
  }

  @override
  void dispose() {
    _sub?.cancel();
    _calls.dispose();
    super.dispose();
  }

  void _onIncoming(Map<String, dynamic>? call) {
    if (!mounted) return;
    final id = '${call?['id'] ?? ''}';
    final state = '${call?['state'] ?? ''}';
    if (call == null || id.isEmpty || state != 'ringing') {
      if (_ringing != null) setState(() => _ringing = null);
      return;
    }
    if ('${_ringing?['id'] ?? ''}' == id) return;
    setState(() => _ringing = call);
  }

  String get _peerLabel {
    final caller = _ringing?['caller'];
    if (caller is Map) {
      final name = '${caller['display_name'] ?? ''}'.trim();
      if (name.isNotEmpty) return name;
      final handle = '${caller['handle'] ?? ''}'.trim();
      if (handle.isNotEmpty) return '@$handle';
    }
    final id = '${_ringing?['caller_id'] ?? ''}';
    return id.isEmpty ? 'Incoming call' : id;
  }

  Future<void> _decline() async {
    final id = '${_ringing?['id'] ?? ''}';
    setState(() => _ringing = null);
    if (id.isEmpty) return;
    try {
      await _calls.decline(id);
    } catch (_) {}
  }

  Future<void> _accept() async {
    if (_opening) return;
    final call = _ringing;
    final id = '${call?['id'] ?? ''}';
    if (call == null || id.isEmpty) return;
    final label = _peerLabel;
    setState(() {
      _opening = true;
      _ringing = null;
    });
    try {
      final res = await _calls.accept(id);
      if (!mounted) return;
      final video = call['video'] == true ||
          (res['call'] is Map && (res['call'] as Map)['video'] == true);
      await _callPage.ensure();
      if (!mounted) return;
      await call_page.CallPage.open(
        context,
        dependencies: widget.dependencies,
        callId: id,
        peerLabel: _peerLabelFrom(res) ?? label,
        video: video,
        incoming: true,
        initialCall: (res['call'] is Map
            ? (res['call'] as Map).cast<String, dynamic>()
            : call),
        iceServers: CallService.iceServersOf(res),
        alreadyAccepted: true,
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Could not answer: $e')));
      }
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  String? _peerLabelFrom(Map<String, dynamic> res) {
    final caller = res['caller'];
    if (caller is! Map) return null;
    final name = '${caller['display_name'] ?? ''}'.trim();
    if (name.isNotEmpty) return name;
    final handle = '${caller['handle'] ?? ''}'.trim();
    return handle.isEmpty ? null : '@$handle';
  }

  @override
  Widget build(BuildContext context) {
    final ringing = _ringing;
    final video = ringing?['video'] == true;
    final scheme = Theme.of(context).colorScheme;
    return Stack(
      fit: StackFit.expand,
      children: [
        widget.child,
        if (ringing != null)
          Positioned(
            left: 12,
            right: 12,
            top: MediaQuery.paddingOf(context).top + 8,
            child: ThemeSlotHost(
              slot: ThemeChromeSlots.callOverlay,
              child: Material(
                elevation: 6,
                borderRadius: AppShape.borderRadius(context, 16),
                color: scheme.surfaceContainerHighest,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
                  child: Row(
                    children: [
                      Builder(builder: (context) {
                        const radius = 20.0;
                        final size = radius * 2;
                        final corners = context.avatarBorderRadius(size);
                        return HaloRing(
                          borderRadius: corners,
                          child: AvatarFace(
                            size: size,
                            borderRadius: corners,
                            backgroundColor: ThemeRoles.wellFill(context),
                            child: Icon(
                              video
                                  ? Icons.videocam_rounded
                                  : Icons.call_rounded,
                              color: ThemeRoles.wellInk(context),
                            ),
                          ),
                        );
                      }),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(_peerLabel,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    fontWeight: FontWeight.w800, fontSize: 15)),
                            Text(
                              video
                                  ? 'Incoming video call'
                                  : 'Incoming voice call',
                              style: TextStyle(
                                  fontSize: 12,
                                  color: scheme.onSurfaceVariant),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        tooltip: 'Decline',
                        onPressed: _opening ? null : _decline,
                        style: IconButton.styleFrom(
                          backgroundColor: scheme.errorContainer,
                          foregroundColor: scheme.onErrorContainer,
                        ),
                        icon: const Icon(Icons.call_end_rounded),
                      ),
                      const SizedBox(width: 6),
                      IconButton(
                        tooltip: 'Accept',
                        onPressed: _opening ? null : _accept,
                        style: IconButton.styleFrom(
                          backgroundColor: AppColors.successOf(context),
                          foregroundColor: scheme.onPrimary,
                        ),
                        icon: Icon(video
                            ? Icons.videocam_rounded
                            : Icons.call_rounded),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
