import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter/material.dart';

import 'web_page_handle.dart';

/// Whether pages can show in the app here.
bool get webPageFrameSupported => true;

/// An `<iframe>` showing [url]. It may run scripts, forms, popups and
/// downloads but never navigate the app away; the app's theme reaches it by
/// postMessage.
Widget webPageFrame({
  Key? key,
  required String url,
  required Map<String, dynamic> theme,
  required WebPageStatus onStatus,
  required void Function(WebPageHandle handle) onReady,
  Future<void> Function(Uri url)? openExternal,
}) => _WebPageIframe(
  key: key,
  url: url,
  theme: theme,
  onStatus: onStatus,
  onReady: onReady,
);

class _WebPageIframe extends StatefulWidget {
  const _WebPageIframe({
    super.key,
    required this.url,
    required this.theme,
    required this.onStatus,
    required this.onReady,
  });

  final String url;
  final Map<String, dynamic> theme;
  final WebPageStatus onStatus;
  final void Function(WebPageHandle handle) onReady;

  @override
  State<_WebPageIframe> createState() => _WebPageIframeState();
}

class _WebPageIframeState extends State<_WebPageIframe>
    implements WebPageHandle {
  JSObject? _iframe;
  Map<String, dynamic> _theme = const {};

  void _created(Object element) {
    final iframe = element as JSObject;
    _iframe = iframe;
    _theme = widget.theme;
    iframe.callMethod<JSAny?>(
      'setAttribute'.toJS,
      'sandbox'.toJS,
      'allow-scripts allow-same-origin allow-forms allow-popups allow-popups-to-escape-sandbox allow-modals allow-downloads'
          .toJS,
    );
    iframe.callMethod<JSAny?>(
      'setAttribute'.toJS,
      'allow'.toJS,
      'clipboard-read; clipboard-write; fullscreen; geolocation'.toJS,
    );
    iframe.callMethod<JSAny?>(
      'setAttribute'.toJS,
      'referrerpolicy'.toJS,
      'same-origin'.toJS,
    );
    final style = iframe.getProperty<JSObject>('style'.toJS);
    style
      ..setProperty('width'.toJS, '100%'.toJS)
      ..setProperty('height'.toJS, '100%'.toJS)
      ..setProperty('border'.toJS, 'none'.toJS)
      ..setProperty('display'.toJS, 'block'.toJS)
      ..setProperty('background'.toJS, 'transparent'.toJS);
    iframe.setProperty(
      'onload'.toJS,
      ((JSAny? _) {
        widget.onStatus(loading: false);
        // A new page of the site: it gets the theme again.
        _post(_theme);
      }).toJS,
    );
    iframe.setProperty('src'.toJS, widget.url.toJS);
    widget.onStatus(loading: true);
    widget.onReady(this);
  }

  void _post(Map<String, dynamic> theme) {
    final target = _iframe?.getProperty<JSObject?>('contentWindow'.toJS);
    target?.callMethod<JSAny?>(
      'postMessage'.toJS,
      {'type': 'tradera:theme', ...theme}.jsify(),
      '*'.toJS,
    );
  }

  @override
  Future<void> reload() async {
    widget.onStatus(loading: true);
    _iframe?.setProperty('src'.toJS, widget.url.toJS);
  }

  @override
  void setTheme(Map<String, dynamic> theme) {
    _theme = theme;
    _post(theme);
  }

  @override
  Widget build(BuildContext context) => HtmlElementView.fromTagName(
    tagName: 'iframe',
    onElementCreated: _created,
  );
}
