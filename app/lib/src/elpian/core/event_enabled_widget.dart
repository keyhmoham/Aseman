import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/elpian_node.dart';
import 'event_system.dart';
import 'event_dispatcher.dart';
import 'elpian_services.dart';
import 'node_events.dart';

/// Wrapper widget that adds event handling capabilities to any widget
class EventEnabledWidget extends StatefulWidget {
  final Widget child;
  final ElpianNode node;
  final String? parentId;

  /// Whether to recognise gestures (taps, drags, swipes, scales) for the
  /// node's events. `false` for widgets that recognise and dispatch all of
  /// their own (see `ElpianEngine.selfGesturingTypes`); the node is still
  /// registered for dispatch, and pointer, hover and keyboard events are
  /// still wired.
  final bool handleGestures;

  /// Whether to recognise taps (tap, double, long press, tap down/up,
  /// secondary). `false` for widgets that recognise their own taps (see
  /// `ElpianEngine.selfDispatchingTypes`) — a second tap recogniser would
  /// fight theirs and report taps twice — while their drags, swipes and
  /// scales still come from here.
  final bool handleTaps;

  /// The dispatcher of the mini app being rendered. Captured when the widget
  /// is built — inside the engine's service scope — because the state mounts
  /// later, outside it, where `ElpianServices.current` is the shared set.
  final EventDispatcher dispatcher;

  EventEnabledWidget({
    Key? key,
    required this.child,
    required this.node,
    this.parentId,
    this.handleGestures = true,
    this.handleTaps = true,
    EventDispatcher? dispatcher,
  })  : dispatcher = dispatcher ?? ElpianServices.current.events,
        super(key: key);

  @override
  State<EventEnabledWidget> createState() => _EventEnabledWidgetState();
}

class _EventEnabledWidgetState extends State<EventEnabledWidget> {
  late final EventDispatcher _dispatcher = widget.dispatcher;
  late String _elementId;
  final FocusNode _focusNode = FocusNode();

  String _resolveElementId(ElpianNode node) {
    return node.key ?? 'element_${node.hashCode}';
  }

  @override
  void initState() {
    super.initState();
    _elementId = _resolveElementId(widget.node);

    // Register node in dispatcher
    _dispatcher.registerNode(_elementId, widget.node,
        parentId: widget.parentId);

    // Setup focus listener
    _focusNode.addListener(_onFocusChange);
  }

  @override
  void didUpdateWidget(EventEnabledWidget oldWidget) {
    super.didUpdateWidget(oldWidget);

    final oldId = _resolveElementId(oldWidget.node);
    final newId = _resolveElementId(widget.node);

    // Reconcile registry if the element id or parent changed, or the node
    // instance changed (new render tree).
    if (oldId != newId ||
        oldWidget.parentId != widget.parentId ||
        oldWidget.node != widget.node) {
      _dispatcher.unregisterNode(oldId, oldWidget.node);
      _dispatcher.registerNode(newId, widget.node, parentId: widget.parentId);
      _elementId = newId;
    }
  }

  @override
  void dispose() {
    _focusNode.removeListener(_onFocusChange);
    _focusNode.dispose();
    _dispatcher.unregisterNode(_elementId, widget.node);
    super.dispose();
  }

  void _onFocusChange() {
    if (_focusNode.hasFocus) {
      _dispatcher.dispatchFocus(_elementId);
    } else {
      _dispatcher.dispatchBlur(_elementId);
    }
  }

  @override
  Widget build(BuildContext context) {
    Widget result = widget.child;

    // Check if node has any events defined
    if (widget.node.events == null || widget.node.events!.isEmpty) {
      return result;
    }

    final events = widget.node.events!;

    // Gestures: taps (unless the widget recognises its own), drags, swipes
    // and scales, through the same detector a GestureDetector node uses.
    final gestures =
        NodeEvents.forDispatcher(widget.node, _dispatcher, _elementId);
    if (widget.handleGestures && gestures.hasGestures) {
      result = gestures.detector(result, taps: widget.handleTaps);
    }

    // Wrap with Listener for pointer events
    if (_hasAnyEvent(events, [
      'pointerdown',
      'pointerup',
      'pointermove',
      'pointercancel',
      'pointerenter',
      'pointerexit',
      'pointerhover',
    ])) {
      result = Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: events.containsKey('pointerdown')
            ? (details) => _dispatcher.dispatchPointerDown(_elementId, details)
            : null,
        onPointerUp: events.containsKey('pointerup')
            ? (details) => _dispatcher.dispatchPointerUp(_elementId, details)
            : null,
        onPointerMove: events.containsKey('pointermove')
            ? (details) => _dispatcher.dispatchPointerMove(_elementId, details)
            : null,
        // The OS can cancel a pointer stream (e.g. a system gesture or the
        // pointer being taken over) without ever firing `up`. Surface it so a
        // consumer like a joystick still resets instead of staying "held".
        onPointerCancel: events.containsKey('pointercancel')
            ? (details) => _dispatcher.dispatchEvent(
                  ElpianPointerEvent(
                    type: 'pointercancel',
                    eventType: ElpianEventType.pointerCancel,
                    target: _elementId,
                    position: details.position,
                    localPosition: details.localPosition,
                    pointerId: details.pointer,
                  ),
                  _elementId,
                )
            : null,
        child: result,
      );
      // Following a pointer's moves: keep the page around from scrolling
      // under it (a drag or scale recogniser already does).
      if (events.containsKey('pointermove') &&
          !gestures.hasAny(NodeEvents.panEvents) &&
          !gestures.hasAny(NodeEvents.scaleEvents)) {
        result = NodeEvents.claim(result);
      }
    }

    // Wrap with MouseRegion for hover events
    if (_hasAnyEvent(events, ['pointerenter', 'pointerexit', 'pointerhover'])) {
      result = MouseRegion(
        onEnter: events.containsKey('pointerenter')
            ? (event) => _dispatcher.dispatchEvent(
                  ElpianPointerEvent(
                    type: 'pointerenter',
                    eventType: ElpianEventType.pointerEnter,
                    target: _elementId,
                    position: event.position,
                    localPosition: event.localPosition,
                  ),
                  _elementId,
                )
            : null,
        onExit: events.containsKey('pointerexit')
            ? (event) => _dispatcher.dispatchEvent(
                  ElpianPointerEvent(
                    type: 'pointerexit',
                    eventType: ElpianEventType.pointerExit,
                    target: _elementId,
                    position: event.position,
                    localPosition: event.localPosition,
                  ),
                  _elementId,
                )
            : null,
        onHover: events.containsKey('pointerhover')
            ? (event) => _dispatcher.dispatchEvent(
                  ElpianPointerEvent(
                    type: 'pointerhover',
                    eventType: ElpianEventType.pointerHover,
                    target: _elementId,
                    position: event.position,
                    localPosition: event.localPosition,
                  ),
                  _elementId,
                )
            : null,
        child: result,
      );
    }

    // Wrap with Focus for keyboard events
    if (_hasAnyEvent(events, ['focus', 'blur', 'keydown', 'keyup'])) {
      result = Focus(
        focusNode: _focusNode,
        onKeyEvent: _hasAnyEvent(events, ['keydown', 'keyup'])
            ? (node, event) {
                if (event is KeyDownEvent && events.containsKey('keydown')) {
                  _dispatcher.dispatchKeyDown(
                    _elementId,
                    event.logicalKey.keyLabel,
                    event.logicalKey.keyId,
                  );
                  return KeyEventResult.handled;
                }
                if (event is KeyUpEvent && events.containsKey('keyup')) {
                  _dispatcher.dispatchKeyUp(
                    _elementId,
                    event.logicalKey.keyLabel,
                    event.logicalKey.keyId,
                  );
                  return KeyEventResult.handled;
                }
                return KeyEventResult.ignored;
              }
            : null,
        child: result,
      );
    }

    return result;
  }

  bool _hasAnyEvent(Map<String, dynamic> events, List<String> eventNames) {
    return eventNames.any((name) => events.containsKey(name));
  }
}

/// Extension to easily wrap widgets with event handling
extension EventExtension on Widget {
  Widget withEvents(ElpianNode node, {String? parentId}) {
    return EventEnabledWidget(
      node: node,
      parentId: parentId,
      child: this,
    );
  }
}
