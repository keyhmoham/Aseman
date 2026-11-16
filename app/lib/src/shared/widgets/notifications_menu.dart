import 'package:flutter/material.dart';

import '../../app_dependencies.dart';
import '../../core/layout/breakpoints.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/theme_chrome.dart';
import '../../core/theme/theme_roles.dart';
import '../../data/models/app_notification.dart';
import 'avatar.dart';
import 'avatar_face.dart';
import 'overlay_panels.dart';
import 'panel_empty.dart';
import 'segmented_tab_bar.dart';
import 'skeleton.dart';
import 'sky_ui.dart';

/// Opens the latest notifications. On desktop it is a full-height sheet stuck
/// to the leading edge; on phones it is a bottom sheet.
/// Opening it marks them read. The sheet is tabbed: **All** for notifications,
/// **Invites** for pending project invitations. Tapping a message notification
/// opens its space through [onOpenSpace] (by name); tapping an invite
/// notification switches to the Invites tab.
Future<void> showNotificationsMenu(
  BuildContext context,
  AppDependencies dependencies, {
  ValueChanged<String>? onOpenSpace,
}) async {
  final compact = MediaQuery.sizeOf(context).width < Breakpoints.expanded;
  final AppNotification? picked;
  if (compact) {
    picked = await showAppSheet<AppNotification>(
      context,
      ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * .8,
        ),
        child: Builder(builder: (sheetContext) {
          return _NotificationsBody(
            dependencies: dependencies,
            onSelect: (n) => Navigator.pop(sheetContext, n),
          );
        }),
      ),
      isScrollControlled: true,
    );
  } else {
    picked = await showDockedPanel<AppNotification>(
      context: context,
      width: 400,
      edge: DockedEdge.leading,
      barrierLabel: 'Close notifications',
      builder: (panelContext) => _NotificationsBody(
        dependencies: dependencies,
        onSelect: (n) => Navigator.pop(panelContext, n),
      ),
    );
  }
  if (picked == null || !context.mounted) return;
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

  List<Map<String, dynamic>>? invites;
  bool invitesFailed = false;
  bool invitesBusy = false;

  /// 0 = All, 1 = Invites.
  int tab = 0;

  @override
  void initState() {
    super.initState();
    _load();
    _loadInvites();
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

  Future<void> _loadInvites() async {
    try {
      final raw = await widget.dependencies.service.invokeAction(
        'spaces',
        'invitations_list',
      );
      if (!mounted) return;
      final map = raw is Map
          ? Map<String, dynamic>.from(raw)
          : const <String, dynamic>{};
      final rows = map['invitations'];
      setState(() {
        invites = rows is List
            ? [
                for (final e in rows)
                  if (e is Map) Map<String, dynamic>.from(e),
              ]
            : const <Map<String, dynamic>>[];
        invitesFailed = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          invitesFailed = true;
          invites = const [];
        });
      }
    }
  }

  Future<void> _inviteAction(String action, String invitationId) async {
    if (invitesBusy) return;
    setState(() => invitesBusy = true);
    try {
      await widget.dependencies.service.invokeAction(
        'spaces',
        action,
        body: {'invitation': invitationId},
      );
      if (!mounted) return;
      await _loadInvites();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Invitation: $error')),
      );
    } finally {
      if (mounted) setState(() => invitesBusy = false);
    }
  }

  void _onNotificationTap(AppNotification note) {
    if (note.kind == 'invite') {
      setState(() => tab = 1);
      return;
    }
    widget.onSelect(note);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final list = items;
    final pending = invites?.length ?? 0;
    final unread = list == null ? 0 : list.where((n) => !n.read).length;
    return Column(mainAxisSize: MainAxisSize.min, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 12, 8),
        child: SkySectionHeader(
          icon: Icons.notifications_none_rounded,
          title: 'Notifications',
          subtitle: tab == 0
              ? 'Mentions, replies and updates'
              : 'Project invitations waiting on you',
          dense: true,
          actions: [
            if (tab == 0 && unread > 0)
              SoftMetaChip(label: '$unread new', accent: scheme.primary),
            if (tab == 1 && pending > 0)
              SoftMetaChip(
                  label: '$pending pending', accent: scheme.tertiary),
          ],
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
        child: SegmentedTabBar(
          compact: true,
          labels: const ['All', 'Invites'],
          icons: const [
            Icons.notifications_none_rounded,
            Icons.mark_email_unread_outlined,
          ],
          selectedIndex: tab,
          onTap: (i) => setState(() => tab = i),
        ),
      ),
      Flexible(
        child: IndexedStack(
          index: tab,
          sizing: StackFit.expand,
          children: [
            _notificationsContent(context, list),
            _invitesContent(context),
          ],
        ),
      ),
    ]);
  }

  Widget _notificationsContent(
    BuildContext context,
    List<AppNotification>? list,
  ) {
    if (failed) {
      return const PanelEmpty(
          icon: Icons.cloud_off_outlined,
          title: 'Could not load',
          message: 'Notifications could not be loaded. Try again shortly.');
    }
    if (list == null) {
      return const SkeletonList(itemCount: 4);
    }
    if (list.isEmpty) {
      return const PanelEmpty(
          icon: Icons.notifications_none_outlined,
          title: "You're all caught up",
          message: 'New mentions, invites, and replies will show up here.');
    }
    return ListView.separated(
      shrinkWrap: true,
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.xs, AppSpacing.xxs, AppSpacing.xs, AppSpacing.sm),
      itemCount: list.length,
      separatorBuilder: (_, __) => const SizedBox(height: AppSpacing.xs - 2),
      itemBuilder: (context, i) =>
          _NotificationTile(list[i], onTap: () => _onNotificationTap(list[i])),
    );
  }

  Widget _invitesContent(BuildContext context) {
    if (invitesFailed) {
      return const PanelEmpty(
        icon: Icons.cloud_off_outlined,
        title: 'Could not load',
        message: 'Invitations could not be loaded. Try again shortly.',
      );
    }
    final rows = invites;
    if (rows == null) {
      return const SkeletonList(itemCount: 3);
    }
    if (rows.isEmpty) {
      return const PanelEmpty(
        icon: Icons.mark_email_read_outlined,
        title: 'No invitations',
        message: 'New project invitations will appear here.',
      );
    }
    return ListView.builder(
      shrinkWrap: true,
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.sm, AppSpacing.xxs, AppSpacing.sm, AppSpacing.sm),
      itemCount: rows.length,
      itemBuilder: (context, i) => _InviteTile(
        invite: rows[i],
        busy: invitesBusy,
        onDecline: () => _inviteAction(
          'invitation_decline',
          '${rows[i]['id'] ?? ''}',
        ),
        onAccept: () => _inviteAction(
          'invitation_accept',
          '${rows[i]['id'] ?? ''}',
        ),
      ),
    );
  }
}

class _InviteTile extends StatelessWidget {
  const _InviteTile({
    required this.invite,
    required this.busy,
    required this.onDecline,
    required this.onAccept,
  });

  final Map<String, dynamic> invite;
  final bool busy;
  final VoidCallback onDecline;
  final VoidCallback onAccept;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final space = invite['space'];
    final spaceMap = space is Map
        ? Map<String, dynamic>.from(space)
        : const <String, dynamic>{};
    final inviter = invite['inviter'];
    final inviterMap = inviter is Map
        ? Map<String, dynamic>.from(inviter)
        : const <String, dynamic>{};
    final name =
        '${spaceMap['name'] ?? invite['space_name'] ?? 'Project invitation'}';
    final handle =
        '${invite['inviter_handle'] ?? inviterMap['handle'] ?? 'a teammate'}';
    final avatar = invite['space_avatar'];
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm - 2),
      child: SoftCard(
        showOrb: false,
        padding: const EdgeInsets.all(AppSpacing.sm + 2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Builder(builder: (context) {
                  const radius = 20.0;
                  final size = radius * 2;
                  final corners = context.avatarBorderRadius(size);
                  final picture = Avatars.of(avatar);
                  return HaloRing(
                    borderRadius: corners,
                    child: AvatarFace(
                      size: size,
                      borderRadius: corners,
                      backgroundColor: ThemeRoles.wellFill(context),
                      foregroundImage: picture,
                      onImageError: picture == null ? null : (_, __) {},
                      child: Icon(Icons.folder_shared_outlined,
                          color: ThemeRoles.wellInk(context)),
                    ),
                  );
                }),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name,
                        style: const TextStyle(fontWeight: FontWeight.w900),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Invited by @$handle · ${_date(invite['created_at'])}',
                        style: TextStyle(
                          fontSize: 13,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: busy ? null : onDecline,
                    child: const Text('Decline'),
                  ),
                ),
                const SizedBox(width: AppSpacing.xs),
                Expanded(
                  child: FilledButton(
                    onPressed: busy ? null : onAccept,
                    child: const Text('Accept'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  static String _date(Object? value) {
    final raw = '$value'.trim();
    if (raw.isEmpty || raw == 'null') return 'recently';
    final parsed = DateTime.tryParse(raw);
    if (parsed == null) return raw;
    final d = DateTime.now().difference(parsed);
    if (d.inMinutes < 1) return 'just now';
    if (d.inHours < 1) return '${d.inMinutes}m ago';
    if (d.inDays < 1) return '${d.inHours}h ago';
    if (d.inDays < 7) return '${d.inDays}d ago';
    return '${parsed.year}-${parsed.month.toString().padLeft(2, '0')}-${parsed.day.toString().padLeft(2, '0')}';
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
    final accent = invite ? scheme.tertiary : scheme.primary;
    return SoftCard(
      onTap: onTap,
      selected: !note.read,
      showOrb: false,
      radius: 16,
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.sm, AppSpacing.sm - 1, AppSpacing.sm, AppSpacing.sm - 1),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: accent.withValues(alpha: .14),
            borderRadius: BorderRadius.circular(11),
          ),
          child: Icon(
              invite
                  ? Icons.mark_email_unread_outlined
                  : Icons.forum_outlined,
              size: 18,
              color: accent),
        ),
        const SizedBox(width: AppSpacing.sm),
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
              const SizedBox(width: AppSpacing.xs),
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
          const SizedBox(width: AppSpacing.xs),
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: CircleAvatar(radius: 4, backgroundColor: accent),
          ),
        ],
      ]),
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
