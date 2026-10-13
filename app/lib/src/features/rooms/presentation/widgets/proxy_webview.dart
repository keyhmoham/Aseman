import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// A full-screen webview for a workspace's authenticated sandbox preview.
///
/// Android/iOS/macOS use this view; other platforms open the gateway externally.
/// A failed preview keeps reload and external-open controls available.
class ProxyWebView extends StatefulWidget {
  const ProxyWebView({super.key, required this.title, required this.url});

  final String title;
  final String url;

  @override
  State<ProxyWebView> createState() => _ProxyWebViewState();
}

class _ProxyWebViewState extends State<ProxyWebView> {
  late final WebViewController _controller;
  bool _loading = true;
  String? _error;
  Timer? _loaderTimer;
  late Uri _mainPage;

  @override
  void initState() {
    super.initState();
    _mainPage = Uri.parse(widget.url);
    // A missing completion callback must not leave the loader blocking content.
    _loaderTimer = Timer(const Duration(seconds: 6), () {
      if (mounted) setState(() => _loading = false);
    });
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0xFFFAFAFA))
      ..setNavigationDelegate(NavigationDelegate(
        onPageStarted: (url) {
          _mainPage = Uri.parse(url);
          if (mounted)
            setState(() {
              _loading = true;
              _error = null;
            });
        },
        onPageFinished: (_) {
          if (mounted) setState(() => _loading = false);
        },
        onWebResourceError: (error) {
          if (error.isForMainFrame == false || !mounted) return;
          setState(() {
            _loading = false;
            _error =
                'Preview is unavailable. Its server may have stopped or its access may have expired.';
          });
        },
        onHttpError: (error) {
          if (!mounted) return;
          final request = error.request;
          if (request != null &&
              (request.uri.host != _mainPage.host ||
                  request.uri.path != _mainPage.path)) return;
          setState(() {
            _loading = false;
            _error =
                'Preview could not load. Try again or use the delivered files.';
          });
        },
      ))
      ..loadRequest(Uri.parse(widget.url));
  }

  @override
  void dispose() {
    _loaderTimer?.cancel();
    super.dispose();
  }

  Future<void> _openExternally() async {
    try {
      if (await launchUrl(Uri.parse(widget.url),
          mode: LaunchMode.externalApplication)) return;
    } catch (_) {
      // The in-app view remains available for retry.
    }
    if (mounted)
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not open an external browser.')));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFFAFAFA),
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.close_rounded),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: 'Open externally',
            icon: const Icon(Icons.open_in_new_rounded),
            onPressed: _openExternally,
          ),
          IconButton(
            tooltip: 'Reload',
            icon: const Icon(Icons.refresh_rounded),
            onPressed: _reload,
          ),
        ],
      ),
      body: Stack(children: [
        // The webview itself (fills the body). Never cover it with an opaque
        // overlay, or the page stays hidden behind a grey box.
        Positioned.fill(
            child: ColoredBox(
          color: const Color(0xFFFAFAFA),
          child: WebViewWidget(controller: _controller),
        )),
        if (_loading)
          const Positioned(
              left: 0,
              right: 0,
              top: 0,
              child: LinearProgressIndicator(minHeight: 2.5)),
        if (_error != null)
          Positioned(
              left: 12,
              right: 12,
              top: 12,
              child: Card(
                  child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        Text(_error!),
                        TextButton(
                            onPressed: _reload,
                            child: const Text('Retry preview')),
                      ])))),
      ]),
    );
  }

  void _reload() {
    setState(() {
      _error = null;
      _loading = true;
    });
    _loaderTimer?.cancel();
    _loaderTimer = Timer(const Duration(seconds: 6), () {
      if (mounted) setState(() => _loading = false);
    });
    _controller.reload();
  }
}
