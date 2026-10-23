import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../../shared/widgets/overlay_panels.dart';

/// Where the provider sends the person back. The in-app web view stops at
/// it before it loads, so it only has to be an address the provider accepts:
/// the node's own /oauth.html.
String oauthRedirectUri(String apiBaseUrl) {
  final base = Uri.tryParse(apiBaseUrl);
  final origin = base != null && base.hasScheme && base.host.isNotEmpty
      ? base.origin
      : 'http://localhost';
  return '$origin/oauth.html';
}

/// Whether sign-in pages can open in the app here (flutter_inappwebview).
bool get _inAppSupported => const {
      TargetPlatform.android,
      TargetPlatform.iOS,
      TargetPlatform.macOS,
      TargetPlatform.windows,
    }.contains(defaultTargetPlatform);

/// Signs in inside the app (a web view that catches the redirect), or in the
/// browser with the returned address pasted back where web views do not run.
class OAuthWindow {
  OAuthWindow._();

  /// Nothing opens before the page is ready on these platforms.
  static OAuthWindow open() => OAuthWindow._();

  Future<String> signIn(BuildContext context, String authorizationUrl,
      {required String redirectUri, required String state}) async {
    final returned = _inAppSupported
        ? await Navigator.of(context).push<String>(MaterialPageRoute<String>(
            fullscreenDialog: true,
            builder: (_) =>
                _SignInPage(url: authorizationUrl, redirectUri: redirectUri)))
        : await _inBrowser(context, authorizationUrl);
    if (returned == null || returned.isEmpty) {
      throw StateError('Sign-in was cancelled.');
    }
    return returned;
  }

  void close() {}
}

Future<String?> _inBrowser(BuildContext context, String url) async {
  await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  if (!context.mounted) return null;
  final controller = TextEditingController();
  final pasted = await showAppDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Finish signing in'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        const Text(
            'Sign in in the browser. When it lands on a page that says it is finishing sign-in, copy that page\'s address and paste it here.'),
        const SizedBox(height: 12),
        TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(
                labelText: 'Address after signing in',
                border: OutlineInputBorder())),
      ]),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel')),
        FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Continue')),
      ],
    ),
  );
  controller.dispose();
  return pasted;
}

/// The provider's sign-in page, closed with the address it redirects to.
class _SignInPage extends StatefulWidget {
  const _SignInPage({required this.url, required this.redirectUri});
  final String url;
  final String redirectUri;

  @override
  State<_SignInPage> createState() => _SignInPageState();
}

class _SignInPageState extends State<_SignInPage> {
  bool _loading = true;
  bool _done = false;

  bool _isReturn(Uri? url) {
    if (url == null) return false;
    final target = Uri.parse(widget.redirectUri);
    return url.scheme == target.scheme &&
        url.host == target.host &&
        url.port == target.port &&
        url.path == target.path;
  }

  void _finish(Uri url) {
    if (_done) return;
    _done = true;
    Navigator.of(context).pop(url.toString());
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: const Text('Sign in'),
          leading: IconButton(
              tooltip: 'Cancel',
              onPressed: () => Navigator.of(context).pop(),
              icon: const Icon(Icons.close_rounded)),
          bottom: _loading
              ? const PreferredSize(
                  preferredSize: Size.fromHeight(2),
                  child: LinearProgressIndicator(minHeight: 2))
              : null,
        ),
        body: InAppWebView(
          initialUrlRequest: URLRequest(url: WebUri(widget.url)),
          initialSettings: InAppWebViewSettings(
              useShouldOverrideUrlLoading: true, incognito: true),
          shouldOverrideUrlLoading: (controller, action) async {
            final url = action.request.url;
            if (_isReturn(url)) {
              _finish(url!);
              return NavigationActionPolicy.CANCEL;
            }
            return NavigationActionPolicy.ALLOW;
          },
          onLoadStart: (controller, url) {
            if (_isReturn(url)) _finish(url!);
          },
          onLoadStop: (_, __) {
            if (mounted) setState(() => _loading = false);
          },
        ),
      );
}
