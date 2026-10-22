import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// Builds the frame running [html]: messages the app posts reach
/// [onMessage]; [onReady] gets the function that posts to the app.
Widget mcpAppFrame({
  Key? key,
  required String html,
  required void Function(Object? message) onMessage,
  required void Function(void Function(Map<String, dynamic>) send) onReady,
}) =>
    _McpAppWebView(
        key: key, html: html, onMessage: onMessage, onReady: onReady);

/// Whether apps can run here (a web view exists on Android, iOS and macOS).
bool get mcpAppFrameSupported =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.macOS);

/// In a web view the app's page is the top window, so it has no parent to
/// post to: this shim gives it one. What it posts to its "parent" goes to
/// the host's channel; what the host sends arrives as a message from that
/// parent.
const _shim = '''
<script>(function(){
  var parent = { postMessage: function(m){ AsemanMcpHost.postMessage(JSON.stringify(m)); } };
  try { window.parent = parent; } catch (e) {}
  if (window.parent !== parent) {
    try { Object.defineProperty(window, 'parent', { get: function(){ return parent; } }); } catch (e) {}
  }
  window.__asemanMcpDeliver = function(json){
    var e = new Event('message');
    Object.defineProperty(e, 'data', { value: JSON.parse(json) });
    Object.defineProperty(e, 'source', { value: parent });
    Object.defineProperty(e, 'origin', { value: 'null' });
    window.dispatchEvent(e);
  };
})();</script>
''';

/// [html] with the shim first in its head.
@visibleForTesting
String withMcpShim(String html) {
  final head = RegExp(r'<head[^>]*>', caseSensitive: false).firstMatch(html);
  if (head != null) {
    return html.replaceRange(head.end, head.end, _shim);
  }
  return '$_shim$html';
}

class _McpAppWebView extends StatefulWidget {
  const _McpAppWebView(
      {super.key,
      required this.html,
      required this.onMessage,
      required this.onReady});

  final String html;
  final void Function(Object? message) onMessage;
  final void Function(void Function(Map<String, dynamic>) send) onReady;

  @override
  State<_McpAppWebView> createState() => _McpAppWebViewState();
}

class _McpAppWebViewState extends State<_McpAppWebView> {
  WebViewController? _controller;

  @override
  void initState() {
    super.initState();
    if (!mcpAppFrameSupported) return;
    final controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0x00000000))
      ..addJavaScriptChannel('AsemanMcpHost', onMessageReceived: (m) {
        try {
          widget.onMessage(jsonDecode(m.message));
        } catch (_) {}
      })
      ..setNavigationDelegate(NavigationDelegate(
        // The app stays on its page: links open through ui/open-link.
        onNavigationRequest: (request) =>
            request.url.startsWith('about:') || request.url.startsWith('data:')
                ? NavigationDecision.navigate
                : NavigationDecision.prevent,
      ))
      ..loadHtmlString(withMcpShim(widget.html));
    _controller = controller;
    widget.onReady((message) {
      final json = jsonEncode(jsonEncode(message));
      controller.runJavaScript(
          'window.__asemanMcpDeliver && window.__asemanMcpDeliver($json)');
    });
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (controller == null) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
              'This app shows its results in its own screen, which runs in the web, Android, iOS and macOS versions of Aseman.',
              textAlign: TextAlign.center),
        ),
      );
    }
    // Vertical drags scroll the app's page, not the chat around it.
    return WebViewWidget(
      controller: controller,
      gestureRecognizers: {
        const Factory<VerticalDragGestureRecognizer>(
            VerticalDragGestureRecognizer.new),
      },
    );
  }
}
