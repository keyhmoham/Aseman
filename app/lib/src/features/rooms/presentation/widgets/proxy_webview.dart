import 'package:flutter/material.dart';

import '../../../../data/services/tradera_service.dart';
import '../../../computer/preview_view.dart';

/// A web page of the space (a sandbox preview behind the gateway) full
/// screen, where no desk is on screen (the messenger); in the same view the
/// desk's card windows use, on every platform that has one.
class ProxyWebView extends StatelessWidget {
  const ProxyWebView(
      {super.key,
      required this.title,
      required this.service,
      required this.page});

  final String title;
  final TraderaService service;

  /// The gateway path: /v1/proxy/<id>/….
  final String page;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.close_rounded),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      // Woken and started when needed, then shown.
      body: LivePreview(
          service: service, page: page, title: title, embed: 'screen'),
    );
  }
}
