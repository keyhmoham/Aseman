import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'web_page_handle.dart';

/// Whether pages can show in the app here: flutter_inappwebview runs on
/// Android, iOS, macOS and Windows (WebView2); elsewhere they open in the
/// browser.
bool get webPageFrameSupported =>
    !kIsWeb &&
    const {
      TargetPlatform.android,
      TargetPlatform.iOS,
      TargetPlatform.macOS,
      TargetPlatform.windows,
    }.contains(defaultTargetPlatform);

/// A native web view showing [url]. It stays on the page's own site:
/// links elsewhere and new windows open in the browser.
Widget webPageFrame({
  Key? key,
  required String url,
  required Map<String, dynamic> theme,
  required WebPageStatus onStatus,
  required void Function(WebPageHandle handle) onReady,
  Future<void> Function(Uri url)? openExternal,
  bool interactive = true,
  bool claimGestures = false,
}) => IgnorePointer(
  ignoring: !interactive,
  child: _WebPageWebView(
    key: key,
    url: url,
    theme: theme,
    onStatus: onStatus,
    onReady: onReady,
    openExternal: openExternal,
    claimGestures: claimGestures,
  ),
);

class _WebPageWebView extends StatefulWidget {
  const _WebPageWebView({
    super.key,
    required this.url,
    required this.theme,
    required this.onStatus,
    required this.onReady,
    this.openExternal,
    this.claimGestures = false,
  });

  final String url;

  /// Every touch is the page's (a remote screen), even inside a sheet or a
  /// scrolling view that would otherwise take drags.
  final bool claimGestures;
  final Map<String, dynamic> theme;
  final WebPageStatus onStatus;
  final void Function(WebPageHandle handle) onReady;
  final Future<void> Function(Uri url)? openExternal;

  @override
  State<_WebPageWebView> createState() => _WebPageWebViewState();
}

class _WebPageWebViewState extends State<_WebPageWebView>
    implements WebPageHandle {
  InAppWebViewController? _controller;
  late Map<String, dynamic> _theme = widget.theme;
  late final Uri _home = Uri.parse(widget.url);

  Future<void> _sendTheme() async {
    final json = jsonEncode({'type': 'aseman:theme', ..._theme});
    await _controller?.evaluateJavascript(
      source: 'window.__asemanSetTheme && window.__asemanSetTheme($json);',
    );
  }

  @override
  Future<void> reload() async {
    widget.onStatus(loading: true);
    await _controller?.reload();
  }

  @override
  void setTheme(Map<String, dynamic> theme) {
    _theme = theme;
    _sendTheme();
  }

  /// The page's own site (the node's preview gateway) stays in the view.
  bool _own(Uri? url) =>
      url == null ||
      url.scheme == 'about' ||
      url.scheme == 'data' ||
      url.scheme == 'blob' ||
      (url.host == _home.host && url.port == _home.port);

  @override
  Widget build(BuildContext context) {
    return InAppWebView(
      // Drags scroll the page even inside a list, a sheet or a desk that
      // scrolls itself; without a recognizer of its own the view only gets
      // the touches nothing around it wants, and Android pages never scroll.
      gestureRecognizers: widget.claimGestures
          ? {const Factory<EagerGestureRecognizer>(EagerGestureRecognizer.new)}
          : {
              const Factory<VerticalDragGestureRecognizer>(
                VerticalDragGestureRecognizer.new,
              ),
            },
      initialUrlRequest: URLRequest(url: WebUri(widget.url)),
      initialSettings: InAppWebViewSettings(
        javaScriptEnabled: true,
        transparentBackground: true,
        mediaPlaybackRequiresUserGesture: false,
        allowsInlineMediaPlayback: true,
        supportMultipleWindows: true,
        javaScriptCanOpenWindowsAutomatically: false,
        useShouldOverrideUrlLoading: true,
        isInspectable: kDebugMode,
        // The page follows the app's own theme; no automatic darkening.
        algorithmicDarkeningAllowed: false,
        forceDark: ForceDark.OFF,
      ),
      onWebViewCreated: (controller) {
        _controller = controller;
        widget.onReady(this);
      },
      onLoadStart: (_, __) => widget.onStatus(loading: true),
      onLoadStop: (_, __) {
        widget.onStatus(loading: false);
        _sendTheme();
      },
      onReceivedError: (_, request, error) {
        if (request.isForMainFrame == false) return;
        widget.onStatus(
          loading: false,
          error:
              'The page is unavailable. Its server may have stopped or its access may have expired.',
        );
      },
      onReceivedHttpError: (_, request, response) {
        if (request.isForMainFrame == false) return;
        widget.onStatus(
          loading: false,
          error: 'The page could not load (${response.statusCode ?? 'error'}).',
        );
      },
      shouldOverrideUrlLoading: (_, action) async {
        final url = action.request.url;
        if (_own(url)) return NavigationActionPolicy.ALLOW;
        if (url != null) await widget.openExternal?.call(url);
        return NavigationActionPolicy.CANCEL;
      },
      onCreateWindow: (_, action) async {
        final url = action.request.url;
        if (url != null) await widget.openExternal?.call(url);
        return false;
      },
    );
  }
}
