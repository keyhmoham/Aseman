import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../app_dependencies.dart';
import '../../../core/formatting/billing_units.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_shape.dart';
import '../../../core/utils/context_extensions.dart';
import '../../../data/models/bot.dart';
import '../../../data/models/profile.dart';
import '../../../data/models/space.dart';
import '../../../shared/widgets/app_form.dart';
import '../../../shared/widgets/avatar.dart';
import '../../../shared/widgets/mini_tag.dart';
import '../../../shared/widgets/overlay_panels.dart';
import '../../tools/connect/mcp_connect_dialog.dart';
import 'project_control_screen.dart';

/// Feature-rich settings panel for a workspace (space): profile & visibility,
/// stats, rooms, members & invites, and — as the very last section — a danger
/// zone to leave (non-owner) or delete (owner) the space.
class SpaceSettingsPanel extends StatefulWidget {
  const SpaceSettingsPanel({
    super.key,
    required this.dependencies,
    required this.space,
    this.onExit,
    this.onUpdated,
  });

  final AppDependencies dependencies;
  final Workspace space;

  /// Invoked after the space was left or deleted, so the caller can close the
  /// panel and switch away.
  final VoidCallback? onExit;

  /// Invoked after the space profile (name/description/visibility) changed.
  final ValueChanged<Workspace>? onUpdated;

  @override
  State<SpaceSettingsPanel> createState() => _SpaceSettingsPanelState();
}

class _SpaceSettingsPanelState extends State<SpaceSettingsPanel> {
  late Workspace _space = widget.space;
  SpaceProfile? _profile;
  List<Map<String, dynamic>> _members = const [];
  List<WorkspaceRoom> _rooms = const [];
  Map<String, dynamic> _usage = const {};

  /// The space's tools that each person connects with their own account,
  /// and whether the caller has connected theirs here.
  List<({String id, String name, bool connected})> _accounts = const [];
  late final TextEditingController _name =
      TextEditingController(text: _space.name);
  late final TextEditingController _desc =
      TextEditingController(text: _space.description);
  late bool _public = _space.public;
  bool _loading = true;
  bool _busy = false;
  bool _dirty = false;

  String get _me =>
      widget.dependencies.sessionController.session?.accountId ?? '';

  bool get _isOwner =>
      _space.ownerId == _me || _space.role == 'owner' || _myRole == 'owner';

  /// Owners and admins may manage rooms, members and roles.
  bool get _canManage => _isOwner || _space.role == 'admin';

  @override
  void initState() {
    super.initState();
    _name.addListener(_markDirty);
    _desc.addListener(_markDirty);
    _load();
  }

  @override
  void dispose() {
    _name.removeListener(_markDirty);
    _desc.removeListener(_markDirty);
    _name.dispose();
    _desc.dispose();
    super.dispose();
  }

  void _markDirty() {
    if (!mounted) return;
    setState(() => _dirty = _name.text.trim() != _space.name ||
        _desc.text.trim() != _space.description ||
        _public != _space.public);
  }

  void _setPublic(bool value) {
    setState(() => _public = value);
    _markDirty();
  }

  Future<void> _load() async {
    final deps = widget.dependencies;
    setState(() => _loading = true);
    try {
      final results = await Future.wait<Object>([
        deps.service.fetchSpaceProfile(_space.id),
        deps.service.fetchSpaceMembers(_space.id),
        deps.service.fetchRoomsForSpace(_space.id),
      ]);
      if (!mounted) return;
      final profile = results[0] as SpaceProfile;
      final members = results[1] as List<Map<String, dynamic>>;
      final rooms = results[2] as List<WorkspaceRoom>;
      final fresh = Workspace(
        id: _space.id,
        ownerId: profile.ownerId.isEmpty ? _space.ownerId : profile.ownerId,
        name: profile.name.isEmpty ? _space.name : profile.name,
        description: profile.description,
        public: profile.public,
        home: profile.home,
        role: _space.role,
      );
      setState(() {
        _profile = profile;
        _members = members;
        _rooms = rooms;
        _space = fresh;
        _public = fresh.public;
        _name.text = fresh.name;
        _desc.text = fresh.description;
        _loading = false;
      });
      unawaited(_loadUsage());
      unawaited(_loadAccounts());
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
      context.showMessage('Could not load workspace settings.');
    }
  }

  /// Loads the LLM token usage rollup (best-effort: a failure never blocks the
  /// rest of the panel).
  Future<void> _loadUsage() async {
    try {
      final usage =
          await widget.dependencies.service.fetchUsageSummary(_space.id);
      if (!mounted) return;
      setState(() => _usage = usage);
    } catch (_) {}
  }

  /// Best-effort, like usage: a failure only hides the section.
  Future<void> _loadAccounts() async {
    try {
      final service = widget.dependencies.service;
      final results = await Future.wait<Object>([
        service.toolConnections(_space.id),
        service.fetchSpaceBots(_space.id),
      ]);
      final states = results[0]
          as Map<String, ({String auth, bool connected, String name})>;
      final inSpace = {for (final b in results[1] as List<Bot>) b.id};
      if (!mounted) return;
      setState(() => _accounts = [
            for (final e in states.entries)
              if (e.value.auth == 'user' && inSpace.contains(e.key))
                (id: e.key, name: e.value.name, connected: e.value.connected),
          ]);
    } catch (_) {}
  }

  Future<void> _connect(String botId, String name, bool reconnect) async {
    final ok = await connectMcpTool(context, widget.dependencies.service,
        botId: botId, spaceId: _space.id, name: name, reconnect: reconnect);
    if (ok) await _loadAccounts();
  }

  Future<void> _openProjectControls() => showFloatingPanel(
        context,
        ProjectControlScreen(
          dependencies: widget.dependencies,
          spaceId: _space.id,
          spaceName: _space.name,
        ),
        maxWidth: 1180,
      );

  String get _myRole {
    for (final m in _members) {
      if (m['member_id'] == _me) return m['role'] as String? ?? '';
    }
    return _space.role;
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      context.showMessage('Workspace name cannot be empty.');
      return;
    }
    setState(() => _busy = true);
    try {
      await widget.dependencies.service.updateSpace(
        _space.id,
        name: name == _space.name ? null : name,
        description: _desc.text.trim(),
        public: _public == _space.public ? null : _public,
      );
      if (!mounted) return;
      setState(() {
        _space = Workspace(
          id: _space.id,
          ownerId: _space.ownerId,
          name: name,
          description: _desc.text.trim(),
          public: _public,
          home: _space.home,
          role: _space.role,
        );
        _dirty = false;
        _busy = false;
      });
      widget.onUpdated?.call(_space);
      context.showMessage('Workspace settings saved.');
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      context.showMessage('Save failed: $e');
    }
  }

  // ── rooms ────────────────────────────────────────────────────────────────

  Future<void> _createRoom() async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) => const _PromptDialog(
        title: 'New room',
        label: 'Room name',
        confirmLabel: 'Create',
      ),
    );
    if (name == null || name.trim().isEmpty || !mounted) return;
    setState(() => _busy = true);
    try {
      await widget.dependencies.service.createRoom(_space.id, name.trim(), '');
      final rooms =
          await widget.dependencies.service.fetchRoomsForSpace(_space.id);
      if (!mounted) return;
      setState(() {
        _rooms = rooms;
        _busy = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      context.showMessage('Create room failed: $e');
    }
  }

  Future<void> _deleteRoom(WorkspaceRoom room) async {
    final ok = await _confirm(
      title: 'Delete “${room.name}”?',
      message: 'This deletes the room and its messages. This cannot be undone.',
      confirmLabel: 'Delete room',
      destructive: true,
    );
    if (ok != true || !mounted) return;
    try {
      await widget.dependencies.service.deleteRoom(room.id);
      if (!mounted) return;
      setState(() => _rooms = _rooms.where((r) => r.id != room.id).toList());
      context.showMessage('Room deleted.');
    } catch (e) {
      if (!mounted) return;
      context.showMessage('Delete failed: $e');
    }
  }

  // ── members ──────────────────────────────────────────────────────────────

  Future<void> _invite() async {
    final invitee = await showDialog<AccountInvite>(
      context: context,
      builder: (_) => _InviteDialog(dependencies: widget.dependencies),
    );
    if (invitee == null || !mounted) return;
    setState(() => _busy = true);
    try {
      await widget.dependencies.service
          .inviteToSpace(_space.id, invitee.id, role: invitee.role);
      final members =
          await widget.dependencies.service.fetchSpaceMembers(_space.id);
      if (!mounted) return;
      setState(() {
        _members = members;
        _busy = false;
      });
      context.showMessage('@${invitee.handle} invited to ${_space.name}.');
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      context.showMessage('Invite failed: $e');
    }
  }

  Future<void> _setRole(Map<String, dynamic> member, String role) async {
    try {
      await widget.dependencies.service
          .setMemberRole(_space.id, member['member_id'] as String, role);
      if (!mounted) return;
      setState(() {
        _members = [
          for (final m in _members)
            if (m['member_id'] == member['member_id'])
              {...m, 'role': role}
            else
              m,
        ];
      });
      context.showMessage('Role updated.');
    } catch (e) {
      if (!mounted) return;
      context.showMessage('Role update failed: $e');
    }
  }

  Future<void> _removeMember(Map<String, dynamic> member) async {
    final handle = member['handle'] as String? ?? 'this member';
    final ok = await _confirm(
      title: 'Remove @$handle?',
      message: 'They will lose access to ${_space.name} and its rooms.',
      confirmLabel: 'Remove member',
      destructive: true,
    );
    if (ok != true || !mounted) return;
    try {
      await widget.dependencies.service
          .removeSpaceMember(_space.id, member['member_id'] as String);
      if (!mounted) return;
      setState(() => _members = _members
          .where((m) => m['member_id'] != member['member_id'])
          .toList());
      context.showMessage('@$handle removed.');
    } catch (e) {
      if (!mounted) return;
      context.showMessage('Remove failed: $e');
    }
  }

  // ── danger zone (last) ───────────────────────────────────────────────────

  Future<void> _leave() async {
    final ok = await _confirm(
      title: 'Leave ${_space.name}?',
      message:
          'You will lose access to this workspace, its rooms and its agents. '
          'You can rejoin later if you are invited again.',
      confirmLabel: 'Leave workspace',
      destructive: true,
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await widget.dependencies.service.leaveSpace(_space.id);
      if (!mounted) return;
      setState(() => _busy = false);
      context.showMessage('You left ${_space.name}.');
      widget.onExit?.call();
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      context.showMessage('Leave failed: $e');
    }
  }

  Future<void> _delete() async {
    final ok = await _confirm(
      title: 'Delete ${_space.name}?',
      message:
          'This permanently deletes the workspace, its rooms, files, posts '
          'and agents. This cannot be undone.',
      confirmLabel: 'Delete workspace',
      destructive: true,
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await widget.dependencies.service.deleteSpace(_space.id);
      if (!mounted) return;
      setState(() => _busy = false);
      context.showMessage('${_space.name} was deleted.');
      widget.onExit?.call();
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      context.showMessage('Delete failed: $e');
    }
  }

  Future<bool?> _confirm({
    required String title,
    required String message,
    required String confirmLabel,
    required bool destructive,
  }) =>
      confirmAppAction(context,
          icon: destructive
              ? Icons.warning_amber_rounded
              : Icons.help_outline_rounded,
          title: title,
          message: message,
          action: confirmLabel,
          destructive: destructive);

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return SafeArea(
        child: Column(children: [
      Padding(
          padding: const EdgeInsets.fromLTRB(24, 18, 12, 12),
          child: Row(children: [
            AppAvatar(_space.initials, color: colors.primary),
            const SizedBox(width: 12),
            Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  const Text('Workspace settings',
                      style: TextStyle(
                          fontSize: 24,
                          letterSpacing: -.4,
                          fontWeight: FontWeight.w800)),
                  Text(_space.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 11, color: colors.onSurfaceVariant)),
                ])),
            if (_busy)
              const Padding(
                  padding: EdgeInsets.only(right: 8),
                  child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))),
            IconButton(
                tooltip: 'Files, computer, apps, routines, memory and plugins',
                onPressed: _openProjectControls,
                icon: const Icon(Icons.dashboard_customize_outlined)),
            IconButton.filledTonal(
                tooltip: 'Close',
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close_rounded)),
          ])),
      Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(24, 20, 24, 28),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _overviewCard(context),
                        const SizedBox(height: 16),
                        _statsCard(context),
                        const SizedBox(height: 16),
                        _roomsCard(context),
                        const SizedBox(height: 16),
                        _membersCard(context),
                        if (_accounts.isNotEmpty) ...[
                          const SizedBox(height: 16),
                          _accountsCard(context),
                        ],
                        const SizedBox(height: 16),
                        _usageCard(context),
                        const SizedBox(height: 16),
                        _dangerZoneCard(context),
                      ]))),
    ]));
  }

  // ── overview ─────────────────────────────────────────────────────────────

  Widget _overviewCard(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return _Section(
      title: 'Overview',
      icon: Icons.info_outline_rounded,
      trailing: _dirty
          ? FilledButton(
              onPressed: _busy ? null : _save,
              child: const Text('Save changes'))
          : null,
      child: Column(children: [
        Row(children: [
          Expanded(
              child: TextField(
            controller: _name,
            decoration: const InputDecoration(
              labelText: 'Workspace name',
              prefixIcon: Icon(Icons.badge_outlined),
            ),
          )),
        ]),
        const SizedBox(height: 14),
        TextField(
          controller: _desc,
          minLines: 2,
          maxLines: 4,
          decoration: const InputDecoration(
            labelText: 'Description',
            prefixIcon: Icon(Icons.notes_rounded),
            alignLabelWithHint: true,
          ),
        ),
        const SizedBox(height: 14),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Public workspace'),
          subtitle: const Text(
              'Anyone can discover and join. Private spaces require an invite.'),
          value: _public,
          onChanged: _isOwner ? _setPublic : null,
        ),
        if (!_isOwner)
          Text(
            'Only the workspace owner can change visibility.',
            style: TextStyle(fontSize: 10, color: colors.onSurfaceVariant),
          ),
        const SizedBox(height: 6),
        Wrap(spacing: 8, runSpacing: 8, children: [
          MiniTag(
              _public ? 'PUBLIC' : 'PRIVATE',
              _public
                  ? AppColors.success
                  : Theme.of(context).colorScheme.onSurfaceVariant),
          if (_space.home) const MiniTag('HOME', AppColors.primary),
          MiniTag(
              'OWNER · ${_profile?.ownerHandle ?? ''}',
              _isOwner
                  ? AppColors.cyan
                  : Theme.of(context).colorScheme.onSurfaceVariant),
          if (_myRole.isNotEmpty)
            MiniTag('YOUR ROLE · ${_myRole.toUpperCase()}', AppColors.warning),
        ]),
      ]),
    );
  }

  // ── stats ────────────────────────────────────────────────────────────────

  Widget _statsCard(BuildContext context) {
    final p = _profile;
    return _Section(
      title: 'At a glance',
      icon: Icons.insights_rounded,
      child: p == null
          ? const Center(
              child: Padding(
                  padding: EdgeInsets.all(16),
                  child: CircularProgressIndicator()))
          : Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                _StatTile(
                    icon: Icons.group_outlined,
                    label: 'Members',
                    value: p.memberCount),
                _StatTile(
                    icon: Icons.forum_outlined,
                    label: 'Rooms',
                    value: p.roomCount),
                _StatTile(
                    icon: Icons.smart_toy_outlined,
                    label: 'Agents',
                    value: p.agentCount),
                _StatTile(
                    icon: Icons.dynamic_feed_outlined,
                    label: 'Posts',
                    value: p.postCount),
                _StatTile(
                    icon: Icons.folder_outlined,
                    label: 'Files',
                    value: p.fileCount),
              ],
            ),
    );
  }

  // ── rooms ────────────────────────────────────────────────────────────────

  Widget _roomsCard(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return _Section(
      title: 'Rooms',
      icon: Icons.forum_outlined,
      trailing: _canManage
          ? IconButton.filledTonal(
              visualDensity: VisualDensity.compact,
              tooltip: 'New room',
              onPressed: _busy ? null : _createRoom,
              icon: const Icon(Icons.add_rounded, size: 19))
          : null,
      child: _rooms.isEmpty
          ? Text('No rooms yet.',
              style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant))
          : Column(children: [
              for (final room in _rooms)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.circle_outlined,
                      size: 20, color: colors.onSurfaceVariant),
                  title: Text(room.name,
                      style: const TextStyle(fontWeight: FontWeight.w700)),
                  subtitle: room.topic.isEmpty ? null : Text(room.topic),
                  trailing: _canManage
                      ? IconButton(
                          tooltip: 'Delete room',
                          visualDensity: VisualDensity.compact,
                          onPressed: _busy ? null : () => _deleteRoom(room),
                          icon: const Icon(Icons.delete_outline_rounded,
                              size: 18),
                          color: AppColors.danger)
                      : null,
                ),
            ]),
    );
  }

  // ── members ──────────────────────────────────────────────────────────────

  Widget _accountsCard(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return _Section(
      title: 'Your app connections',
      icon: Icons.link_rounded,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(
            'These apps run with each person\'s own account. Connect yours to use them here; nobody else in the space sees it.',
            style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant)),
        for (final a in _accounts)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(
                a.connected ? Icons.link_rounded : Icons.link_off_rounded,
                color:
                    a.connected ? AppColors.success : colors.onSurfaceVariant),
            title: Text(a.name.isEmpty ? 'App' : a.name,
                style: const TextStyle(fontWeight: FontWeight.w700)),
            subtitle: Text(a.connected ? 'Connected' : 'Not connected'),
            trailing: a.connected
                ? TextButton(
                    onPressed: () => _connect(a.id, a.name, true),
                    child: const Text('Reconnect'))
                : FilledButton.tonal(
                    onPressed: () => _connect(a.id, a.name, false),
                    child: const Text('Connect')),
          ),
      ]),
    );
  }

  Widget _membersCard(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final humanMembers = _members.where((m) => m['kind'] != 'bot').toList();
    return _Section(
      title: 'Members',
      icon: Icons.people_outline_rounded,
      trailing: IconButton.filledTonal(
        visualDensity: VisualDensity.compact,
        tooltip: 'Invite member',
        onPressed: _busy ? null : _invite,
        icon: const Icon(Icons.person_add_alt_1_rounded, size: 19),
      ),
      child: humanMembers.isEmpty
          ? Text('No members yet — invite someone to collaborate.',
              style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant))
          : Column(children: [
              for (final m in humanMembers)
                _MemberTile(
                  member: m,
                  isMe: m['member_id'] == _me,
                  isOwner: (m['role'] as String? ?? '') == 'owner',
                  canManage: _canManage,
                  onRole: (role) => _setRole(m, role),
                  onRemove: () => _removeMember(m),
                ),
            ]),
    );
  }

  // ── LLM token usage (per room / per agent) ───────────────────────────────

  Widget _usageCard(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final rooms = _usage['rooms'] as List? ?? const [];
    final agents = _usage['agents'] as List? ?? const [];
    final totalIn = (_usage['total_in'] as num?)?.toInt() ?? 0;
    final totalOut = (_usage['total_out'] as num?)?.toInt() ?? 0;
    final totalCost = (_usage['total_cost'] as num?)?.toInt() ?? 0;
    return _Section(
      title: 'LLM usage',
      icon: Icons.bolt_rounded,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (totalIn > 0 || totalOut > 0)
          Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Text(
                '$totalIn in / $totalOut out tokens'
                '${totalCost > 0 ? ' · ${formatLedgerCredits(totalCost, exact: true)}' : ''}',
                style:
                    const TextStyle(fontWeight: FontWeight.w800, fontSize: 13),
              )),
        if (rooms.isEmpty)
          Text('No token usage yet.',
              style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant))
        else ...[
          _usageBreakdown('Per room chat', rooms),
          const SizedBox(height: 14),
          _usageBreakdown('Per agent', agents),
        ],
      ]),
    );
  }

  Widget _usageBreakdown(String label, List<dynamic> rows) {
    final colors = Theme.of(context).colorScheme;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label,
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800)),
      const SizedBox(height: 6),
      for (final row in rows)
        if (row is Map)
          Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(children: [
                Expanded(
                    child: Text(_usageLabel(row),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12))),
                Text(
                  '${_usageTokens(row, true)} in / ${_usageTokens(row, false)} out',
                  style:
                      TextStyle(fontSize: 11, color: colors.onSurfaceVariant),
                ),
                const SizedBox(width: 8),
                Text('${row['requests'] ?? 0}×',
                    style: TextStyle(
                        fontSize: 10, color: colors.onSurfaceVariant)),
              ])),
    ]);
  }

  String _usageLabel(Map<dynamic, dynamic> row) {
    final label = row['label'] as String? ?? '';
    final key = row['key'] as String? ?? '';
    if (label.isNotEmpty && label != '_') return label;
    return key == '_' ? 'Workspace' : 'Room';
  }

  int _usageTokens(Map<dynamic, dynamic> row, bool isIn) {
    final v = isIn ? row['tokens_in'] : row['tokens_out'];
    return (v as num?)?.toInt() ?? 0;
  }

  // ── danger zone (must stay the last section) ─────────────────────────────

  Widget _dangerZoneCard(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
      decoration: BoxDecoration(
        color: AppColors.danger.withValues(alpha: .06),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.danger.withValues(alpha: .35)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Row(children: [
          Icon(Icons.warning_amber_rounded, color: AppColors.danger, size: 20),
          SizedBox(width: 10),
          Text('Danger zone',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900)),
        ]),
        const SizedBox(height: 12),
        if (_isOwner) ...[
          Text(
            'Delete this workspace forever. All rooms, files, posts and '
            'agents will be removed. This cannot be undone.',
            style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
          ),
          const SizedBox(height: 14),
          SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                style: FilledButton.styleFrom(
                    backgroundColor: AppColors.danger,
                    foregroundColor: Colors.white),
                onPressed: _busy ? null : _delete,
                icon: const Icon(Icons.delete_forever_rounded, size: 18),
                label: const Text('Delete workspace'),
              )),
        ] else ...[
          Text(
            'Leave this workspace. You will lose access to its rooms and '
            'agents. The workspace remains available to its other members.',
            style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
          ),
          const SizedBox(height: 14),
          SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                style: FilledButton.styleFrom(
                    backgroundColor: AppColors.danger,
                    foregroundColor: Colors.white),
                onPressed: _busy ? null : _leave,
                icon: const Icon(Icons.logout_rounded, size: 18),
                label: const Text('Leave workspace'),
              )),
        ],
      ]),
    );
  }
}

// ── shared building blocks ──────────────────────────────────────────────────

class _Section extends StatelessWidget {
  const _Section({
    required this.title,
    required this.icon,
    required this.child,
    this.trailing,
  });

  final String title;
  final IconData icon;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: colors.surfaceContainerLow,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppShape.card)),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Container(
              width: 40,
              height: 40,
              decoration: ShapeDecoration(
                  color: colors.secondaryContainer,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14))),
              child: Icon(icon, size: 21, color: colors.onSecondaryContainer),
            ),
            const SizedBox(width: 12),
            Expanded(
                child: Text(title,
                    style: const TextStyle(
                        fontSize: 18, fontWeight: FontWeight.w800))),
            if (trailing != null) trailing!,
          ]),
          const SizedBox(height: 16),
          child,
        ]),
      ),
    );
  }
}

class _StatTile extends StatelessWidget {
  const _StatTile({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final int value;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      width: math.max(92, (MediaQuery.sizeOf(context).width - 120) / 5),
      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 10),
      decoration: BoxDecoration(
          color: colors.surfaceContainer,
          borderRadius: BorderRadius.circular(AppShape.inner)),
      child: Column(children: [
        Icon(icon, size: 22, color: colors.primary),
        const SizedBox(height: 8),
        Text('$value',
            style: const TextStyle(
                fontSize: 26, letterSpacing: -.5, fontWeight: FontWeight.w800)),
        Text(label,
            style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant)),
      ]),
    );
  }
}

class _MemberTile extends StatelessWidget {
  const _MemberTile({
    required this.member,
    required this.isMe,
    required this.isOwner,
    required this.canManage,
    required this.onRole,
    required this.onRemove,
  });

  final Map<String, dynamic> member;
  final bool isMe;
  final bool isOwner;
  final bool canManage;
  final ValueChanged<String> onRole;
  final VoidCallback onRemove;

  String get _handle => member['handle'] as String? ?? 'user';
  String get _role => member['role'] as String? ?? 'member';

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final roleColor = switch (_role) {
      'owner' => AppColors.cyan,
      'admin' => AppColors.warning,
      _ => Theme.of(context).colorScheme.onSurfaceVariant,
    };
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: AppAvatar(_handle.isEmpty ? '?' : _handle[0].toUpperCase(),
          color: colors.primary),
      title: Row(children: [
        Flexible(
            child: Text('@$_handle',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w700))),
        if (isMe) ...[
          const SizedBox(width: 6),
          const MiniTag('YOU', AppColors.primary),
        ],
      ]),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 3),
        child: MiniTag(_role.toUpperCase(), roleColor),
      ),
      trailing: canManage && !isOwner && !isMe
          ? PopupMenuButton<String>(
              tooltip: 'Manage member',
              onSelected: (value) {
                if (value == 'remove') {
                  onRemove();
                } else {
                  onRole(value);
                }
              },
              itemBuilder: (_) => [
                const PopupMenuItem(
                    value: 'member', child: Text('Set as member')),
                const PopupMenuItem(
                    value: 'admin', child: Text('Set as admin')),
                const PopupMenuItem(
                    value: 'guest', child: Text('Set as guest')),
                const PopupMenuDivider(),
                const PopupMenuItem(
                  value: 'remove',
                  child: Text('Remove from workspace',
                      style: TextStyle(color: AppColors.danger)),
                ),
              ],
            )
          : null,
    );
  }
}

/// Result of the invite dialog.
class AccountInvite {
  const AccountInvite(
      {required this.id, required this.handle, this.role = 'member'});
  final String id;
  final String handle;
  final String role;
}

class _InviteDialog extends StatefulWidget {
  const _InviteDialog({required this.dependencies});
  final AppDependencies dependencies;
  @override
  State<_InviteDialog> createState() => _InviteDialogState();
}

class _InviteDialogState extends State<_InviteDialog> {
  final controller = TextEditingController();
  List<Map<String, dynamic>> _results = const [];
  bool _searching = false;
  String? _inviteeId;
  String _role = 'member';

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  Future<void> _search(String query) async {
    if (query.trim().isEmpty) {
      setState(() => _results = const []);
      return;
    }
    setState(() => _searching = true);
    try {
      final users =
          await widget.dependencies.service.searchUsers(query.trim(), limit: 8);
      if (!mounted) return;
      setState(() {
        _results = users
            .where((u) => u.kind == 'user')
            .map((u) => {'id': u.id, 'handle': u.handle})
            .toList();
        _searching = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _searching = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Invite to workspace'),
      content: SizedBox(
        width: 380,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
            controller: controller,
            autofocus: true,
            onChanged: _search,
            decoration: const InputDecoration(
                labelText: 'Search by handle',
                prefixIcon: Icon(Icons.search_rounded)),
          ),
          const SizedBox(height: 14),
          if (_searching)
            const Center(
                child: Padding(
                    padding: EdgeInsets.all(8),
                    child: SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2))))
          else if (_results.isNotEmpty)
            ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 180),
                child: ListView(shrinkWrap: true, children: [
                  for (final user in _results)
                    RadioListTile<String>(
                      dense: true,
                      value: user['id'] as String,
                      groupValue: _inviteeId,
                      onChanged: (v) => setState(() => _inviteeId = v),
                      title: Text('@${user['handle']}',
                          style: const TextStyle(fontSize: 13)),
                    ),
                ])),
          const SizedBox(height: 6),
          Row(children: [
            const Text('Role: ', style: TextStyle(fontSize: 12)),
            const SizedBox(width: 8),
            for (final role in const ['member', 'admin', 'guest'])
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ChoiceChip(
                  label: Text(role, style: const TextStyle(fontSize: 11)),
                  selected: _role == role,
                  onSelected: (_) => setState(() => _role = role),
                ),
              ),
          ]),
        ]),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel')),
        FilledButton(
          onPressed: _inviteeId == null
              ? null
              : () {
                  final user = _results.firstWhere((u) => u['id'] == _inviteeId,
                      orElse: () => const {});
                  Navigator.pop(
                      context,
                      AccountInvite(
                          id: _inviteeId!,
                          handle: user['handle'] as String? ?? '',
                          role: _role));
                },
          child: const Text('Send invite'),
        ),
      ],
    );
  }
}

class _PromptDialog extends StatefulWidget {
  const _PromptDialog({
    required this.title,
    required this.label,
    required this.confirmLabel,
  });
  final String title;
  final String label;
  final String confirmLabel;
  @override
  State<_PromptDialog> createState() => _PromptDialogState();
}

class _PromptDialogState extends State<_PromptDialog> {
  final controller = TextEditingController();
  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 360,
        child: TextField(
          controller: controller,
          autofocus: true,
          onSubmitted: (v) {
            if (v.trim().isNotEmpty) Navigator.pop(context, v.trim());
          },
          decoration: InputDecoration(labelText: widget.label),
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel')),
        FilledButton(
          onPressed: () {
            final v = controller.text.trim();
            if (v.isNotEmpty) Navigator.pop(context, v);
          },
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}

/// Open the space settings panel as a responsive floating panel.
Future<void> showSpaceSettings(
  BuildContext context, {
  required AppDependencies dependencies,
  required Workspace space,
  VoidCallback? onExit,
  ValueChanged<Workspace>? onUpdated,
}) =>
    showFloatingPanel(
      context,
      SpaceSettingsPanel(
        dependencies: dependencies,
        space: space,
        onExit: onExit,
        onUpdated: onUpdated,
      ),
      maxWidth: 720,
      barrierLabel: 'Workspace settings',
    );
