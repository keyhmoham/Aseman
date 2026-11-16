import 'package:flutter/material.dart';

import '../../../agui/agui.dart';
import '../../../data/services/aseman_service.dart';
import '../../files/presentation/html_preview/html_preview.dart';
import '../../tools/elpian_app/elpian_app_view.dart';
import '../domain/desk_models.dart';
import 'compact_summary.dart';
import 'frontend_presentation.dart';

/// An AG-UI window. On the phone board it is a summary that opens the
/// surface; opened, the surface itself.
class DeskAgUiView extends StatelessWidget {
  const DeskAgUiView({super.key, required this.window});

  final DeskWindow window;

  @override
  Widget build(BuildContext context) {
    final title = window.label.isEmpty ? 'Visualization' : window.label;
    if (FrontendPresentation.isCompact(context)) {
      return CompactSummaryView(
        summary: CompactSummary(
          title: title,
          caption: 'AG-UI · tap to open',
          icon: 'dashboard',
        ),
      );
    }
    final raw = window.aguiSurface;
    if (raw == null) {
      return const Center(child: Text('Empty AG-UI surface'));
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: AgUiSurfaceView(
        key: ValueKey('agui-${window.id}'),
        surface: AgUiSurface.fromJson(raw),
        compact: false,
      ),
    );
  }
}

/// A report stored on the desk window: an HTML document or an Elpian
/// program. Same card an on-demand app uses, without a preview server.
class DeskReportView extends StatelessWidget {
  const DeskReportView({
    super.key,
    required this.service,
    required this.window,
    this.spaceId = '',
    this.roomId = '',
  });

  final AsemanService service;
  final DeskWindow window;
  final String spaceId;
  final String roomId;

  @override
  Widget build(BuildContext context) {
    final elpian = window.isElpianReport;
    final title = window.label.isEmpty
        ? (elpian ? 'Elpian report' : 'Web report')
        : window.label;
    if (FrontendPresentation.isCompact(context)) {
      return CompactSummaryView(
        summary: CompactSummary(
          title: title,
          caption: elpian
              ? 'Elpian report · tap to open'
              : 'Web report · tap to open',
          icon: elpian ? 'widgets' : 'language',
        ),
      );
    }
    if (elpian) {
      return ElpianAppView(
        key: ValueKey('report-elpian-${window.id}'),
        service: service,
        page: 'desk://report',
        entry: 'report.js',
        code: window.reportProgram,
        spaceId: spaceId,
        roomId: roomId,
        title: title,
      );
    }
    if (!htmlPreviewSupported) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Text(
            'This web report needs a web view, which this device does not have.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    return htmlPreview(
      key: ValueKey('report-html-${window.id}'),
      html: window.reportHtml,
    );
  }
}

/// The short tile a pinned report or AG-UI surface shows before it opens.
class DeskKindPreview extends StatelessWidget {
  const DeskKindPreview({super.key, required this.pin});

  final DeskPin pin;

  @override
  Widget build(BuildContext context) {
    final (caption, icon) = pin.isAgui
        ? ('AG-UI', 'dashboard')
        : pin.isElpianReport
            ? ('Elpian report', 'widgets')
            : pin.isHtmlReport
                ? ('Web report', 'language')
                : pin.isComputer
                    ? ('Computer', 'computer')
                    : pin.isFile
                        ? ('File', 'description')
                        : ('Preview', 'language');
    final title = pin.label.isEmpty
        ? (pin.isAgui
            ? 'Visualization'
            : pin.isElpianReport
                ? 'Elpian report'
                : pin.isHtmlReport
                    ? 'Web report'
                    : pin.isComputer
                        ? 'Computer'
                        : pin.isFile
                            ? 'File'
                            : 'Web page')
        : pin.label;
    return CompactSummaryView(
      summary: CompactSummary(title: title, caption: caption, icon: icon),
    );
  }
}
