import 'dart:async';

import 'package:flutter/material.dart';

import 'desk_controller.dart';

/// The content of a window whose interface the node designs for one request
/// (a tool without a generative frontend of its own): while it is designed,
/// what it is being designed for; if the design failed, why, and a way to try
/// again; once ready, the window's own design, built by [ready].
class DesignedWindowContent extends StatefulWidget {
  const DesignedWindowContent({
    super.key,
    required this.windowId,
    required this.request,
    required this.template,
    required this.status,
    required this.ready,
    this.controller,
  });

  final String windowId;
  final String request;
  final Map<String, dynamic> template;
  final String status;
  final Widget Function(Map<String, dynamic> template) ready;

  /// Offers designing again (absent in previews).
  final DeskController? controller;

  /// A design still under way after this long is offered again (the node
  /// may have restarted meanwhile).
  static const stale = Duration(seconds: 90);

  @override
  State<DesignedWindowContent> createState() => _DesignedWindowContentState();
}

class _DesignedWindowContentState extends State<DesignedWindowContent>
    with SingleTickerProviderStateMixin {
  // Made in initState, not lazily: a window that never showed its pulse
  // would otherwise make it in dispose(), off the tree.
  late final AnimationController _pulse;
  Timer? _stale;
  bool _late = false;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1400))
      ..repeat(reverse: true);
    _watch();
  }

  @override
  void didUpdateWidget(DesignedWindowContent old) {
    super.didUpdateWidget(old);
    if (old.status != widget.status) _watch();
  }

  void _watch() {
    _stale?.cancel();
    _late = false;
    if (_designing) {
      _stale = Timer(DesignedWindowContent.stale, () {
        if (mounted) setState(() => _late = true);
      });
    }
  }

  bool get _designing =>
      widget.template.isEmpty && !widget.status.startsWith('failed');

  @override
  void dispose() {
    _stale?.cancel();
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    if (widget.template.isNotEmpty) return widget.ready(widget.template);
    final failed = widget.status.startsWith('failed');
    final request = widget.request.trim();
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          if (failed)
            Icon(Icons.error_outline_rounded, size: 36, color: scheme.error)
          else
            FadeTransition(
              opacity: Tween(begin: .35, end: 1.0).animate(_pulse),
              child: ScaleTransition(
                scale: Tween(begin: .9, end: 1.05).animate(
                    CurvedAnimation(parent: _pulse, curve: Curves.easeInOut)),
                child: Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                      color: scheme.primaryContainer,
                      borderRadius: BorderRadius.circular(18)),
                  child: Icon(Icons.auto_awesome_rounded,
                      color: scheme.onPrimaryContainer),
                ),
              ),
            ),
          const SizedBox(height: 14),
          Text(
              failed
                  ? 'This window could not be designed'
                  : 'Designing this window for your request…',
              textAlign: TextAlign.center,
              style: text.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
          if (request.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text('“$request”',
                textAlign: TextAlign.center,
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
                style: text.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                    fontStyle: FontStyle.italic)),
          ],
          if (failed) ...[
            const SizedBox(height: 8),
            Text(widget.status.replaceFirst('failed: ', ''),
                textAlign: TextAlign.center,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: text.bodySmall?.copyWith(color: scheme.error)),
          ],
          if ((failed || _late) && widget.controller != null) ...[
            const SizedBox(height: 14),
            FilledButton.tonalIcon(
              onPressed: () => widget.controller!.redesign(widget.windowId),
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: Text(failed ? 'Try again' : 'Start over'),
            ),
          ],
        ]),
      ),
    );
  }
}
