/// Rendering genui surfaces in Aseman: one surface ([GenUiSurfaceView]) —
/// the app's theme with the surface's `primaryColor`, the agent's name and
/// icon above it — and a set of static messages with a host that answers
/// their actions ([GenUiView]).
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:genui/genui.dart';

import '../../elpian/core/elpian_services.dart';
import '../../elpian/core/media.dart';
import '../runtime/host.dart';
import '../runtime/presentation.dart';
import '../runtime/surfaces.dart';
import 'compact_surface.dart';

/// A user action a surface fired: an A2UI client-to-server `action`.
class GenUiAction {
  const GenUiAction({
    required this.name,
    required this.surfaceId,
    required this.sourceComponentId,
    required this.timestamp,
    this.context = const {},
    this.userMessage,
  });

  factory GenUiAction.fromEvent(UserActionEvent event, String surfaceId) =>
      GenUiAction(
        name: event.name,
        surfaceId: surfaceId,
        sourceComponentId: event.sourceComponentId,
        timestamp: DateTime.tryParse('${event.toMap()['timestamp']}') ??
            DateTime.now(),
        context: Map<String, dynamic>.of(event.context),
        userMessage: event.toMap()['userMessage'] as String?,
      );

  final String name;
  final String surfaceId;
  final String sourceComponentId;
  final DateTime timestamp;
  final Map<String, dynamic> context;

  /// What the person asked for, in words (v1.0 actions).
  final String? userMessage;

  Map<String, dynamic> toJson() => {
        'name': name,
        'surfaceId': surfaceId,
        'sourceComponentId': sourceComponentId,
        'timestamp': timestamp.toUtc().toIso8601String(),
        'context': context,
        if (userMessage != null) 'userMessage': userMessage,
      };
}

/// Sends a surface's user actions to [onAction] (instead of genui's chat
/// submission).
class _ActionDelegate implements ActionDelegate {
  const _ActionDelegate(this.onAction);
  final void Function(GenUiAction action)? onAction;

  @override
  bool handleEvent(BuildContext context, UiEvent event, SurfaceContext surface,
      Widget Function(SurfaceDefinition, Catalog, String, DataContext) _) {
    if (!event.isUserAction) return false;
    onAction?.call(GenUiAction.fromEvent(
        UserActionEvent.fromMap(event.toMap()), surface.surfaceId));
    return true;
  }
}

/// One surface of [surfaces].
class GenUiSurfaceView extends StatelessWidget {
  const GenUiSurfaceView({
    super.key,
    required this.surfaces,
    required this.surfaceId,
    this.onAction,
    this.showAttribution = false,
  });

  final GenUiSurfaces surfaces;
  final String surfaceId;
  final void Function(GenUiAction action)? onAction;

  /// Show the theme's `agentDisplayName` / `iconUrl` above the surface.
  final bool showAttribution;

  @override
  Widget build(BuildContext context) {
    final surface = surfaces.contextFor(surfaceId);
    return ValueListenableBuilder<SurfaceDefinition?>(
      valueListenable: surface.definition,
      builder: (context, definition, _) {
        final theme = definition?.theme ?? const <String, Object?>{};
        Widget out = Surface(
          key: ValueKey(surfaceId),
          surfaceContext: surface,
          actionDelegate: _ActionDelegate(onAction),
        );
        out = _themed(context, theme, out);
        final header = showAttribution ? _attribution(context, theme) : null;
        if (header != null) {
          out = Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [header, out],
          );
        }
        return out;
      },
    );
  }

  static final RegExp _hex = RegExp(r'^#[0-9a-fA-F]{6}$');

  /// The app's theme, with the surface's `primaryColor` when it has one.
  Widget _themed(BuildContext context, Map<String, Object?> theme, Widget child) {
    final primary = theme['primaryColor'];
    if (primary is! String || !_hex.hasMatch(primary)) return child;
    final base = Theme.of(context);
    final color = Color(int.parse('FF${primary.substring(1)}', radix: 16));
    final seeded = ColorScheme.fromSeed(
        seedColor: color, brightness: base.brightness);
    return Theme(
      data: base.copyWith(
        colorScheme: base.colorScheme.copyWith(
          primary: seeded.primary,
          onPrimary: seeded.onPrimary,
          primaryContainer: seeded.primaryContainer,
          onPrimaryContainer: seeded.onPrimaryContainer,
        ),
      ),
      child: child,
    );
  }

  Widget? _attribution(BuildContext context, Map<String, Object?> theme) {
    final name = theme['agentDisplayName'] is String
        ? theme['agentDisplayName'] as String
        : '';
    final icon = theme['iconUrl'] is String &&
            RegExp(r'^https?:|^data:image/', caseSensitive: false)
                .hasMatch(theme['iconUrl'] as String)
        ? theme['iconUrl'] as String
        : '';
    if (name.isEmpty && icon.isEmpty) return null;
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 10),
      child: Row(children: [
        if (icon.isNotEmpty)
          ClipOval(
              child: ElpianMediaImage(
                  src: icon, fit: BoxFit.cover, width: 20, height: 20)),
        if (name.isNotEmpty) ...[
          const SizedBox(width: 8),
          Flexible(
            child: Text(name,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: scheme.onSurfaceVariant)),
          ),
        ],
      ]),
    );
  }
}

/// Answers an action with the surface's new data model (null: unchanged).
typedef GenUiActionHandler = Future<Map<String, dynamic>?> Function(
    GenUiAction action, Map<String, dynamic> dataModel);

/// Renders static A2UI [messages] — a tool's generated frontend, a widget an
/// agent composed. Actions go to [onAction] with the surface's current data
/// model; the data model it returns replaces the surface's.
class GenUiView extends StatefulWidget {
  const GenUiView({
    super.key,
    required this.messages,
    this.onAction,
    this.toolFrontend,
    this.elpianServices,
    this.showAttribution = false,
  });

  final List<Map<String, dynamic>> messages;
  final GenUiActionHandler? onAction;
  final GenUiToolFrontendBuilder? toolFrontend;
  final ElpianServices? elpianServices;
  final bool showAttribution;

  @override
  State<GenUiView> createState() => _GenUiViewState();
}

class _GenUiViewState extends State<GenUiView> {
  late GenUiSurfaces _surfaces;
  StreamSubscription<GenUiProblemReport>? _problems;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    _problems?.cancel();
    _surfaces = GenUiSurfaces()..addListener(_changed);
    _problems = _surfaces.problems.listen((p) {
      if (p.code == 'VALIDATION_FAILED') return; // logged; renders anyway
      if (mounted) setState(() => _error = p.message);
    });
    final problems = _surfaces.ingest(widget.messages);
    _error = problems.isEmpty ? null : problems.first.message;
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(GenUiView old) {
    super.didUpdateWidget(old);
    if (!identical(old.messages, widget.messages)) {
      final previous = _surfaces;
      _load();
      previous
        ..removeListener(_changed)
        ..dispose();
    }
  }

  @override
  void dispose() {
    _problems?.cancel();
    _surfaces
      ..removeListener(_changed)
      ..dispose();
    super.dispose();
  }

  Future<void> _runAction(GenUiAction action) async {
    final run = widget.onAction;
    if (run == null || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final current = _surfaces.dataModel(action.surfaceId);
      final data = await run(
          action,
          current is Map
              ? current.cast<String, dynamic>()
              : <String, dynamic>{});
      if (data != null && mounted) {
        _surfaces.handle({
          'version': 'v0.9',
          'updateDataModel': {
            'surfaceId': action.surfaceId,
            'path': '/',
            'value': data,
          },
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (FrontendPresentation.isCompact(context)) {
      // A phone-board widget: the first surface's compact form.
      final ids = _surfaces.surfaceIds;
      return GenUiHost(
        toolFrontend: widget.toolFrontend,
        elpianServices: widget.elpianServices,
        child: ids.isEmpty
            ? const SizedBox.shrink()
            : GenUiCompactView(
                key: ValueKey('compact:${ids.first}'),
                surfaces: _surfaces,
                surfaceId: ids.first,
                onAction: _runAction),
      );
    }
    return GenUiHost(
      toolFrontend: widget.toolFrontend,
      elpianServices: widget.elpianServices,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_busy)
            const LinearProgressIndicator(minHeight: 2)
          else
            const SizedBox(height: 2),
          for (final id in _surfaces.surfaceIds)
            GenUiSurfaceView(
              key: ValueKey('surface:$id'),
              surfaces: _surfaces,
              surfaceId: id,
              onAction: _runAction,
              showAttribution: widget.showAttribution,
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(_error!,
                  style: TextStyle(fontSize: 12, color: scheme.error)),
            ),
        ],
      ),
    );
  }
}
