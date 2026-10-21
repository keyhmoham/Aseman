import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter/material.dart';

/// Whether HTML can be rendered in the app here.
bool get htmlPreviewSupported => true;

/// [html] in an `<iframe srcdoc>`. Its scripts, forms and popups run, but
/// without `allow-same-origin` the page has an opaque origin: it cannot
/// read the app's storage or call the node as the person.
Widget htmlPreview({Key? key, required String html}) =>
    _HtmlIframe(key: key, html: html);

class _HtmlIframe extends StatelessWidget {
  const _HtmlIframe({super.key, required this.html});
  final String html;

  void _created(Object element) {
    final iframe = element as JSObject;
    iframe.callMethod<JSAny?>(
      'setAttribute'.toJS,
      'sandbox'.toJS,
      'allow-scripts allow-forms allow-popups allow-modals'.toJS,
    );
    iframe.callMethod<JSAny?>(
      'setAttribute'.toJS,
      'referrerpolicy'.toJS,
      'no-referrer'.toJS,
    );
    iframe.getProperty<JSObject>('style'.toJS)
      ..setProperty('width'.toJS, '100%'.toJS)
      ..setProperty('height'.toJS, '100%'.toJS)
      ..setProperty('border'.toJS, 'none'.toJS)
      ..setProperty('display'.toJS, 'block'.toJS)
      ..setProperty('background'.toJS, 'white'.toJS);
    iframe.setProperty('srcdoc'.toJS, html.toJS);
  }

  @override
  Widget build(BuildContext context) => HtmlElementView.fromTagName(
    tagName: 'iframe',
    onElementCreated: _created,
  );
}
