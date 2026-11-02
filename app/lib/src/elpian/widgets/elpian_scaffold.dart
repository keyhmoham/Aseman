import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../core/event_enabled_widget.dart';
import '../core/node_events.dart';
import '../models/elpian_node.dart';
import 'elpian_expressive.dart';
import 'elpian_icon.dart';

/// `Scaffold`: the Material page structure, with every slot filled from
/// children.
///
/// A child goes into a slot by `props.slot` or by its type:
///
/// | slot                     | or type                         |
/// |--------------------------|---------------------------------|
/// | `appBar`                 | `AppBar`                        |
/// | `body`                   | (anything else; the last wins,  |
/// |                          | several unslotted → a column)   |
/// | `drawer`                 | `Drawer`                        |
/// | `endDrawer`              |                                 |
/// | `floatingActionButton`   | `FloatingActionButton`          |
/// | `bottomNavigationBar`    | `BottomNavigationBar`, `NavigationBar` (also `bottomBar`) |
/// | `bottomSheet`            |                                 |
/// | `persistentFooterButtons`| (each such child is one button) |
///
/// Props: `floatingActionButtonLocation` (`endFloat`, `centerFloat`,
/// `startFloat`, `endDocked`, `centerDocked`, `startDocked`, `endTop`,
/// `startTop`, `centerTop`, `miniEndFloat`, …), `extendBody`,
/// `extendBodyBehindAppBar`, `resizeToAvoidBottomInset`, `primary`,
/// `drawerEnableOpenDragGesture`, `endDrawerEnableOpenDragGesture`.
/// `style.backgroundColor` colours the page.
///
/// Events: `drawerchange` / `enddrawerchange` with `{open}`.
class ElpianScaffold {
  static Widget build(ElpianNode node, List<Widget> children) {
    PreferredSizeWidget? appBar;
    Widget? drawer;
    Widget? endDrawer;
    Widget? fab;
    Widget? bottomNavigationBar;
    Widget? bottomSheet;
    Widget? explicitBody;
    final footerButtons = <Widget>[];
    final body = <Widget>[];

    for (var i = 0; i < node.children.length && i < children.length; i++) {
      final childNode = node.children[i];
      final widget = children[i];
      final slot = childNode.props['slot']?.toString();
      switch (slot ?? childNode.type) {
        case 'appBar':
        case 'AppBar':
          appBar = preferredSized(widget, childNode);
          break;
        case 'drawer':
        case 'Drawer':
          drawer = _asDrawer(widget, childNode);
          break;
        case 'endDrawer':
          endDrawer = _asDrawer(widget, childNode);
          break;
        case 'floatingActionButton':
        case 'FloatingActionButton':
        case 'FAB':
          fab = widget;
          break;
        case 'bottomNavigationBar':
        case 'bottomBar':
        case 'BottomNavigationBar':
        case 'NavigationBar':
          bottomNavigationBar = widget;
          break;
        case 'bottomSheet':
          bottomSheet = widget;
          break;
        case 'persistentFooterButtons':
        case 'persistentFooterButton':
          footerButtons.add(widget);
          break;
        case 'body':
          explicitBody = widget;
          break;
        default:
          body.add(widget);
      }
    }

    final Widget? bodyWidget = explicitBody ??
        (body.isEmpty
            ? null
            : body.length == 1
                ? body.first
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: body,
                  ));

    final e = NodeEvents(node);
    bool flag(String key, bool fallback) {
      final v = node.props[key];
      return v is bool ? v : fallback;
    }

    return Scaffold(
      appBar: appBar,
      body: bodyWidget,
      drawer: drawer,
      endDrawer: endDrawer,
      floatingActionButton: fab,
      floatingActionButtonLocation:
          _fabLocation(node.props['floatingActionButtonLocation']),
      bottomNavigationBar: bottomNavigationBar,
      bottomSheet: bottomSheet,
      persistentFooterButtons: footerButtons.isEmpty ? null : footerButtons,
      backgroundColor: node.style?.backgroundColor,
      extendBody: flag('extendBody', false),
      extendBodyBehindAppBar: flag('extendBodyBehindAppBar', false),
      resizeToAvoidBottomInset: node.props['resizeToAvoidBottomInset'] is bool
          ? node.props['resizeToAvoidBottomInset'] as bool
          : null,
      primary: flag('primary', true),
      drawerEnableOpenDragGesture: flag('drawerEnableOpenDragGesture', true),
      endDrawerEnableOpenDragGesture:
          flag('endDrawerEnableOpenDragGesture', true),
      onDrawerChanged: e.has('drawerchange')
          ? (open) => e.emit('drawerchange', data: {'open': open})
          : null,
      onEndDrawerChanged: e.has('enddrawerchange')
          ? (open) => e.emit('enddrawerchange', data: {'open': open})
          : null,
    );
  }

  /// [widget] as the [PreferredSizeWidget] a Scaffold's `appBar` slot needs.
  ///
  /// The engine may have wrapped the built AppBar (a [KeyedSubtree] for a
  /// keyed node, an [EventEnabledWidget] for one with events); its size is
  /// read from the AppBar inside, and the wrapper is kept.
  static PreferredSizeWidget preferredSized(Widget widget, ElpianNode node,
      {double fallbackHeight = kToolbarHeight}) {
    if (widget is PreferredSizeWidget) return widget;
    Widget? inner = widget;
    while (inner != null && inner is! PreferredSizeWidget) {
      inner = switch (inner) {
        KeyedSubtree(:final child) => child,
        EventEnabledWidget(:final child) => child,
        _ => null,
      };
    }
    final size = inner is PreferredSizeWidget
        ? inner.preferredSize
        : Size.fromHeight(node.style?.height ?? fallbackHeight);
    return PreferredSize(preferredSize: size, child: widget);
  }

  static Widget _asDrawer(Widget widget, ElpianNode node) {
    if (node.type == 'Drawer' || widget is Drawer) return widget;
    return Drawer(child: widget);
  }

  static FloatingActionButtonLocation? _fabLocation(Object? name) =>
      switch (name) {
        'endFloat' => FloatingActionButtonLocation.endFloat,
        'centerFloat' => FloatingActionButtonLocation.centerFloat,
        'startFloat' => FloatingActionButtonLocation.startFloat,
        'endDocked' => FloatingActionButtonLocation.endDocked,
        'centerDocked' => FloatingActionButtonLocation.centerDocked,
        'startDocked' => FloatingActionButtonLocation.startDocked,
        'endTop' => FloatingActionButtonLocation.endTop,
        'centerTop' => FloatingActionButtonLocation.centerTop,
        'startTop' => FloatingActionButtonLocation.startTop,
        'miniEndFloat' => FloatingActionButtonLocation.miniEndFloat,
        'miniCenterFloat' => FloatingActionButtonLocation.miniCenterFloat,
        'miniStartFloat' => FloatingActionButtonLocation.miniStartFloat,
        'miniEndDocked' => FloatingActionButtonLocation.miniEndDocked,
        'miniCenterDocked' => FloatingActionButtonLocation.miniCenterDocked,
        'miniStartDocked' => FloatingActionButtonLocation.miniStartDocked,
        'miniEndTop' => FloatingActionButtonLocation.miniEndTop,
        'miniStartTop' => FloatingActionButtonLocation.miniStartTop,
        'endContained' => FloatingActionButtonLocation.endContained,
        _ => null,
      };
}

/// `Drawer`: a Material navigation drawer around its children (a column).
/// `style.backgroundColor` and `style.width` apply; `props.elevation`.
class ElpianDrawer {
  static Widget build(ElpianNode node, List<Widget> children) {
    final content = children.length == 1
        ? children.first
        : ListView(padding: EdgeInsets.zero, children: children);
    return Drawer(
      backgroundColor: node.style?.backgroundColor,
      width: node.style?.width,
      elevation: sizeProp(node, 'elevation')?.toDouble(),
      child: content,
    );
  }
}

/// `FloatingActionButton` (also `FAB`): dispatches `tap`/`click` when
/// pressed.
///
/// Content: the children, else `props.icon` (a Material icon name, default
/// `add`) and `props.text`/`label` (with a label it is the extended FAB).
/// Props: `size` — `small`, `medium` (default), `large`; `variant` —
/// `primary` (default: primary container), `secondary`, `tertiary`,
/// `surface`; `tooltip`, `elevation`, `heroTag`, `disabled`.
/// `style.backgroundColor` and `style.color` colour it.
class ElpianFloatingActionButton {
  static Widget build(ElpianNode node, List<Widget> children) {
    final e = NodeEvents(node);
    final label = (node.props['label'] ?? node.props['text'])?.toString();
    final enabled = node.props['disabled'] != true;
    final onPressed = enabled ? e.activate : null;
    final tooltip = node.props['tooltip']?.toString();
    final elevation = sizeProp(node, 'elevation')?.toDouble();
    final heroTag = node.props['heroTag'] ?? 'fab:${e.id}';
    final size =
        '${node.props['size'] ?? (node.props['mini'] == true ? 'small' : 'medium')}';

    return Builder(
      builder: (context) {
        final scheme = Theme.of(context).colorScheme;
        final fabTheme = Theme.of(context).floatingActionButtonTheme;
        // Default matches app soft-mist FAB theme. `filled` stays saturated.
        final (Color bg, Color fg) = switch (node.props['variant']) {
          'secondary' => (
            scheme.secondaryContainer,
            scheme.onSecondaryContainer,
          ),
          'tertiary' => (scheme.tertiaryContainer, scheme.onTertiaryContainer),
          'surface' => (scheme.surfaceContainerHigh, scheme.primary),
          'filled' => (scheme.primary, scheme.onPrimary),
          _ => (
            fabTheme.backgroundColor ?? AppFab.mistOf(scheme),
            fabTheme.foregroundColor ?? AppFab.inkOf(scheme),
          ),
        };
        final background = node.style?.backgroundColor ?? bg;
        final foreground = node.style?.color ?? fg;
        final mistShape = fabTheme.shape ?? AppFab.shapeOf(scheme);
        final iconSize = switch (size) {
          'large' => 36.0,
          'small' => 20.0,
          _ => 24.0,
        };
        final icon = children.isNotEmpty
            ? (children.length == 1
                  ? children.first
                  : Row(mainAxisSize: MainAxisSize.min, children: children))
            : Icon(
                ElpianIcon.iconData('${node.props['icon'] ?? 'add'}') ??
                    Icons.add,
                size: iconSize,
              );

        if (label != null && label.isNotEmpty) {
          return ExpressivePress(
            enabled: enabled,
            child: FloatingActionButton.extended(
              onPressed: onPressed,
              backgroundColor: background,
              foregroundColor: foreground,
              tooltip: tooltip,
              elevation: elevation ?? 0,
              heroTag: heroTag,
              shape: mistShape,
              icon: icon,
              label: Text(
                label,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
          );
        }
        final Widget fab = switch (size) {
          'large' => FloatingActionButton.large(
            onPressed: onPressed,
            backgroundColor: background,
            foregroundColor: foreground,
            tooltip: tooltip,
            elevation: elevation ?? 0,
            heroTag: heroTag,
            shape: mistShape,
            child: icon,
          ),
          'small' => FloatingActionButton.small(
            onPressed: onPressed,
            backgroundColor: background,
            foregroundColor: foreground,
            tooltip: tooltip,
            elevation: elevation ?? 0,
            heroTag: heroTag,
            shape: mistShape,
            child: icon,
          ),
          _ => FloatingActionButton(
            onPressed: onPressed,
            backgroundColor: background,
            foregroundColor: foreground,
            tooltip: tooltip,
            elevation: elevation ?? 0,
            heroTag: heroTag,
            shape: mistShape,
            child: icon,
          ),
        };
        return ExpressivePress(enabled: enabled, child: fab);
      },
    );
  }
}
