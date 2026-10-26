import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/utils/context_extensions.dart';
import '../../data/services/aseman_service.dart';
import '../desk/presentation/desk_controller.dart';
import '../desk/presentation/web/web_page_frame.dart';
import '../desk/presentation/web_page_view.dart';
import 'computer_view.dart';
import 'space_computer.dart';

/// The proxy a preview gateway path (/v1/proxy/<id>/…) goes through.
String? proxyIdOf(String page) =>
    RegExp(r'^/v1/proxy/([0-9a-fA-F]{32})/').firstMatch(page)?.group(1);

/// A page of the space published from its computer: a port someone (or an
/// agent) made reachable through the node's gateway.
@immutable
class PublishedPreview {
  const PublishedPreview({
    required this.id,
    required this.title,
    required this.port,
    required this.page,
    this.kind = 'preview',
  });

  factory PublishedPreview.fromJson(Map<String, dynamic> m) {
    final port = m['port'] is num
        ? (m['port'] as num).toInt()
        : int.tryParse('${m['port']}') ?? 0;
    final title = '${m['title'] ?? ''}';
    return PublishedPreview(
      id: '${m['id'] ?? ''}',
      title: title.isEmpty ? 'Port $port' : title,
      port: port,
      page: '${m['url'] ?? ''}',
      // Nodes before `kind` named the desktop's and apps' proxies only.
      kind:
          '${m['kind'] ?? (port == 6080 && title == 'Desktop'
                  ? 'desktop'
                  : title.startsWith('Tool · ')
                  ? 'tool'
                  : 'preview')}',
    );
  }

  final String id;
  final String title;
  final int port;

  /// The gateway path: /v1/proxy/<id>/.
  final String page;

  /// preview, desktop (the Computer tab's) or tool (an installed app's).
  final String kind;
}

/// Opens a preview: as a card window on the desk on wide screens, in a
/// bottom sheet on phones. Either wakes the computer and starts the
/// preview's app when needed, then shows it.
Future<void> openPreview(
  BuildContext context,
  AsemanService service, {
  required String spaceId,
  required String page,
  required String title,
}) async {
  final desk = DeskScope.maybeOf(context);
  if (desk != null &&
      MediaQuery.sizeOf(context).width >= computerSheetBreakpoint) {
    await desk.openPage(page, title: title);
    return;
  }
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    // The page scrolls and is touched: only the handle bar moves the sheet.
    enableDrag: false,
    clipBehavior: Clip.antiAlias,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (sheet) => FractionallySizedBox(
      heightFactor: .94,
      child: LivePreview(
        service: service,
        spaceId: spaceId,
        page: page,
        title: title,
        embed: 'screen',
        onClose: () => Navigator.of(sheet).pop(),
      ),
    ),
  );
}

enum _Phase { preparing, ready, unavailable, asleep }

/// A preview, made ready before it is shown: the computer is woken if it
/// sleeps and the preview's app started again if it is not answering
/// (spaces.proxy_open), with each step said as it happens; then the page,
/// live. While it is on screen the computer counts as in use; if it falls
/// asleep anyway, the page offers to wake it and reconnect.
class LivePreview extends StatefulWidget {
  const LivePreview({
    super.key,
    required this.service,
    required this.page,
    this.spaceId = '',
    this.title = '',
    this.embed = 'desk',
    this.onClose,
    this.content,
    this.compact = false,
  });

  final AsemanService service;

  /// The gateway path: /v1/proxy/<id>/….
  final String page;

  /// The space whose computer serves it ('' when unknown: then its state is
  /// not followed).
  final String spaceId;
  final String title;

  /// Where it is shown (desk, screen).
  final String embed;

  /// In a sheet: a header names the page and closes it.
  final VoidCallback? onClose;

  /// What is shown once the service is up, instead of the web page (an
  /// Elpian app's native view).
  final WidgetBuilder? content;

  /// Shown as a phone-board widget: while it is not ready, a quiet tile
  /// state instead of the full explanations (a tap opens it in full).
  final bool compact;

  @override
  State<LivePreview> createState() => _LivePreviewState();
}

class _LivePreviewState extends State<LivePreview> {
  SpaceComputer? _computer;
  _Phase _phase = _Phase.preparing;
  String _problem = '';
  String _log = '';
  int _generation = 0;
  Timer? _keepAlive;
  bool _wasAwake = false;

  String get _name => widget.title.isEmpty ? 'the page' : widget.title;

  @override
  void initState() {
    super.initState();
    if (widget.spaceId.isNotEmpty) {
      _computer = SpaceComputer.of(widget.service, widget.spaceId)
        ..addListener(_computerChanged);
      _wasAwake = _computer!.state == ComputerState.awake;
    }
    unawaited(_prepare());
  }

  @override
  void dispose() {
    _keepAlive?.cancel();
    _computer?.removeListener(_computerChanged);
    super.dispose();
  }

  void _computerChanged() {
    final computer = _computer!;
    final awake = computer.state == ComputerState.awake;
    // It fell asleep under the page: say so instead of a broken page.
    if (_wasAwake && computer.state.off && _phase == _Phase.ready) {
      _phase = _Phase.asleep;
    }
    _wasAwake = awake;
    if (mounted) setState(() {});
  }

  Future<void> _prepare() async {
    setState(() {
      _phase = _Phase.preparing;
      _problem = _log = '';
    });
    final id = proxyIdOf(widget.page);
    if (id == null) {
      _show();
      return;
    }
    try {
      final response = await widget.service.invokeAction(
        'spaces',
        'proxy_open',
        body: {'proxy': id},
        // Waking takes seconds; an app started again can take minutes.
        timeout: const Duration(minutes: 5),
      );
      if (!mounted) return;
      final m = response is Map ? response : const <String, dynamic>{};
      if (m['ready'] == false) {
        setState(() {
          _phase = _Phase.unavailable;
          _problem = m['can_start'] == true
              ? '$_name did not start on the computer.'
              : 'Nothing is answering for $_name yet. Ask the team to start it, then try again.';
          _log = '${m['log'] ?? ''}';
        });
        return;
      }
      _show();
    } catch (e) {
      if (!mounted) return;
      // Someone who may only look (or an older node) cannot prepare it:
      // the page is shown as it is when the computer is awake.
      if (_computer?.state == ComputerState.awake) {
        _show();
        return;
      }
      setState(() {
        _phase = _Phase.unavailable;
        _problem = 'The computer could not be woken: ${_short(e)}';
      });
    }
  }

  void _show() {
    if (!mounted) return;
    setState(() {
      _phase = _Phase.ready;
      _generation++;
      _wasAwake = true;
    });
    _keepAlive ??= Timer.periodic(const Duration(seconds: 45), (_) {
      if (_phase == _Phase.ready) unawaited(_computer?.keepAlive());
    });
  }

  static String _short(Object e) {
    final text = '$e';
    return text.length > 200 ? '${text.substring(0, 200)}…' : text;
  }

  Uri? get _browserUrl {
    try {
      return Uri.parse(widget.service.proxyUrl(widget.page));
    } catch (_) {
      return null;
    }
  }

  Future<void> _openInBrowser() async {
    final url = _browserUrl;
    if (url == null ||
        !await launchUrl(url, mode: LaunchMode.externalApplication)) {
      if (mounted) context.showMessage('Could not open the browser.');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.compact && _phase != _Phase.ready) {
      final scheme = Theme.of(context).colorScheme;
      return Center(
        child: _phase == _Phase.preparing
            ? SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: scheme.primary))
            : Icon(
                _phase == _Phase.asleep
                    ? Icons.bedtime_outlined
                    : Icons.cloud_off_rounded,
                color: scheme.onSurfaceVariant),
      );
    }
    final body = switch (_phase) {
      _Phase.ready when widget.content != null => KeyedSubtree(
        key: ValueKey('${widget.page}#$_generation'),
        child: widget.content!(context),
      ),
      _Phase.ready => WebPageView(
        key: ValueKey('${widget.page}#$_generation'),
        service: widget.service,
        page: widget.page,
        embed: widget.embed,
        // The sheet's header carries what the strip would.
        showStrip: widget.onClose == null,
        claimGestures: widget.onClose != null,
      ),
      _Phase.preparing => _Preparing(
        step: _computer == null || _computer!.state == ComputerState.awake
            ? 'Starting $_name…'
            : 'Waking the computer…',
        detail: _computer == null || _computer!.state == ComputerState.awake
            ? 'Making sure it is running and reachable.'
            : 'It slept while nothing used it. This takes a few seconds.',
      ),
      _Phase.unavailable => _Problem(
        icon: Icons.cloud_off_rounded,
        title: 'Not available right now',
        text: _problem,
        log: _log,
        primary: ('Try again', _prepare),
        secondary: ('Show anyway', _show),
      ),
      _Phase.asleep => _Problem(
        icon: Icons.bedtime_outlined,
        title: 'The computer fell asleep',
        text: 'Nothing was using it, so it went to sleep. Its files are kept.',
        primary: ('Wake and reconnect', _prepare),
      ),
    };
    if (widget.onClose == null) return body;
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            height: 56,
            padding: const EdgeInsets.only(left: 16, right: 4),
            decoration: BoxDecoration(
              color: scheme.surfaceContainer,
              border: Border(
                bottom: BorderSide(color: scheme.outlineVariant, width: .5),
              ),
            ),
            child: Row(
              children: [
                Icon(Icons.language_rounded, size: 18, color: scheme.primary),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.title.isEmpty ? 'Preview' : widget.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      if (_computer != null)
                        Row(
                          children: [
                            ComputerStateLight(_computer!.state, size: 6),
                            const SizedBox(width: 5),
                            Text(
                              'Computer ${_computer!.state.label.toLowerCase()}',
                              style: TextStyle(
                                fontSize: 11,
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'Reload',
                  visualDensity: VisualDensity.compact,
                  onPressed: _prepare,
                  icon: const Icon(Icons.refresh_rounded, size: 20),
                ),
                IconButton(
                  tooltip: 'Open in the browser',
                  visualDensity: VisualDensity.compact,
                  onPressed: _openInBrowser,
                  icon: const Icon(Icons.open_in_new_rounded, size: 19),
                ),
                IconButton(
                  tooltip: 'Close',
                  visualDensity: VisualDensity.compact,
                  onPressed: widget.onClose,
                  icon: const Icon(Icons.close_rounded, size: 21),
                ),
              ],
            ),
          ),
          Expanded(child: body),
        ],
      ),
    );
  }
}

class _Preparing extends StatelessWidget {
  const _Preparing({required this.step, required this.detail});
  final String step;
  final String detail;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 320),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: scheme.primaryContainer,
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Icon(
                  Icons.rocket_launch_rounded,
                  color: scheme.onPrimaryContainer,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                step,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                detail,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 12.5,
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 18),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: const LinearProgressIndicator(minHeight: 4),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Problem extends StatelessWidget {
  const _Problem({
    required this.icon,
    required this.title,
    required this.text,
    required this.primary,
    this.secondary,
    this.log = '',
  });
  final IconData icon;
  final String title;
  final String text;
  final String log;
  final (String, VoidCallback) primary;
  final (String, VoidCallback)? secondary;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 36, color: scheme.onSurfaceVariant),
              const SizedBox(height: 12),
              Text(
                title,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                text,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 12.5,
                  color: scheme.onSurfaceVariant,
                ),
              ),
              if (log.isNotEmpty) ...[
                const SizedBox(height: 12),
                Container(
                  width: double.infinity,
                  constraints: const BoxConstraints(maxHeight: 160),
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: SingleChildScrollView(
                    child: SelectableText(
                      log,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 10.5,
                      ),
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 16),
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (secondary != null)
                    OutlinedButton(
                      onPressed: secondary!.$2,
                      child: Text(secondary!.$1),
                    ),
                  FilledButton(onPressed: primary.$2, child: Text(primary.$1)),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A preview drawn as a small browser window: the page live (looked at,
/// not used) while the computer is awake, a dark screen while it sleeps.
class PreviewThumbnail extends StatelessWidget {
  const PreviewThumbnail({
    super.key,
    required this.service,
    required this.preview,
    required this.state,
  });

  final AsemanService service;
  final PublishedPreview preview;
  final ComputerState state;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final live = state == ComputerState.awake && webPageFrameSupported;
    Widget dot(Color c) => Container(
      width: 6,
      height: 6,
      margin: const EdgeInsets.only(right: 4),
      decoration: BoxDecoration(color: c, shape: BoxShape.circle),
    );
    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: .6)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          // The window's bar.
          Container(
            height: 20,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            color: scheme.surfaceContainerHigh,
            child: Row(
              children: [
                dot(const Color(0xFFFF5F57)),
                dot(const Color(0xFFFEBC2E)),
                dot(const Color(0xFF28C840)),
                const SizedBox(width: 4),
                Expanded(
                  child: Container(
                    height: 12,
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    alignment: Alignment.centerLeft,
                    decoration: BoxDecoration(
                      color: scheme.surfaceContainerLowest,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      ':${preview.port}',
                      style: TextStyle(
                        fontSize: 8,
                        height: 1,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          AspectRatio(
            aspectRatio: 16 / 10,
            child: live
                ? ColoredBox(
                    color: Colors.white,
                    child: WebPageView(
                      key: ValueKey('thumb-${preview.page}'),
                      service: service,
                      page: preview.page,
                      showStrip: false,
                      interactive: false,
                    ),
                  )
                : _DarkPage(state: state),
          ),
        ],
      ),
    );
  }
}

class _DarkPage extends StatelessWidget {
  const _DarkPage({required this.state});
  final ComputerState state;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: const BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Color(0xFF0D1117), Color(0xFF07090C)],
      ),
    ),
    child: Center(
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (state.changing)
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                const Icon(
                  Icons.power_settings_new_rounded,
                  size: 20,
                  color: Color(0x40FFFFFF),
                ),
              const SizedBox(height: 6),
              Text(
                state.changing
                    ? state.label
                    : state == ComputerState.awake
                    ? 'Opens in the app'
                    : 'Asleep · wakes when opened',
                style: const TextStyle(color: Color(0x99E8ECEF), fontSize: 10),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

/// Copies a preview's address (without the sign-in it is opened with).
Future<void> copyPreviewLink(
  BuildContext context,
  AsemanService service,
  String page,
) async {
  final url = Uri.parse(service.proxyUrl(page));
  final bare = url.replace(
    queryParameters: {
      for (final e in url.queryParameters.entries)
        if (e.key != 'token') e.key: e.value,
    },
  );
  await Clipboard.setData(
    ClipboardData(text: bare.toString().replaceFirst(RegExp(r'\?$'), '')),
  );
  if (context.mounted) context.showMessage('Link copied');
}
