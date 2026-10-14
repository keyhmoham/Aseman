import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../../elpian/elpian.dart';
import '../domain/tool_models.dart';
import '../ui_kit/kit.dart' show registerUiKit;
import 'a2ui_catalog.dart';
import 'a2ui_normalize.dart';

export 'a2ui_catalog.dart' show traderaCatalog, toolFrontendNodeType;

/// Builds the embedded frontend of [botId] at [height].
/// [shown]: the result to open it on, when an agent showed one.
typedef ToolFrontendBuilder = Widget Function(
    BuildContext context, String botId, double height, ShownResult? shown);

/// Renders A2UI messages — a tool's generated frontend, or a widget an agent
/// composed — with Elpian's A2UI renderer and engine. Buttons' events go to
/// [onAction] with the surface's current data model; what it returns (a new
/// data model) is shown. `ToolFrontend` components are drawn by
/// [toolFrontend].
class A2UIView extends StatefulWidget {
  const A2UIView({
    super.key,
    required this.messages,
    this.onAction,
    this.toolFrontend,
  });

  final List<Map<String, dynamic>> messages;
  final Future<Map<String, dynamic>?> Function(
      A2UIClientAction action, Map<String, dynamic> data)? onAction;
  final ToolFrontendBuilder? toolFrontend;

  @override
  State<A2UIView> createState() => _A2UIViewState();
}

class _A2UIViewState extends State<A2UIView> {
  late A2UIConversation _conversation;
  late ElpianEngine _engine;
  VoidCallback? _unsubscribe;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _engine = ElpianEngine();
    registerUiKit(_engine);
    _engine.registerWidget(toolFrontendNodeType, (node, children) {
      final props = node.props;
      final tool = '${props['tool'] ?? ''}';
      final height = (props['height'] as num?)?.toDouble() ?? 320;
      return Builder(
          builder: (context) =>
              widget.toolFrontend
                  ?.call(context, tool, height, ShownResult.fromProps(props)) ??
              SizedBox(height: height));
    });
    _load();
  }

  void _load() {
    _unsubscribe?.call();
    _conversation =
        A2UIConversation(processor: A2UIProcessor(catalogs: [traderaCatalog]));
    _unsubscribe = _conversation.on(_onEvent);
    _conversation.ingest(normalizeA2uiMessages(widget.messages));
  }

  @override
  void didUpdateWidget(A2UIView old) {
    super.didUpdateWidget(old);
    if (!identical(old.messages, widget.messages)) _load();
  }

  @override
  void dispose() {
    _unsubscribe?.call();
    _conversation.dispose();
    super.dispose();
  }

  void _refresh() {
    if (!mounted) return;
    final phase = SchedulerBinding.instance.schedulerPhase;
    if (phase == SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() {});
      });
    } else {
      setState(() {});
    }
  }

  void _onEvent(A2UIConversationEvent e) {
    switch (e.type) {
      case 'action':
        _runAction(e.action!);
      case 'error':
        _error = e.message;
        _refresh();
      default:
        _refresh();
    }
  }

  Future<void> _runAction(A2UIClientAction action) async {
    final run = widget.onAction;
    if (run == null || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final current = _conversation.dataModel(action.surfaceId);
      final data = await run(
          action,
          current is Map
              ? current.cast<String, dynamic>()
              : <String, dynamic>{});
      if (data != null) {
        _conversation.ingest([
          {
            'version': 'v0.9',
            'updateDataModel': {
              'surfaceId': action.surfaceId,
              'path': '/',
              'value': data,
            },
          }
        ]);
      }
    } catch (e) {
      _error = e.toString();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Map<String, dynamic> _lowerToolFrontend(
          Map<String, dynamic> component, String key, A2UICustomContext ctx) =>
      {
        'type': toolFrontendNodeType,
        'key': key,
        'props': {
          'tool': component['tool'],
          'height': component['height'],
          'microtool': ctx.resolve(component['microtool']),
          'args': ctx.resolve(component['args']),
        },
      };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hooks = _conversation.loweringHooks(_refresh);
    final surfaces = [
      for (final surface in _conversation.processor.surfaces)
        lowerSurface(
          surface,
          LoweringOptions(
            hooks: hooks,
            state: _conversation.ui,
            keyPrefix: 'tradera',
            showAttribution: false,
            dark: Theme.of(context).brightness == Brightness.dark,
            customComponents: {
              ...traderaLowerings(),
              'ToolFrontend': _lowerToolFrontend,
            },
          ),
        ).node,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_busy) const LinearProgressIndicator(minHeight: 2),
        for (final node in surfaces) _engine.renderFromJson(node),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(_error!,
                style: TextStyle(fontSize: 12, color: scheme.error)),
          ),
      ],
    );
  }
}
