import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/layout/breakpoints.dart';
import '../../core/theme/app_colors.dart';
import '../../core/utils/context_extensions.dart';
import '../../data/services/aseman_service.dart';
import '../desk/presentation/desk_controller.dart';
import '../desk/presentation/web_page_view.dart';
import 'space_computer.dart';

/// Below this width the computer opens in a bottom sheet, else as a card
/// window on the desk (the workspace's own breakpoint).
const double computerSheetBreakpoint = Breakpoints.expanded;

/// Opens the project's computer, its desktop live and driven: a card window
/// on the desk on wide screens, a bottom sheet on phones.
Future<void> openComputer(
  BuildContext context,
  AsemanService service,
  String spaceId,
) async {
  final desk = DeskScope.maybeOf(context);
  if (desk != null &&
      MediaQuery.sizeOf(context).width >= computerSheetBreakpoint) {
    await desk.openComputer();
    return;
  }
  await showComputerSheet(context, service: service, spaceId: spaceId);
}

/// The computer in a bottom sheet. Its body is a remote screen, so the
/// sheet is not dragged by it: the handle and the close button dismiss it.
Future<void> showComputerSheet(
  BuildContext context, {
  required AsemanService service,
  required String spaceId,
}) => showModalBottomSheet<void>(
  context: context,
  // Remote screen — opaque bezel, not the frosted app-sheet chrome.
  backgroundColor: const Color(0xFF1B1F25),
  isScrollControlled: true,
  useSafeArea: true,
  enableDrag: false,
  showDragHandle: true,
  clipBehavior: Clip.antiAlias,
  shape: const RoundedRectangleBorder(
    borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
  ),
  builder: (sheet) => FractionallySizedBox(
    heightFactor: .94,
    child: ComputerSession(
      service: service,
      spaceId: spaceId,
      onClose: () => Navigator.of(sheet).pop(),
    ),
  ),
);

/// The colors of a screen: the same in light and dark themes, as a real one.
abstract final class _Screen {
  static const bezel = Color(0xFF1B1F25);
  static const bezelEdge = Color(0xFF2B3038);
  static const glass = Color(0xFF07090C);
  static const glassLit = Color(0xFF0D1117);
  static const text = Color(0x99E8ECEF);
}

Color computerStateColor(ComputerState s, [BuildContext? context]) =>
    switch (s) {
      ComputerState.awake => context != null
          ? AppColors.successOf(context)
          : AppColors.success,
      ComputerState.failed =>
        context != null ? AppColors.dangerOf(context) : AppColors.danger,
      ComputerState.asleep =>
        context != null ? AppColors.warningOf(context) : AppColors.warning,
      ComputerState.none => AppColors.muted,
      _ => context != null ? AppColors.cyanOf(context) : AppColors.cyan,
    };

/// A small light saying what the computer is doing; it breathes while the
/// computer is on its way somewhere.
class ComputerStateLight extends StatefulWidget {
  const ComputerStateLight(this.state, {super.key, this.size = 8});
  final ComputerState state;
  final double size;

  @override
  State<ComputerStateLight> createState() => _ComputerStateLightState();
}

class _ComputerStateLightState extends State<ComputerStateLight>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(ComputerStateLight old) {
    super.didUpdateWidget(old);
    _sync();
  }

  void _sync() {
    if (widget.state.changing) {
      if (!_pulse.isAnimating) _pulse.repeat(reverse: true);
    } else {
      _pulse
        ..stop()
        ..value = 1;
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = computerStateColor(widget.state);
    return FadeTransition(
      opacity: Tween(begin: .35, end: 1.0).animate(_pulse),
      child: Container(
        width: widget.size,
        height: widget.size,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(color: color.withValues(alpha: .55), blurRadius: 6),
          ],
        ),
      ),
    );
  }
}

/// The computer's screen at the top of its tab, drawn as a monitor: the
/// desktop live (looked at, not driven) while it is awake, a dark screen
/// while it sleeps. Tapping it opens the computer.
class ComputerMonitor extends StatelessWidget {
  const ComputerMonitor({super.key, required this.computer, this.onOpen});

  final SpaceComputer computer;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final state = computer.state;
    return Semantics(
      button: onOpen != null,
      label: 'Computer screen, ${state.label}',
      child: GestureDetector(
        onTap: onOpen,
        child: MouseRegion(
          cursor: onOpen == null ? MouseCursor.defer : SystemMouseCursors.click,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.fromLTRB(6, 6, 6, 4),
                decoration: BoxDecoration(
                  color: _Screen.bezel,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: _Screen.bezelEdge),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x33000000),
                      blurRadius: 18,
                      offset: Offset(0, 8),
                    ),
                  ],
                ),
                child: Column(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(9),
                      child: AspectRatio(
                        aspectRatio: 16 / 10,
                        child: AnimatedSwitcher(
                          duration: const Duration(milliseconds: 350),
                          child: _screenFor(state),
                        ),
                      ),
                    ),
                    const SizedBox(height: 4),
                    ComputerStateLight(state, size: 4),
                  ],
                ),
              ),
              // The stand.
              Container(
                width: 30,
                height: 9,
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Color(0xFF14171C), Color(0xFF2A2F37)],
                  ),
                ),
              ),
              Container(
                width: 72,
                height: 4,
                decoration: BoxDecoration(
                  color: _Screen.bezelEdge,
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _screenFor(ComputerState state) {
    if (state == ComputerState.awake) {
      return _LiveDesktop(
        key: const ValueKey('live'),
        computer: computer,
        view: true,
      );
    }
    if (state.changing) {
      return _BusyScreen(key: ValueKey(state), label: state.label);
    }
    return _OffScreen(key: ValueKey(state), state: state);
  }
}

/// A screen that is off: dark glass with the room's reflection on it.
class _OffScreen extends StatelessWidget {
  const _OffScreen({super.key, required this.state, this.action});
  final ComputerState state;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final big = action != null;
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [_Screen.glassLit, _Screen.glass],
        ),
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          // The reflection.
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment(-1, -1),
                end: Alignment(.2, .4),
                colors: [
                  Color(0x14FFFFFF),
                  Color(0x05FFFFFF),
                  Color(0x00FFFFFF),
                ],
                stops: [0, .45, .46],
              ),
            ),
          ),
          Center(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      state == ComputerState.failed
                          ? Icons.error_outline_rounded
                          : Icons.power_settings_new_rounded,
                      size: big ? 40 : 22,
                      color: state == ComputerState.failed
                          ? AppColors.dangerOf(context).withValues(alpha: .7)
                          : const Color(0x40FFFFFF),
                    ),
                    SizedBox(height: big ? 10 : 5),
                    Text(
                      state.label,
                      style: TextStyle(
                        color: _Screen.text,
                        fontSize: big ? 15 : 10,
                        fontWeight: FontWeight.w600,
                        letterSpacing: .2,
                      ),
                    ),
                    if (big) ...[
                      const SizedBox(height: 4),
                      Text(
                        state == ComputerState.none
                            ? 'Wake it to start its desktop.'
                            : 'Its files are kept while it sleeps.',
                        style: const TextStyle(
                          color: Color(0x66E8ECEF),
                          fontSize: 12.5,
                        ),
                      ),
                      const SizedBox(height: 16),
                      action!,
                    ],
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A screen coming on (or going off): dark, with what is happening.
class _BusyScreen extends StatelessWidget {
  const _BusyScreen({super.key, required this.label, this.big = false});
  final String label;
  final bool big;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: _Screen.glass,
    child: Center(
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: big ? 28 : 18,
                height: big ? 28 : 18,
                child: CircularProgressIndicator(
                  strokeWidth: big ? 2.6 : 2,
                  color: AppColors.cyanOf(context),
                  backgroundColor: const Color(0x1AFFFFFF),
                ),
              ),
              SizedBox(height: big ? 14 : 7),
              Text(
                label,
                style: TextStyle(
                  color: _Screen.text,
                  fontSize: big ? 14 : 10,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

/// The desktop of an awake computer: asked for once (which starts it if it
/// is not running), then shown live. [view]: looked at only.
class _LiveDesktop extends StatefulWidget {
  const _LiveDesktop({
    super.key,
    required this.computer,
    this.view = false,
    this.generation = 0,
  });

  final SpaceComputer computer;
  final bool view;

  /// Changed to connect again.
  final int generation;

  @override
  State<_LiveDesktop> createState() => _LiveDesktopState();
}

class _LiveDesktopState extends State<_LiveDesktop> {
  late Future<ComputerDesktop> _desktop = widget.computer.desktop();

  @override
  void didUpdateWidget(_LiveDesktop old) {
    super.didUpdateWidget(old);
    if (old.generation != widget.generation) {
      widget.computer.forgetDesktop();
      _desktop = widget.computer.desktop();
    }
  }

  void _retry() => setState(() {
    widget.computer.forgetDesktop();
    _desktop = widget.computer.desktop();
  });

  @override
  Widget build(BuildContext context) => FutureBuilder<ComputerDesktop>(
    future: _desktop,
    builder: (context, snap) {
      if (snap.hasError) {
        return _DesktopTrouble(
          big: !widget.view,
          message: widget.view
              ? 'Live view unavailable'
              : 'The desktop could not start.\n${_reason(snap.error)}',
          onRetry: _retry,
        );
      }
      final desktop = snap.data;
      if (desktop == null) {
        return _BusyScreen(label: 'Starting the desktop…', big: !widget.view);
      }
      return ColoredBox(
        color: _Screen.glass,
        child: WebPageView(
          key: ValueKey('${desktop.page}#${widget.view}#${widget.generation}'),
          service: widget.computer.service,
          page: desktop.viewer(view: widget.view),
          embed: 'computer',
          showStrip: false,
          interactive: !widget.view,
          claimGestures: !widget.view,
        ),
      );
    },
  );

  static String _reason(Object? e) {
    final text = '$e';
    return text.length > 180 ? '${text.substring(0, 180)}…' : text;
  }
}

class _DesktopTrouble extends StatelessWidget {
  const _DesktopTrouble({
    required this.message,
    required this.onRetry,
    this.big = false,
  });
  final String message;
  final VoidCallback onRetry;
  final bool big;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: _Screen.glass,
    child: Center(
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.desktop_access_disabled_rounded,
                size: big ? 34 : 20,
                color: const Color(0x66FFFFFF),
              ),
              SizedBox(height: big ? 10 : 5),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 360),
                child: Text(
                  message,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: _Screen.text,
                    fontSize: big ? 13 : 10,
                  ),
                ),
              ),
              if (big) ...[
                const SizedBox(height: 14),
                FilledButton.tonalIcon(
                  onPressed: onRetry,
                  icon: const Icon(Icons.refresh_rounded, size: 18),
                  label: const Text('Try again'),
                ),
              ],
            ],
          ),
        ),
      ),
    ),
  );
}

/// The computer's desktop, live and driven: in a desk card window, a
/// bottom sheet (with [onClose]) or full screen. While it is shown the
/// computer counts as in use; asleep, it offers to wake it.
class ComputerSession extends StatefulWidget {
  const ComputerSession({
    super.key,
    required this.service,
    required this.spaceId,
    this.onClose,
    this.fullScreen = false,
  });

  final AsemanService service;
  final String spaceId;

  /// Closes the sheet or screen it is in; a card window has its own.
  final VoidCallback? onClose;
  final bool fullScreen;

  @override
  State<ComputerSession> createState() => _ComputerSessionState();
}

class _ComputerSessionState extends State<ComputerSession> {
  late final SpaceComputer _computer = SpaceComputer.of(
    widget.service,
    widget.spaceId,
  );
  Timer? _keepAlive;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _computer.addListener(_changed);
    _changed();
  }

  @override
  void dispose() {
    _keepAlive?.cancel();
    _computer.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    final awake = _computer.state == ComputerState.awake;
    if (awake && _keepAlive == null) {
      unawaited(_computer.keepAlive());
      _keepAlive = Timer.periodic(
        const Duration(seconds: 45),
        (_) => _computer.keepAlive(),
      );
    } else if (!awake) {
      _keepAlive?.cancel();
      _keepAlive = null;
    }
    if (mounted) setState(() {});
  }

  Future<void> _wake() async {
    try {
      await _computer.wake();
    } catch (e) {
      if (mounted) context.showMessage('The computer did not wake: $e');
    }
  }

  void _reconnect() => setState(() => _generation++);

  void _fullScreen() => Navigator.of(context).push(
    MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (route) => Scaffold(
        backgroundColor: _Screen.glass,
        body: SafeArea(
          child: ComputerSession(
            service: widget.service,
            spaceId: widget.spaceId,
            fullScreen: true,
            onClose: () => Navigator.of(route).pop(),
          ),
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final state = _computer.state;
    final Widget screen;
    if (!_computer.loaded) {
      screen = const _BusyScreen(label: 'Connecting…', big: true);
    } else if (state == ComputerState.awake) {
      screen = _LiveDesktop(computer: _computer, generation: _generation);
    } else if (state.changing) {
      screen = _BusyScreen(key: ValueKey(state), label: state.label, big: true);
    } else {
      screen = _OffScreen(
        key: ValueKey(state),
        state: state,
        action: FilledButton.icon(
          onPressed: _wake,
          icon: const Icon(Icons.power_settings_new_rounded, size: 18),
          label: const Text('Wake up'),
        ),
      );
    }
    return ColoredBox(
      color: _Screen.glass,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _SessionBar(
            state: state,
            showTitle: widget.onClose != null,
            onReconnect: state == ComputerState.awake ? _reconnect : null,
            onFullScreen: widget.fullScreen ? null : _fullScreen,
            onClose: widget.onClose,
          ),
          Expanded(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 300),
              child: KeyedSubtree(
                key: ValueKey(state == ComputerState.awake),
                child: screen,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The session's slim bar: what the computer is doing and the view's
/// controls. In a sheet it also names the computer and closes it.
class _SessionBar extends StatelessWidget {
  const _SessionBar({
    required this.state,
    required this.showTitle,
    this.onReconnect,
    this.onFullScreen,
    this.onClose,
  });

  final ComputerState state;
  final bool showTitle;
  final VoidCallback? onReconnect;
  final VoidCallback? onFullScreen;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    const fg = Color(0xFFE8ECEF);
    final button = IconButton.styleFrom(
      foregroundColor: fg,
      disabledForegroundColor: const Color(0x40E8ECEF),
      visualDensity: VisualDensity.compact,
    );
    return Container(
      height: showTitle ? 52 : 38,
      padding: EdgeInsets.only(left: showTitle ? 16 : 12, right: 4),
      decoration: const BoxDecoration(
        color: _Screen.bezel,
        border: Border(bottom: BorderSide(color: _Screen.bezelEdge)),
      ),
      child: Row(
        children: [
          if (showTitle) ...[
            const Icon(Icons.desktop_windows_rounded, size: 18, color: fg),
            const SizedBox(width: 10),
            const Text(
              'Computer',
              style: TextStyle(
                color: fg,
                fontSize: 15,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(width: 12),
          ],
          ComputerStateLight(state, size: 7),
          const SizedBox(width: 7),
          Flexible(
            child: Text(
              state.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Color(0xB3E8ECEF), fontSize: 12),
            ),
          ),
          const Spacer(),
          IconButton(
            tooltip: 'Reconnect',
            style: button,
            iconSize: 18,
            onPressed: onReconnect,
            icon: const Icon(Icons.refresh_rounded),
          ),
          if (onFullScreen != null)
            IconButton(
              tooltip: 'Full screen',
              style: button,
              iconSize: 18,
              onPressed: onFullScreen,
              icon: const Icon(Icons.fullscreen_rounded),
            ),
          if (onClose != null)
            IconButton(
              tooltip: 'Close',
              style: button,
              iconSize: 18,
              onPressed: onClose,
              icon: const Icon(Icons.close_rounded),
            ),
        ],
      ),
    );
  }
}
