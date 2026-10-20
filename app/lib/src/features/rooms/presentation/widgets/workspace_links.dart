import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../../data/services/tradera_service.dart';
import '../../../desk/presentation/desk_controller.dart';
import '../../../desk/presentation/web/web_page_frame.dart';
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
      await openWorkspacePage(context, service, link, title: 'Website preview');
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

/// Where a page of the space opens: on the room's desk, as a card window
/// next to tools' frontends, when a desk is on screen; else full screen in
/// the app where it can show pages; else in the browser.
enum WorkspacePageTarget { desk, screen, browser }

WorkspacePageTarget workspacePageTarget(BuildContext context) =>
    DeskScope.maybeOf(context) != null
        ? WorkspacePageTarget.desk
        : webPageFrameSupported
            ? WorkspacePageTarget.screen
            : WorkspacePageTarget.browser;

/// Opens [page] (a preview gateway path, /v1/proxy/<id>/…) in the app.
Future<void> openWorkspacePage(
    BuildContext context, TraderaService service, String page,
    {required String title}) async {
  switch (workspacePageTarget(context)) {
    case WorkspacePageTarget.desk:
      await DeskScope.maybeOf(context)!.openPage(page, title: title);
    case WorkspacePageTarget.screen:
      await Navigator.of(context).push(MaterialPageRoute<void>(
          builder: (_) =>
              ProxyWebView(title: title, service: service, page: page)));
    case WorkspacePageTarget.browser:
      if (!await launchUrl(Uri.parse(service.proxyUrl(page)),
          mode: LaunchMode.externalApplication)) {
        throw StateError('Could not open preview');
      }
  }
}
