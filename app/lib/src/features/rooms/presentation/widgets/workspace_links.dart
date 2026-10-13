import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../../data/services/tradera_service.dart';
import 'attachment_bubble.dart';
import 'proxy_webview.dart';

/// Resolve server report links through the current signed-in workspace client.
/// Never attach credentials to an arbitrary external URL from model output.
Future<void> openWorkspaceLink(
    BuildContext context, TraderaService service, String link) async {
  try {
    final uri = Uri.tryParse(link);
    if (uri == null) throw const FormatException('Invalid link');
    if (uri.scheme == 'attachment' &&
        RegExp(r'^[0-9a-fA-F]{32}$').hasMatch(uri.host) &&
        uri.path.isEmpty &&
        !uri.hasQuery &&
        !uri.hasFragment) {
      final file = await service.fetchFile(uri.host);
      if (!context.mounted) return;
      await showDialog<void>(
          context: context,
          builder: (_) => AlertDialog(
                title: const Text('Delivered file'),
                content: AttachmentBubble(
                    file: file,
                    headers: service.authHeaders(),
                    resolveUrl: (file) => service.fileContentUrl(file.id),
                    fetchBytes: (file) => service.downloadFile(file.id)),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Close'))
                ],
              ));
      return;
    }
    if (!uri.hasScheme &&
        !uri.hasAuthority &&
        RegExp(r'^/v1/proxy/[0-9a-fA-F]{32}/').hasMatch(uri.path)) {
      await openWorkspacePreview(context, service.proxyUrl(link),
          title: 'Website preview');
      return;
    }
    if (!['http', 'https', 'mailto'].contains(uri.scheme)) {
      throw const FormatException('Unsupported link');
    }
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      throw StateError('Could not open link');
    }
  } catch (_) {
    if (context.mounted)
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text(
              'Could not open this link. The file or preview may no longer be available.')));
  }
}

bool get workspacePreviewUsesWebView =>
    !kIsWeb &&
    [
      TargetPlatform.android,
      TargetPlatform.iOS,
      TargetPlatform.macOS,
    ].contains(defaultTargetPlatform);

Future<void> openWorkspacePreview(BuildContext context, String url,
    {required String title}) async {
  if (workspacePreviewUsesWebView) {
    if (!context.mounted) return;
    await Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => ProxyWebView(title: title, url: url)));
  } else if (!await launchUrl(Uri.parse(url),
      mode: LaunchMode.externalApplication)) {
    throw StateError('Could not open preview');
  }
}
