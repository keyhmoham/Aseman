import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../../app_dependencies.dart';

/// Single sign-on with the organization's identity provider (OIDC).
///
/// The node sends the person to the provider and, once it has verified who
/// they are, back to the app at /sso/complete with a one-time handoff that
/// the app trades for its session (enterprise.sso_complete). On the web the
/// whole page goes there and back; on phones and Macs the provider opens in a
/// web view that stops at /sso/complete; elsewhere the browser finishes the
/// sign-in for the web app.

/// The providers this node offers, by name (empty: no SSO here).
Future<List<String>> ssoProviders(AppDependencies deps) async {
  try {
    final out = await deps.service.invokeAction('enterprise', 'sso_discover', body: {'email': ''});
    final list = out is Map ? out['providers'] : null;
    return [if (list is List) for (final p in list) if (p is Map) '${p['name']}'];
  } catch (_) {
    return const [];
  }
}

bool get _inAppWebView =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.macOS);

/// Signs in with the provider that serves [email]. Errors are thrown with
/// the node's message.
Future<void> signInWithSso(BuildContext context, AppDependencies deps, String email) async {
  final out = await deps.service.invokeAction('enterprise', 'sso_start', body: {'email': email, 'return': '/'});
  final url = Uri.parse('${out is Map ? out['url'] : ''}');
  if (kIsWeb) {
    await launchUrl(url, webOnlyWindowName: '_self');
    return;
  }
  if (!_inAppWebView) {
    await launchUrl(url, mode: LaunchMode.externalApplication);
    throw 'Finish signing in in your browser; the web app opens signed in.';
  }
  if (!context.mounted) return;
  final done = await Navigator.of(context).push<Uri>(
      MaterialPageRoute(fullscreenDialog: true, builder: (_) => _SsoWebView(start: url)));
  if (done == null) return;
  await completeSso(deps, done);
}

/// Finishes a sign-in that came back to [uri] (/sso/complete?handoff=…).
Future<void> completeSso(AppDependencies deps, Uri uri) async {
  final error = uri.queryParameters['error'] ?? '';
  if (error.isNotEmpty) throw error;
  final handoff = uri.queryParameters['handoff'] ?? '';
  if (handoff.isEmpty) throw 'The sign-in did not finish.';
  final session = await deps.service.ssoComplete(handoff);
  await deps.sessionController.adopt(session);
}

/// On the web, the page the provider sent the person back to.
bool get returnedFromSso => kIsWeb && Uri.base.path.endsWith('/sso/complete');

class _SsoWebView extends StatefulWidget {
  const _SsoWebView({required this.start});
  final Uri start;

  @override
  State<_SsoWebView> createState() => _SsoWebViewState();
}

class _SsoWebViewState extends State<_SsoWebView> {
  late final WebViewController controller = WebViewController()
    ..setJavaScriptMode(JavaScriptMode.unrestricted)
    ..setNavigationDelegate(NavigationDelegate(onNavigationRequest: (request) {
      final uri = Uri.tryParse(request.url);
      if (uri != null && uri.path.endsWith('/sso/complete')) {
        Navigator.of(context).pop(uri);
        return NavigationDecision.prevent;
      }
      return NavigationDecision.navigate;
    }))
    ..loadRequest(widget.start);

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Single sign-on')),
        body: WebViewWidget(controller: controller),
      );
}
