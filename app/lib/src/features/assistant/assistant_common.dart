import 'package:flutter/material.dart';

import '../../app_dependencies.dart';
import '../../shared/widgets/overlay_panels.dart';

/// Shared plumbing for the assistant's panels: JSON helpers, a loader that
/// shows errors in place, and calls that report failures in a snack bar.

Map<String, dynamic> jsonMap(dynamic v) =>
    v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};

List<Map<String, dynamic>> jsonList(dynamic v) =>
    v is List ? [for (final e in v) jsonMap(e)] : const [];

List<String> jsonStrings(dynamic v) =>
    v is List ? [for (final e in v) '$e'] : const [];

/// A node error without its transport prefix.
String errorText(Object e) {
  final text = '$e';
  final i = text.indexOf(': ');
  return i > 0 && i < 40 ? text.substring(i + 2) : text;
}

/// Calls an action and reports a failure; null when it failed.
Future<Map<String, dynamic>?> runAction(
  BuildContext context,
  AppDependencies deps,
  String namespace,
  String action, [
  Map<String, dynamic> body = const {},
  String? done,
]) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  try {
    final out = jsonMap(
      await deps.service.invokeAction(namespace, action, body: body),
    );
    if (done != null) messenger?.showSnackBar(SnackBar(content: Text(done)));
    return out;
  } catch (e) {
    messenger?.showSnackBar(SnackBar(content: Text(errorText(e))));
    return null;
  }
}

/// A panel with a title bar, a refresh action and a body loaded from the
/// node. [load] runs on open and on refresh; [build] gets its result.
class LoadedPanel extends StatefulWidget {
  const LoadedPanel({
    super.key,
    required this.title,
    required this.load,
    required this.build,
    this.actions = const [],
    this.maxWidth = 760,
  });

  final String title;
  final Future<Map<String, dynamic>> Function() load;
  final Widget Function(
    BuildContext context,
    Map<String, dynamic> data,
    Future<void> Function() reload,
  )
  build;
  final List<Widget> actions;
  final double maxWidth;

  @override
  State<LoadedPanel> createState() => _LoadedPanelState();
}

class _LoadedPanelState extends State<LoadedPanel> {
  Map<String, dynamic>? data;
  String error = '';

  @override
  void initState() {
    super.initState();
    reload();
  }

  Future<void> reload() async {
    try {
      final out = await widget.load();
      if (mounted)
        setState(() {
          data = out;
          error = '';
        });
    } catch (e) {
      if (mounted) setState(() => error = errorText(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        title: Text(widget.title),
        actions: [
          ...widget.actions,
          IconButton(
            tooltip: 'Refresh',
            onPressed: reload,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: widget.maxWidth),
          child: error.isNotEmpty && data == null
              ? Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(error, style: TextStyle(color: scheme.error)),
                )
              : data == null
              ? const Center(child: CircularProgressIndicator())
              : RefreshIndicator(
                  onRefresh: reload,
                  child: widget.build(context, data!, reload),
                ),
        ),
      ),
    );
  }
}

/// A titled group in a panel.
class PanelSection extends StatelessWidget {
  const PanelSection({
    super.key,
    required this.title,
    this.subtitle,
    required this.children,
  });
  final String title;
  final String? subtitle;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            title,
            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
          ),
          if (subtitle != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                subtitle!,
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              ),
            ),
          const SizedBox(height: 8),
          ...children,
        ],
      ),
    );
  }
}

/// Asks for one line of text; null when cancelled.
Future<String?> askText(
  BuildContext context,
  String title, {
  String hint = '',
  String initial = '',
  bool obscure = false,
  int lines = 1,
}) {
  final controller = TextEditingController(text: initial);
  return showAppDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: controller,
        autofocus: true,
        obscureText: obscure,
        minLines: lines,
        maxLines: obscure ? 1 : lines,
        decoration: InputDecoration(hintText: hint),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, controller.text),
          child: const Text('OK'),
        ),
      ],
    ),
  ).whenComplete(controller.dispose);
}

/// Opens a full-screen panel.
Future<void> openPanel(BuildContext context, Widget panel) =>
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => panel));
