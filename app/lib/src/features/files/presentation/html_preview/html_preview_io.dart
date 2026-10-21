import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:url_launcher/url_launcher.dart';

/// Whether HTML can be rendered in the app here: flutter_inappwebview runs
/// on Android, iOS, macOS and Windows (WebView2).
bool get htmlPreviewSupported =>
    !kIsWeb &&
    const {
      TargetPlatform.android,
      TargetPlatform.iOS,
      TargetPlatform.macOS,
      TargetPlatform.windows,
    }.contains(defaultTargetPlatform);

/// [html] in a native web view, on a blank origin. Links out of the page
/// open in the browser.
Widget htmlPreview({Key? key, required String html}) => InAppWebView(
  key: key,
  initialData: InAppWebViewInitialData(
    data: html,
    baseUrl: WebUri('about:blank'),
  ),
  initialSettings: InAppWebViewSettings(
    javaScriptEnabled: true,
    useShouldOverrideUrlLoading: true,
    supportMultipleWindows: false,
    javaScriptCanOpenWindowsAutomatically: false,
    allowFileAccess: false,
    allowContentAccess: false,
    isInspectable: kDebugMode,
  ),
  shouldOverrideUrlLoading: (_, action) async {
    final url = action.request.url;
    if (url == null ||
        url.scheme == 'about' ||
        url.scheme == 'data' ||
        url.scheme == 'blob' ||
        action.isForMainFrame == false) {
      return NavigationActionPolicy.ALLOW;
    }
    await launchUrl(url, mode: LaunchMode.externalApplication);
    return NavigationActionPolicy.CANCEL;
  },
);
