import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter/material.dart';

/// Builds the frame running [html]: messages the app posts reach
/// [onMessage]; [onReady] gets the function that posts to the app.
Widget mcpAppFrame({
  Key? key,
  required String html,
  required void Function(Object? message) onMessage,
  required void Function(void Function(Map<String, dynamic>) send) onReady,
}) =>
    _McpAppIframe(key: key, html: html, onMessage: onMessage, onReady: onReady);

/// Whether apps can run here.
bool get mcpAppFrameSupported => true;

@JS('window')
external JSObject get _window;

class _McpAppIframe extends StatefulWidget {
  const _McpAppIframe(
      {super.key,
      required this.html,
      required this.onMessage,
      required this.onReady});

  final String html;
  final void Function(Object? message) onMessage;
  final void Function(void Function(Map<String, dynamic>) send) onReady;

  @override
  State<_McpAppIframe> createState() => _McpAppIframeState();
}

class _McpAppIframeState extends State<_McpAppIframe> {
  JSObject? _iframe;
  JSFunction? _listener;

  @override
  void dispose() {
    final listener = _listener;
    if (listener != null) {
      _window.callMethod<JSAny?>(
          'removeEventListener'.toJS, 'message'.toJS, listener);
    }
    super.dispose();
  }

  void _created(Object element) {
    final iframe = element as JSObject;
    _iframe = iframe;
    // An opaque origin: the app cannot reach this page, its storage or its
    // credentials; it talks to the host only by messages.
    iframe.callMethod<JSAny?>(
        'setAttribute'.toJS,
        'sandbox'.toJS,
        'allow-scripts allow-forms allow-popups allow-popups-to-escape-sandbox allow-downloads allow-modals'
            .toJS);
    iframe.callMethod<JSAny?>(
        'setAttribute'.toJS, 'allow'.toJS, 'clipboard-write'.toJS);
    final style = iframe.getProperty<JSObject>('style'.toJS);
    style
      ..setProperty('width'.toJS, '100%'.toJS)
      ..setProperty('height'.toJS, '100%'.toJS)
      ..setProperty('border'.toJS, 'none'.toJS)
      ..setProperty('display'.toJS, 'block'.toJS)
      ..setProperty('background'.toJS, 'transparent'.toJS);
    final listener = ((JSObject event) {
      final source = event.getProperty<JSAny?>('source'.toJS);
      final own = _iframe?.getProperty<JSAny?>('contentWindow'.toJS);
      if (own == null || source == null || !source.strictEquals(own).toDart) {
        return;
      }
      widget.onMessage(event.getProperty<JSAny?>('data'.toJS).dartify());
    }).toJS;
    _listener = listener;
    _window.callMethod<JSAny?>(
        'addEventListener'.toJS, 'message'.toJS, listener);
    iframe.setProperty('srcdoc'.toJS, widget.html.toJS);
    widget.onReady((message) {
      final target = _iframe?.getProperty<JSObject?>('contentWindow'.toJS);
      target?.callMethod<JSAny?>('postMessage'.toJS, message.jsify(), '*'.toJS);
    });
  }

  @override
  Widget build(BuildContext context) => HtmlElementView.fromTagName(
      tagName: 'iframe', onElementCreated: _created);
}
