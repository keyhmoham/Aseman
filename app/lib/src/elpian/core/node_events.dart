import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

import '../models/elpian_node.dart';
import 'elpian_services.dart';
import 'event_dispatcher.dart';
import 'event_system.dart';

/// The element id the engine registers a node under — the same id
/// `EventEnabledWidget` uses, so events dispatched by a builder reach the
/// handlers the node declares.
String elementIdOf(ElpianNode node) => node.key ?? 'element_${node.hashCode}';

/// Dispatches a node's events from inside its own builder.
///
/// Captures the dispatcher of the mini app being rendered **at build time**
/// (see [ElpianServices]), so a callback that fires later still reaches the
/// right app.
class NodeEvents {
  NodeEvents(this.node)
      : dispatcher = ElpianServices.current.events,
        id = elementIdOf(node);

  /// Events of [node] dispatched through [dispatcher] under [id] (for nodes
  /// the engine does not render itself, e.g. image-map areas).
  NodeEvents.forDispatcher(this.node, this.dispatcher, this.id);

  final ElpianNode node;
  final EventDispatcher dispatcher;
  final String id;

  /// Whether the node declares a handler for [type].
  bool has(String type) => node.events?.containsKey(type) ?? false;

  /// Whether the node declares a handler for any of [types].
  bool hasAny(Iterable<String> types) => types.any(has);

  static const Map<String, ElpianEventType> _types = {
    'click': ElpianEventType.click,
    'tap': ElpianEventType.tap,
    'doubletap': ElpianEventType.doubleClick,
    'longpress': ElpianEventType.longPress,
    'tapdown': ElpianEventType.tapDown,
    'tapup': ElpianEventType.tapUp,
    'tapcancel': ElpianEventType.tapCancel,
    'pointerenter': ElpianEventType.pointerEnter,
    'pointerexit': ElpianEventType.pointerExit,
    'pointerhover': ElpianEventType.pointerHover,
    'dragstart': ElpianEventType.dragStart,
    'drag': ElpianEventType.drag,
    'dragend': ElpianEventType.dragEnd,
    'dragenter': ElpianEventType.dragEnter,
    'dragleave': ElpianEventType.dragLeave,
    'dragover': ElpianEventType.dragOver,
    'drop': ElpianEventType.drop,
    'focus': ElpianEventType.focus,
    'blur': ElpianEventType.blur,
    'change': ElpianEventType.change,
    'input': ElpianEventType.input,
    'swipeleft': ElpianEventType.swipeLeft,
    'swiperight': ElpianEventType.swipeRight,
    'swipeup': ElpianEventType.swipeUp,
    'swipedown': ElpianEventType.swipeDown,
    'scalestart': ElpianEventType.scaleStart,
    'scaleupdate': ElpianEventType.scaleUpdate,
    'scaleend': ElpianEventType.scaleEnd,
    'pinchstart': ElpianEventType.pinchStart,
    'pinchupdate': ElpianEventType.pinchUpdate,
    'pinchend': ElpianEventType.pinchEnd,
    'rotatestart': ElpianEventType.rotateStart,
    'rotateupdate': ElpianEventType.rotateUpdate,
    'rotateend': ElpianEventType.rotateEnd,
  };

  /// The [ElpianEventType] for an event name ([ElpianEventType.custom] for
  /// names without one).
  static ElpianEventType typeOf(String type) =>
      _types[type] ?? ElpianEventType.custom;

  /// Dispatch a plain event of [type] carrying [data].
  void emit(String type, {Map<String, dynamic> data = const {}}) {
    dispatcher.dispatchEvent(
      ElpianEvent(type: type, eventType: typeOf(type), target: id, data: data),
      id,
    );
  }

  /// Dispatch a positioned event of [type].
  void pointer(
    String type, {
    required Offset position,
    Offset? localPosition,
    Offset delta = Offset.zero,
    Map<String, dynamic> data = const {},
  }) {
    dispatcher.dispatchEvent(
      ElpianPointerEvent(
        type: type,
        eventType: typeOf(type),
        target: id,
        position: position,
        localPosition: localPosition ?? position,
        delta: delta,
        data: data,
      ),
      id,
    );
  }

  /// Dispatch a gesture event of [type].
  void gesture(
    String type, {
    Offset velocity = Offset.zero,
    double scale = 1.0,
    double rotation = 0.0,
    Offset focalPoint = Offset.zero,
    Map<String, dynamic> data = const {},
  }) {
    dispatcher.dispatchEvent(
      ElpianGestureEvent(
        type: type,
        eventType: typeOf(type),
        target: id,
        velocity: velocity,
        scale: scale,
        rotation: rotation,
        focalPoint: focalPoint,
        data: data,
      ),
      id,
    );
  }

  /// A primary activation: `tap` then `click`, so handlers declared under
  /// either name run (as `HtmlButton` does).
  void activate() {
    if (has('tap')) emit('tap');
    dispatcher.dispatchClick(id);
  }

  /// Report the end of a fling as a swipe in its dominant direction, if it
  /// was fast enough and the node listens for that direction.
  void swipe(Velocity velocity, {double minSpeed = 100}) {
    final v = velocity.pixelsPerSecond;
    if (v.distance < minSpeed) return;
    final String type;
    if (v.dx.abs() >= v.dy.abs()) {
      type = v.dx < 0 ? 'swipeleft' : 'swiperight';
    } else {
      type = v.dy < 0 ? 'swipeup' : 'swipedown';
    }
    if (has(type)) gesture(type, velocity: v);
  }

  static Map<String, dynamic> offsetJson(Offset o) => {'x': o.dx, 'y': o.dy};

  /// The touch slop of a node's continuous gestures (drag, scale, a
  /// `pointermove` stream): a quarter of the platform's, so a pan accepts
  /// after 9 px (twice this) — before an ancestor scroll, drawer or page
  /// view (18 px) can take the touch. A stroke that starts on a drawing
  /// surface draws instead of scrolling the page; taps on children still
  /// work (they move less than this).
  static const DeviceGestureSettings claimSettings =
      DeviceGestureSettings(touchSlop: kTouchSlop / 4);

  static const scaleEvents = [
    'scalestart',
    'scaleupdate',
    'scaleend',
    'pinchstart',
    'pinchupdate',
    'pinchend',
    'rotatestart',
    'rotateupdate',
    'rotateend',
  ];
  static const panEvents = ['dragstart', 'drag', 'dragend'];
  static const swipeEvents = ['swipeleft', 'swiperight', 'swipeup', 'swipedown'];
  static const tapEvents = [
    'tap',
    'click',
    'doubletap',
    'longpress',
    'longpressstart',
    'longpressmove',
    'longpressend',
    'tapdown',
    'tapup',
    'tapcancel',
    'secondarytap',
    'contextmenu',
  ];

  /// Whether the node declares an event this detector recognises.
  bool get hasGestures =>
      hasAny(tapEvents) ||
      hasAny(panEvents) ||
      hasAny(scaleEvents) ||
      hasAny(swipeEvents);

  /// Recognises every gesture the node declares an event for and dispatches
  /// it. Only declared gestures are attached, so e.g. a node without
  /// `doubletap` does not delay its taps waiting for a second one, and a
  /// node with only horizontal swipes leaves vertical drags to the list
  /// around it. [alwaysTap] attaches tap even when undeclared (so the tap
  /// still bubbles to ancestors). [taps] false leaves taps (tap, double,
  /// long press, tap down/up, secondary) to a widget that recognises its
  /// own, and attaches only the continuous gestures and swipes.
  ///
  /// Drags and scales claim the touch early ([claimSettings]): they win over
  /// the scrollables, drawers and page views around the node.
  Widget detector(
    Widget child, {
    HitTestBehavior behavior = HitTestBehavior.opaque,
    bool alwaysTap = false,
    bool taps = true,
  }) {
    final usesScale = hasAny(scaleEvents);
    final usesPan = hasAny(panEvents);
    final usesSwipe = hasAny(swipeEvents);
    // Flutter forbids pan and scale recognisers together (scale is a superset
    // of pan); a node with both gets its drags from the scale recogniser.
    final panViaScale = usesScale && usesPan;
    final swipeViaPan = usesSwipe && (usesPan || usesScale);
    final swipeX = !swipeViaPan && hasAny(['swipeleft', 'swiperight']);
    final swipeY = !swipeViaPan && hasAny(['swipeup', 'swipedown']);

    var multiTouch = false;
    var out = child;

    if ((taps && hasAny(tapEvents)) || alwaysTap || swipeX || swipeY) {
      out = GestureDetector(
        behavior: behavior,
        onTap: taps && (alwaysTap || hasAny(['tap', 'click'])) ? activate : null,
        onDoubleTap: taps && has('doubletap') ? () => emit('doubletap') : null,
        onLongPress: taps && has('longpress') ? () => emit('longpress') : null,
        onLongPressStart: taps && has('longpressstart')
            ? (d) => pointer('longpressstart',
                position: d.globalPosition, localPosition: d.localPosition)
            : null,
        onLongPressMoveUpdate: taps && has('longpressmove')
            ? (d) => pointer('longpressmove',
                position: d.globalPosition, localPosition: d.localPosition)
            : null,
        onLongPressEnd: taps && has('longpressend')
            ? (d) => pointer('longpressend',
                position: d.globalPosition, localPosition: d.localPosition)
            : null,
        onTapDown: taps && has('tapdown')
            ? (d) => pointer('tapdown',
                position: d.globalPosition, localPosition: d.localPosition)
            : null,
        onTapUp: taps && has('tapup')
            ? (d) => pointer('tapup',
                position: d.globalPosition, localPosition: d.localPosition)
            : null,
        onTapCancel: taps && has('tapcancel') ? () => emit('tapcancel') : null,
        onSecondaryTapUp: taps && hasAny(['secondarytap', 'contextmenu'])
            ? (d) {
                for (final t in ['secondarytap', 'contextmenu']) {
                  if (has(t)) {
                    pointer(t,
                        position: d.globalPosition,
                        localPosition: d.localPosition);
                  }
                }
              }
            : null,
        onHorizontalDragEnd: swipeX ? (d) => swipe(d.velocity, minSpeed: 1) : null,
        onVerticalDragEnd: swipeY ? (d) => swipe(d.velocity, minSpeed: 1) : null,
        child: out,
      );
    }

    if (usesScale) {
      out = RawGestureDetector(
        behavior: behavior,
        gestures: {
          ScaleGestureRecognizer:
              GestureRecognizerFactoryWithHandlers<ScaleGestureRecognizer>(
            () => ScaleGestureRecognizer(debugOwner: this),
            (r) => r
              ..gestureSettings = claimSettings
              ..dragStartBehavior = DragStartBehavior.down
              ..onStart = (d) {
                multiTouch = d.pointerCount > 1;
                if (has('scalestart')) {
                  gesture('scalestart', focalPoint: d.focalPoint);
                }
                if (multiTouch && has('pinchstart')) {
                  gesture('pinchstart', focalPoint: d.focalPoint);
                }
                if (multiTouch && has('rotatestart')) {
                  gesture('rotatestart', focalPoint: d.focalPoint);
                }
                if (panViaScale && has('dragstart')) {
                  pointer('dragstart',
                      position: d.focalPoint, localPosition: d.localFocalPoint);
                }
              }
              ..onUpdate = (d) {
                if (has('scaleupdate')) {
                  gesture('scaleupdate',
                      scale: d.scale,
                      rotation: d.rotation,
                      focalPoint: d.focalPoint,
                      data: {'localFocalPoint': offsetJson(d.localFocalPoint)});
                }
                if (d.pointerCount > 1) {
                  if (!multiTouch) {
                    multiTouch = true;
                    if (has('pinchstart')) {
                      gesture('pinchstart', focalPoint: d.focalPoint);
                    }
                    if (has('rotatestart')) {
                      gesture('rotatestart', focalPoint: d.focalPoint);
                    }
                  }
                  if (has('pinchupdate')) {
                    gesture('pinchupdate',
                        scale: d.scale, focalPoint: d.focalPoint);
                  }
                  if (has('rotateupdate')) {
                    gesture('rotateupdate',
                        rotation: d.rotation, focalPoint: d.focalPoint);
                  }
                }
                if (panViaScale && has('drag')) {
                  pointer('drag',
                      position: d.focalPoint,
                      localPosition: d.localFocalPoint,
                      delta: d.focalPointDelta);
                }
              }
              ..onEnd = (d) {
                if (has('scaleend')) {
                  gesture('scaleend', velocity: d.velocity.pixelsPerSecond);
                }
                if (multiTouch && has('pinchend')) gesture('pinchend');
                if (multiTouch && has('rotateend')) gesture('rotateend');
                multiTouch = false;
                if (panViaScale && has('dragend')) {
                  pointer('dragend',
                      position: Offset.zero,
                      data: {'velocity': offsetJson(d.velocity.pixelsPerSecond)});
                }
                if (usesSwipe && d.pointerCount == 0) swipe(d.velocity);
              },
          ),
        },
        child: out,
      );
    } else if (usesPan) {
      out = RawGestureDetector(
        behavior: behavior,
        gestures: {
          PanGestureRecognizer:
              GestureRecognizerFactoryWithHandlers<PanGestureRecognizer>(
            () => PanGestureRecognizer(debugOwner: this),
            (r) => r
              ..gestureSettings = claimSettings
              // The stroke starts where the finger went down.
              ..dragStartBehavior = DragStartBehavior.down
              ..onStart = (d) {
                pointer('dragstart',
                    position: d.globalPosition, localPosition: d.localPosition);
              }
              ..onUpdate = (d) {
                pointer('drag',
                    position: d.globalPosition,
                    localPosition: d.localPosition,
                    delta: d.delta);
              }
              ..onEnd = (d) {
                if (has('dragend')) {
                  pointer('dragend',
                      position: d.globalPosition,
                      localPosition: d.localPosition,
                      data: {'velocity': offsetJson(d.velocity.pixelsPerSecond)});
                }
                if (usesSwipe) swipe(d.velocity);
              }
              ..onCancel = has('dragend')
                  ? () {
                      pointer('dragend', position: Offset.zero);
                    }
                  : null,
          ),
        },
        child: out,
      );
    }
    return out;
  }

  /// Claims the touches that start on [child] once they move (by
  /// [claimSettings]), so the scrollables and drawers around it leave them
  /// alone. For nodes that follow raw `pointermove` events (a Listener sees
  /// every move whoever wins, but the page would scroll underneath).
  static Widget claim(Widget child) => RawGestureDetector(
        behavior: HitTestBehavior.translucent,
        gestures: {
          PanGestureRecognizer:
              GestureRecognizerFactoryWithHandlers<PanGestureRecognizer>(
            () => PanGestureRecognizer(debugOwner: 'claim'),
            (r) => r
              ..gestureSettings = claimSettings
              ..onUpdate = (_) {},
          ),
        },
        child: child,
      );
}
