import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../app_dependencies.dart';
import '../../data/models/space.dart';

/// Shared top app bar: brand + workspace switcher on the left, platform
/// actions on the right. Optional callbacks hide the corresponding controls.
class WorkspaceHeader extends StatelessWidget {
  const WorkspaceHeader({
    super.key,
    required this.workspace,
    required this.compact,
    this.room,
    this.onOpenNavigation,
    required this.onOpenWorkspaces,
    this.onGoHome,
    this.onOpenAdmin,
    this.onOpenSpaceSettings,
    required this.onOpenProfile,
    this.onOpenSearchFeed,
    this.handle = '',
  });

  final String workspace;
  final String? room;
  final bool compact;
  final String handle;
  final VoidCallback? onOpenNavigation;
  final VoidCallback onOpenWorkspaces;
  final VoidCallback? onGoHome;
  final VoidCallback? onOpenAdmin;
  final VoidCallback? onOpenSpaceSettings;
  final VoidCallback onOpenProfile;
  final VoidCallback? onOpenSearchFeed;

  @override
  Widget build(BuildContext context) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
      child: Row(children: [
        if (compact && onOpenNavigation != null) ...[
          IconButton(
              onPressed: onOpenNavigation,
              icon: const Icon(Icons.menu_rounded)),
          const SizedBox(width: 4),
        ],
        Flexible(
          child: InkWell(
              onTap: onOpenWorkspaces,
              borderRadius: BorderRadius.circular(20),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.blur_on_rounded, size: 30),
                const SizedBox(width: 9),
                const Flexible(
                  child: Text('TRADERA',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 2)),
                ),
                if (!compact) ...[
                  const SizedBox(width: 8),
                  Text(workspace,
                      style: TextStyle(
                          fontSize: 10,
                          color:
                              Theme.of(context).colorScheme.onSurfaceVariant)),
                  const Icon(Icons.expand_more_rounded, size: 16),
                ],
              ])),
        ),
        if (room != null) ...[
          SizedBox(width: compact ? 4 : 14),
          if (!compact) const Icon(Icons.chevron_right_rounded),
          if (onGoHome != null)
            IconButton(
                onPressed: onGoHome,
                tooltip: 'Workspace home',
                icon: const Icon(Icons.home_outlined, size: 18)),
          if (!compact)
            Text(room!, style: const TextStyle(fontWeight: FontWeight.w700))
        ],
        const Spacer(),
        if (!compact) ...[
          const _LivePill(),
          const SizedBox(width: 8),
        ],
        if (!compact && onOpenAdmin != null) ...[
          IconButton.filledTonal(
              onPressed: onOpenAdmin,
              icon: const Icon(Icons.space_dashboard_outlined)),
          const SizedBox(width: 8),
        ],
        if (onOpenSpaceSettings != null) ...[
          IconButton(
              onPressed: onOpenSpaceSettings,
              tooltip: 'Workspace settings',
              icon: const Icon(Icons.settings_outlined)),
        ],
        if (onOpenSearchFeed != null) ...[
          IconButton(
              onPressed: onOpenSearchFeed,
              tooltip: 'Search feed',
              icon: const Icon(Icons.explore_outlined)),
        ],
        InkWell(
            onTap: onOpenProfile,
            child: CircleAvatar(
                child: Text(handle.isEmpty ? 'ME' : handle[0].toUpperCase())))
      ]));
}

class _LivePill extends StatelessWidget {
  const _LivePill();
  @override
  Widget build(BuildContext context) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
          color: Colors.green.withValues(alpha: .12),
          borderRadius: BorderRadius.circular(20)),
      child: const Row(children: [
        Icon(Icons.circle, color: Colors.greenAccent, size: 8),
        SizedBox(width: 7),
        Text('Markets live',
            style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700))
      ]));
}

/// Workspace switcher dialog/sheet with a searchable grid of the user's real
/// spaces. [dependencies] lists and creates spaces through the backend.
class WorkspacePicker extends StatefulWidget {
  const WorkspacePicker(
      {super.key,
      required this.current,
      required this.onPick,
      this.dependencies,
      this.onSettings});
  final String current;
  final ValueChanged<String> onPick;
  final AppDependencies? dependencies;
  final void Function(Workspace space)? onSettings;
  @override
  State<WorkspacePicker> createState() => _WorkspacePickerState();
}

class _WorkspacePickerState extends State<WorkspacePicker> {
  String query = '';
  List<Workspace> spaces = [];
  final Map<String, int> _roomCounts = {};
  bool loading = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final deps = widget.dependencies;
    if (deps == null) return;
    setState(() => loading = true);
    try {
      final list = await deps.service.fetchSpaces();
      final counts = <String, int>{};
      for (final sp in list) {
        try {
          final rooms = await deps.service.fetchRoomsForSpace(sp.id);
          counts[sp.name] = rooms.length;
        } catch (_) {}
      }
      if (!mounted) return;
      setState(() {
        spaces = list;
        _roomCounts.addAll(counts);
        loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => loading = false);
    }
  }

  List<String> get _names {
    final filtered = spaces
        .map((s) => s.name)
        .where((e) => e.toLowerCase().contains(query.toLowerCase()))
        .toList();
    return filtered;
  }

  Future<void> _create() async {
    final deps = widget.dependencies;
    final name = await showDialog<String>(
      context: context,
      builder: (_) => const _CreateWorkspaceDialog(),
    );
    if (name == null || name.trim().isEmpty || deps == null || !mounted) return;
    try {
      final created = await deps.service.createSpace(name.trim(), '');
      setState(() => spaces = [...spaces, created]);
      widget.onPick(created.name);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Create failed: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 820;
    final names = _names;
    return SafeArea(
        child: Center(
            child: Material(
                color: Colors.transparent,
                child: Container(
                  width: 760,
                  constraints: BoxConstraints(
                      maxHeight: compact ? double.infinity : 620),
                  padding: const EdgeInsets.all(26),
                  decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surface,
                      borderRadius: BorderRadius.circular(compact ? 0 : 34),
                      boxShadow: compact
                          ? null
                          : const [
                              BoxShadow(
                                  color: Colors.black38,
                                  blurRadius: 60,
                                  offset: Offset(0, 22))
                            ]),
                  child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(children: [
                          const Icon(Icons.blur_on_rounded, size: 30),
                          const SizedBox(width: 10),
                          const Expanded(
                              child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                Text('Switch workspace',
                                    style: TextStyle(
                                        fontSize: 23,
                                        fontWeight: FontWeight.w900)),
                                Text(
                                    'Every workspace has its own rooms, desks and feed',
                                    style: TextStyle(fontSize: 11))
                              ])),
                          IconButton(
                              onPressed: () => Navigator.pop(context),
                              icon: const Icon(Icons.close))
                        ]),
                        const SizedBox(height: 18),
                        TextField(
                            autofocus: true,
                            onChanged: (v) => setState(() => query = v),
                            decoration: const InputDecoration(
                                prefixIcon: Icon(Icons.search_rounded),
                                hintText: 'Search workspaces…')),
                        const SizedBox(height: 18),
                        Flexible(
                            child: loading
                                ? const Center(
                                    child: CircularProgressIndicator())
                                : GridView.builder(
                                    shrinkWrap: true,
                                    gridDelegate:
                                        SliverGridDelegateWithFixedCrossAxisCount(
                                            crossAxisCount: compact
                                                ? math.max(
                                                    1,
                                                    (MediaQuery.sizeOf(context)
                                                                .width /
                                                            180)
                                                        .floor())
                                                : 3,
                                            mainAxisSpacing: 12,
                                            crossAxisSpacing: 12,
                                            mainAxisExtent: 154),
                                    itemCount: names.length + 1,
                                    itemBuilder: (context, i) {
                                      if (i == names.length)
                                        return InkWell(
                                            onTap: _create,
                                            borderRadius:
                                                BorderRadius.circular(24),
                                            child: Container(
                                                decoration: BoxDecoration(
                                                    border: Border.all(
                                                        color: Theme.of(context)
                                                            .colorScheme
                                                            .outlineVariant),
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                            24)),
                                                child: const Column(
                                                    mainAxisAlignment:
                                                        MainAxisAlignment
                                                            .center,
                                                    children: [
                                                      Icon(Icons
                                                          .add_circle_outline_rounded),
                                                      SizedBox(height: 8),
                                                      Text('New workspace',
                                                          style: TextStyle(
                                                              fontWeight:
                                                                  FontWeight
                                                                      .w700))
                                                    ])));
                                      final name = names[i];
                                      final selected = name == widget.current;
                                      final space = spaces.firstWhere(
                                          (s) => s.name == name,
                                          orElse: () => Workspace(
                                              id: '', ownerId: '', name: name));
                                      return InkWell(
                                          onTap: () => widget.onPick(name),
                                          borderRadius:
                                              BorderRadius.circular(24),
                                          child: AnimatedContainer(
                                              duration: const Duration(
                                                  milliseconds: 180),
                                              padding: const EdgeInsets.all(16),
                                              decoration: BoxDecoration(
                                                  color: selected
                                                      ? Theme.of(context)
                                                          .colorScheme
                                                          .primaryContainer
                                                      : Theme.of(context)
                                                          .colorScheme
                                                          .surfaceContainerHighest
                                                          .withValues(
                                                              alpha: .6),
                                                  borderRadius:
                                                      BorderRadius.circular(24),
                                                  border: Border.all(
                                                      color: selected
                                                          ? Theme.of(context)
                                                              .colorScheme
                                                              .primary
                                                          : Colors
                                                              .transparent)),
                                              child: Stack(children: [
                                                Column(
                                                    crossAxisAlignment:
                                                        CrossAxisAlignment
                                                            .start,
                                                    children: [
                                                      CircleAvatar(
                                                          child: Text(name
                                                              .substring(
                                                                  0,
                                                                  math.min(2,
                                                                      name.length))
                                                              .toUpperCase())),
                                                      const Spacer(),
                                                      Text(name,
                                                          style: const TextStyle(
                                                              fontWeight:
                                                                  FontWeight
                                                                      .w900)),
                                                      Text(
                                                          '${_roomCountFor(name)} rooms',
                                                          style:
                                                              const TextStyle(
                                                                  fontSize:
                                                                      10)),
                                                      if (selected)
                                                        const Align(
                                                            alignment: Alignment
                                                                .bottomRight,
                                                            child: Icon(
                                                                Icons
                                                                    .check_circle_rounded,
                                                                size: 17))
                                                    ]),
                                                if (widget.onSettings != null &&
                                                    space.id.isNotEmpty)
                                                  Positioned(
                                                      top: 0,
                                                      right: 0,
                                                      child: IconButton(
                                                          tooltip:
                                                              'Settings for $name',
                                                          visualDensity:
                                                              VisualDensity
                                                                  .compact,
                                                          onPressed: () =>
                                                              widget.onSettings!(
                                                                  space),
                                                          icon: const Icon(
                                                              Icons
                                                                  .settings_outlined,
                                                              size: 18)))
                                              ])));
                                    })),
                      ]),
                ))));
  }

  int _roomCountFor(String name) => _roomCounts[name] ?? 0;
}

class _CreateWorkspaceDialog extends StatefulWidget {
  const _CreateWorkspaceDialog();
  @override
  State<_CreateWorkspaceDialog> createState() => _CreateWorkspaceDialogState();
}

class _CreateWorkspaceDialogState extends State<_CreateWorkspaceDialog> {
  final controller = TextEditingController();
  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('New workspace'),
      content: SizedBox(
        width: 360,
        child: TextField(
          controller: controller,
          autofocus: true,
          onSubmitted: (v) {
            if (v.trim().isNotEmpty) Navigator.pop(context, v.trim());
          },
          decoration: const InputDecoration(labelText: 'Workspace name'),
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
          child: const Text('Create'),
        ),
      ],
    );
  }
}
