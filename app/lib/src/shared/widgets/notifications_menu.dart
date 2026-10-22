import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../app_dependencies.dart';
import '../../core/theme/app_surfaces.dart';
import '../../data/models/app_notification.dart';
import '../../features/account/presentation/account_panel.dart';
import 'overlay_panels.dart';
import 'skeleton.dart';

/// Opens the latest notifications, anchored at the app bar's left edge: on
/// desktop a floating popup like the profile menu, on phones a bottom sheet.
/// Opening it marks them read. Tapping a message notification opens its
/// space through [onOpenSpace] (by name); an invitation opens Invitations.
Future<void> showNotificationsMenu(
  BuildContext context,
  AppDependencies dependencies, {
  ValueChanged<String>? onOpenSpace,
}) async {
  final compact = MediaQuery.sizeOf(context).width < 820;
  final AppNotification? picked;
  if (compact) {
    picked = await showModalBottomSheet<AppNotification>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (sheetContext) => ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(sheetContext).height * .8,
        ),
        child: _NotificationsBody(
          dependencies: dependencies,
          onSelect: (n) => Navigator.pop(sheetContext, n),
        ),
      ),
    );
  } else {
    final size = MediaQuery.sizeOf(context);
    final width = math.min(392.0, size.width - 32);
    picked = await showGeneralDialog<AppNotification>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Close notifications',
      barrierColor: AppSurfaces.barrier,
      transitionDuration: const Duration(milliseconds: 260),
      pageBuilder: (dialogContext, _, __) => SafeArea(
        child: Align(
          alignment: Alignment.topLeft,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 66, 16, 16),
            child: FloatingPanelSurface(
              elevation: 6,
              child: SizedBox(
                width: width,
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: size.height * .7),
                  child: _NotificationsBody(
                    dependencies: dependencies,
                    onSelect: (n) => Navigator.pop(dialogContext, n),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
      transitionBuilder: (_, animation, __, child) {
        final curved =
            CurvedAnimation(parent: animation, curve: Curves.easeOutCubic);
        return FadeTransition(
          opacity: curved,
          child: ScaleTransition(
              alignment: Alignment.topLeft,
              scale: Tween(begin: .92, end: 1.0).animate(curved),
              child: child),
        );
      },
    );
  }
  if (picked == null || !context.mounted) return;
  if (picked.kind == 'invite') {
    await showAccountPanel(context, dependencies, AccountArea.invitations);
    return;
  }
  final open = onOpenSpace;
  if (open == null || picked.space.isEmpty) return;
  try {
    final spaces = await dependencies.service.fetchSpaces();
    for (final sp in spaces) {
      if (sp.id == picked.space) return open(sp.name);
    }
  } catch (_) {}
}

class _NotificationsBody extends StatefulWidget {
  const _NotificationsBody({required this.dependencies, required this.onSelect});
  final AppDependencies dependencies;
  final ValueChanged<AppNotification> onSelect;
  @override
  State<_NotificationsBody> createState() => _NotificationsBodyState();
}

class _NotificationsBodyState extends State<_NotificationsBody> {
  List<AppNotification>? items;
  bool failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final service = widget.dependencies.service;
    try {
      final page = await service.fetchNotifications();
      if (!mounted) return;
      setState(() => items = page.items);
      // Seen now: the unread marks stay for this look, then clear.
      if (page.unread > 0) await service.markNotificationsRead();
    } catch (_) {
      if (mounted) setState(() => failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final list = items;
    return Column(mainAxisSize: MainAxisSize.min, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 18, 12, 8),
        child: Row(children: [
          Icon(Icons.notifications_none_rounded, color: scheme.primary),
          const SizedBox(width: 10),
          const Expanded(
            child: Text('Notifications',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
          ),
          if (list != null && list.any((n) => !n.read))
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
              decoration: BoxDecoration(
                  color: scheme.primaryContainer,
                  borderRadius: BorderRadius.circular(20)),
              child: Text('${list.where((n) => !n.read).length} new',
                  style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: scheme.onPrimaryContainer)),
            ),
        ]),
      ),
      Flexible(child: _content(context, list)),
    ]);
  }

  Widget _content(BuildContext context, List<AppNotification>? list) {
    if (failed) {
      return const _Empty(
          icon: Icons.cloud_off_outlined,
          message: 'Notifications could not be loaded.');
    }
    if (list == null) {
      return const SkeletonList(itemCount: 4);
    }
    if (list.isEmpty) {
      return const _Empty(
          icon: Icons.notifications_off_outlined,
          message: "You're all caught up.");
    }
    return ListView.separated(
      shrinkWrap: true,
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 12),
      itemCount: list.length,
      separatorBuilder: (_, __) => const SizedBox(height: 2),
      itemBuilder: (context, i) =>
          _NotificationTile(list[i], onTap: () => widget.onSelect(list[i])),
    );
  }
}

class _NotificationTile extends StatelessWidget {
  const _NotificationTile(this.note, {required this.onTap});
  final AppNotification note;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final invite = note.kind == 'invite';
    return Material(
      color: note.read
          ? Colors.transparent
          : scheme.primaryContainer.withValues(alpha: .28),
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 11, 12, 11),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            CircleAvatar(
              radius: 18,
              backgroundColor: (invite ? scheme.tertiary : scheme.primary)
                  .withValues(alpha: .16),
              child: Icon(
                  invite
                      ? Icons.mark_email_unread_outlined
                      : Icons.forum_outlined,
                  size: 18,
                  color: invite ? scheme.tertiary : scheme.primary),
            ),
            const SizedBox(width: 12),
            Expanded(
              child:
                  Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Expanded(
                    child: Text(note.title.isEmpty ? 'Aseman' : note.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 14, fontWeight: FontWeight.w700)),
                  ),
                  const SizedBox(width: 8),
                  Text(_ago(note.createdAt),
                      style: TextStyle(
                          fontSize: 11, color: scheme.onSurfaceVariant)),
                ]),
                const SizedBox(height: 2),
                Text(note.body,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 13, color: scheme.onSurfaceVariant)),
              ]),
            ),
            if (!note.read) ...[
              const SizedBox(width: 8),
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: CircleAvatar(radius: 4, backgroundColor: scheme.primary),
              ),
            ],
          ]),
        ),
      ),
    );
  }

  static String _ago(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return 'now';
    if (d.inHours < 1) return '${d.inMinutes}m';
    if (d.inDays < 1) return '${d.inHours}h';
    if (d.inDays < 7) return '${d.inDays}d';
    return '${(d.inDays / 7).floor()}w';
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.icon, required this.message});
  final IconData icon;
  final String message;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(24, 28, 24, 36),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon,
              size: 38, color: Theme.of(context).colorScheme.onSurfaceVariant),
          const SizedBox(height: 10),
          Text(message, style: const TextStyle(fontWeight: FontWeight.w700)),
        ]),
      );
}
