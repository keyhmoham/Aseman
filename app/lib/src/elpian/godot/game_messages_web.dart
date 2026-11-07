/// On the web: a game's browser build, embedded as an iframe, posts its
/// events to the page (`window.parent.postMessage({arena: event}, '*')`).
/// Only messages from the game's own origin are taken.
library;

import 'dart:js_interop';
import 'dart:js_interop_unsafe';

@JS('window')
external JSObject get _window;

void Function()? listenGameMessages(String origin, void Function(Object? event) onEvent) {
  final listener = ((JSObject message) {
    final from = message.getProperty<JSString?>('origin'.toJS)?.toDart ?? '';
    if (origin.isNotEmpty && from != origin) return;
    final data = message.getProperty<JSAny?>('data'.toJS)?.dartify();
    if (data is Map && data.containsKey('arena')) onEvent(data['arena']);
  }).toJS;
  _window.callMethod<JSAny?>('addEventListener'.toJS, 'message'.toJS, listener);
  return () => _window.callMethod<JSAny?>('removeEventListener'.toJS, 'message'.toJS, listener);
}
