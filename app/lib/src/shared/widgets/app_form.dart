import 'package:flutter/material.dart';

import 'app_inputs.dart';

/// Shows [form] as a bottom sheet on phones and as a dialog elsewhere, and
/// returns what the form pops with.
Future<T?> showAppForm<T>(BuildContext context, Widget form) {
  if (MediaQuery.sizeOf(context).width < 600) {
    return showModalBottomSheet<T>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => Padding(
        padding:
            EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
        child: form,
      ),
    );
  }
  return showDialog<T>(
    context: context,
    builder: (context) => Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 580, maxHeight: 780),
        child: form,
      ),
    ),
  );
}

/// The frame every form in the app shares: an icon badge, a headline, the
/// scrolling fields, and the actions pinned to the bottom.
class AppFormFrame extends StatelessWidget {
  const AppFormFrame({
    required this.icon,
    required this.title,
    required this.children,
    required this.submit,
    required this.onSubmit,
    this.subtitle,
    this.destructive = false,
    this.formKey,
  });
  final IconData icon;
  final String title;
  final String? subtitle;
  final List<Widget> children;
  final String submit;
  final VoidCallback? onSubmit;
  final bool destructive;
  final GlobalKey<FormState>? formKey;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final badge = destructive ? scheme.errorContainer : scheme.primaryContainer;
    final onBadge =
        destructive ? scheme.onErrorContainer : scheme.onPrimaryContainer;
    final compact = MediaQuery.sizeOf(context).width < 600;
    return Form(
      key: formKey,
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Flexible(
          child: SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(24, compact ? 4 : 24, 24, 8),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Container(
                width: 52,
                height: 52,
                decoration: ShapeDecoration(
                  color: badge,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(18)),
                ),
                child: Icon(icon, color: onBadge, size: 26),
              ),
              const SizedBox(height: 16),
              Text(title,
                  style: const TextStyle(
                      fontSize: 24,
                      height: 1.15,
                      letterSpacing: -.4,
                      fontWeight: FontWeight.w800)),
              if (subtitle != null) ...[
                const SizedBox(height: 6),
                Text(subtitle!,
                    style: TextStyle(
                        fontSize: 14,
                        height: 1.4,
                        color: scheme.onSurfaceVariant)),
              ],
              const SizedBox(height: 22),
              for (var i = 0; i < children.length; i++) ...[
                if (i > 0) const SizedBox(height: 22),
                children[i],
              ],
            ]),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 12, 24, 20),
          child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel')),
            const SizedBox(width: 8),
            FilledButton(
              style: destructive
                  ? FilledButton.styleFrom(
                      backgroundColor: scheme.error,
                      foregroundColor: scheme.onError)
                  : null,
              onPressed: onSubmit,
              child: Text(submit),
            ),
          ]),
        ),
      ]),
    );
  }
}

/// Asks before an action, with a tick-to-confirm for ones that cannot be
/// undone. Pops `true` when confirmed.
Future<bool> confirmAppAction(
  BuildContext context, {
  required IconData icon,
  required String title,
  required String message,
  required String action,
  bool destructive = false,
}) async =>
    await showAppForm<bool>(
        context,
        _Confirm(
            icon: icon,
            title: title,
            message: message,
            action: action,
            destructive: destructive)) ==
    true;

class _Confirm extends StatefulWidget {
  const _Confirm(
      {required this.icon,
      required this.title,
      required this.message,
      required this.action,
      required this.destructive});
  final IconData icon;
  final String title;
  final String message;
  final String action;
  final bool destructive;
  @override
  State<_Confirm> createState() => _ConfirmState();
}

class _ConfirmState extends State<_Confirm> {
  bool understood = false;
  @override
  Widget build(BuildContext context) => AppFormFrame(
        icon: widget.icon,
        title: widget.title,
        subtitle: widget.message,
        destructive: widget.destructive,
        submit: widget.action,
        onSubmit: widget.destructive && !understood
            ? null
            : () => Navigator.pop(context, true),
        children: [
          if (widget.destructive)
            AppConfirmCheck(
                value: understood,
                onChanged: (v) => setState(() => understood = v),
                label: 'I understand this cannot be undone'),
        ],
      );
}
