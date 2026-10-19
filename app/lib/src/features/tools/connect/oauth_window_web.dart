import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter/widgets.dart';

@JS('window')
external JSObject get _window;

/// Where the provider sends the browser back: this site's /oauth.html, which
/// hands the address to the window that opened it.
String oauthRedirectUri(String apiBaseUrl) => '${Uri.base.origin}/oauth.html';

/// A sign-in window opened while the person's tap is still being handled
/// (browsers block popups opened after an await), then pointed at the
/// provider once the node has prepared the sign-in.
class OAuthWindow {
  OAuthWindow._(this._popup);

  final JSObject _popup;

  /// Opens a blank popup now, inside the tap.
  static OAuthWindow open() {
    const width = 500, height = 650;
    final screen = _window.getProperty<JSObject>('screen'.toJS);
    final left = ((screen.getProperty<JSNumber>('width'.toJS).toDartDouble -
                width) /
            2)
        .clamp(0, 10000);
    final top = ((screen.getProperty<JSNumber>('height'.toJS).toDartDouble -
                height) /
            2)
        .clamp(0, 10000);
    final popup = _window.callMethod<JSObject?>(
        'open'.toJS,
        'about:blank'.toJS,
        'tradera-mcp-oauth'.toJS,
        'popup=yes,width=$width,height=$height,left=${left.round()},top=${top.round()}'
            .toJS);
    if (popup == null) {
      throw StateError(
          'The browser blocked the sign-in window. Allow popups for this site and try again.');
    }
    return OAuthWindow._(popup);
  }

  bool get _closed =>
      _popup.getProperty<JSBoolean?>('closed'.toJS)?.toDart ?? true;

  /// Loads [authorizationUrl] and completes with the address the provider
  /// sent the window back to (carrying the code, or an error).
  Future<String> signIn(BuildContext context, String authorizationUrl,
      {required String redirectUri, required String state}) {
    if (_closed) return Future.error(StateError('Sign-in was cancelled.'));
    final done = Completer<String>();
    final storage = _window.getProperty<JSObject>('localStorage'.toJS);
    final key = 'tradera.oauth.$state';
    final origin = Uri.base.origin;
    late final JSFunction listener;
    Timer? poll, timeout;
    void finish(String? url, [String? error]) {
      if (done.isCompleted) return;
      poll?.cancel();
      timeout?.cancel();
      _window.callMethod<JSAny?>(
          'removeEventListener'.toJS, 'message'.toJS, listener);
      try {
        storage.callMethod<JSAny?>('removeItem'.toJS, key.toJS);
      } catch (_) {}
      close();
      url == null
          ? done.completeError(StateError(error ?? 'Sign-in was cancelled.'))
          : done.complete(url);
    }

    listener = ((JSObject event) {
      if (event.getProperty<JSString?>('origin'.toJS)?.toDart != origin) {
        return;
      }
      final data = event.getProperty<JSAny?>('data'.toJS);
      if (data == null || !data.isA<JSObject>()) return;
      final message = data as JSObject;
      if (message.getProperty<JSString?>('type'.toJS)?.toDart !=
              'tradera:oauth' ||
          message.getProperty<JSString?>('state'.toJS)?.toDart != state) {
        return;
      }
      finish(message.getProperty<JSString?>('url'.toJS)?.toDart);
    }).toJS;
    _window.callMethod<JSAny?>(
        'addEventListener'.toJS, 'message'.toJS, listener);
    // A provider that cuts the window off from its opener still lands on
    // /oauth.html, which leaves the address in storage.
    poll = Timer.periodic(const Duration(milliseconds: 400), (_) {
      final saved =
          storage.callMethod<JSString?>('getItem'.toJS, key.toJS)?.toDart;
      if (saved != null && saved.isNotEmpty) {
        finish(saved);
      } else if (_closed) {
        finish(null);
      }
    });
    timeout = Timer(const Duration(minutes: 5),
        () => finish(null, 'Sign-in took too long. Try again.'));
    _popup
        .getProperty<JSObject>('location'.toJS)
        .setProperty('href'.toJS, authorizationUrl.toJS);
    return done.future;
  }

  /// Closes the window (a failed or finished sign-in).
  void close() {
    try {
      _popup.callMethod<JSAny?>('close'.toJS);
    } catch (_) {}
  }
}
