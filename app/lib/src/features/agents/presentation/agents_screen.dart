import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../app_dependencies.dart';
import '../../../core/theme/app_colors.dart';
import '../../../data/models/bot.dart';
import '../../../data/services/aseman_service.dart';
import '../../../shared/widgets/app_form.dart';
import '../../../shared/widgets/avatar_editor.dart';
import '../../../shared/widgets/overlay_panels.dart';
import '../../../shared/widgets/panel_header.dart';
import '../../../shared/widgets/segmented_tab_bar.dart';
import '../../../shared/widgets/skeleton.dart';
import '../../../shared/widgets/status_tag.dart';
import '../../tools/data/tools_api.dart';
import '../../tools/domain/tool_models.dart';
import '../../tools/presentation/app_frontend_screen.dart';
import '../../tools/presentation/tool_create_form.dart';
import '../../tools/presentation/tool_screen.dart';
import 'agent_create_form.dart';

/// "My bots" — a modal panel (dialog on desktop, bottom sheet on mobile) that
/// shows the agents and apps the signed-in user created, and
/// keeps them editable after they were created. Follows the app's panel
/// convention: icon + title header, TabBar, and tabbed content.
class AgentsScreen extends StatefulWidget {
  const AgentsScreen({super.key, required this.dependencies});

  final AppDependencies dependencies;

  @override
  State<AgentsScreen> createState() => _AgentsScreenState();
}

class _AgentsScreenState extends State<AgentsScreen> {
  List<Bot> _bots = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final bots = await widget.dependencies.service.fetchBots();
      if (!mounted) return;
      setState(() {
        _bots = bots;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  List<Bot> get _agents => _bots.where((b) => b.isAgent).toList();
  List<Bot> get _tools =>
      _bots.where((b) => b.isTool && !b.isSandbox).toList();

  /// Create an agent or a tool.
  Future<void> _create(String what) =>
      what == 'tool' ? _createTool() : _createAgent();

  /// A tool: one form for its backend (external, managed or installed) and
  /// its frontend (none or static).
  Future<void> _createTool() async {
    final draft = await showCreateToolForm(context);
    if (draft == null || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ToolsApi.of(widget.dependencies.service).create(draft);
      messenger.showSnackBar(SnackBar(content: Text('${draft.name} created')));
      await _load();
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Create failed: $e')));
    }
  }

  Future<void> _createAgent() async {
    final result = await showCreateBotForm(context,
        loadLlmCatalog: widget.dependencies.service.fetchLlmCatalog);
    if (result == null || !mounted) return;
    try {
      await widget.dependencies.service.createBot(
        name: result.name,
        kind: result.kind,
        vmType: result.vmType,
        description: result.description,
        instructions: result.instructions,
        provider: result.provider,
        model: result.model,
        maxTurns: result.maxTurns,
        maxTokens: result.maxTokens,
        skills: result.skills,
        module: result.module,
        frontend: result.frontend.isEmpty ? null : result.frontend,
        widgetDsl: result.widgetDsl,
        cpu: result.cpu,
        memoryMb: result.memoryMb,
        diskMb: result.diskMb,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('${result.name} created')));
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Create failed: $e')));
    }
  }

  /// Opens an agent's form filled with how it is configured today and saves
  /// what was changed.
  Future<void> _editAgent(Bot bot) async {
    final service = widget.dependencies.service;
    final messenger = ScaffoldMessenger.of(context);
    final BotFormResult before;
    try {
      before = BotFormResult.fromDetail(await service.fetchBotDetail(bot.id));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Could not load: $e')));
      return;
    }
    if (!mounted) return;
    final after = await showEditBotForm(context,
        initial: before, loadLlmCatalog: service.fetchLlmCatalog);
    if (after == null || !mounted) return;
    T? changed<T>(T now, T was) => now == was ? null : now;
    final skills = [for (final s in after.skills) s['name']];
    final skillsBefore = [for (final s in before.skills) s['name']];
    final resized = after.cpu != before.cpu ||
        after.memoryMb != before.memoryMb ||
        after.diskMb != before.diskMb;
    final backbone =
        after.provider != before.provider || after.model != before.model;
    final reskilled = !listEquals(skills, skillsBefore);
    if (after.name == before.name &&
        after.description == before.description &&
        after.instructions == before.instructions &&
        after.maxTurns == before.maxTurns &&
        after.maxTokens == before.maxTokens &&
        !backbone &&
        !reskilled &&
        !resized) {
      return;
    }
    try {
      await service.editBot(
        bot.id,
        name: changed(after.name, before.name),
        description: changed(after.description, before.description),
        instructions: changed(after.instructions, before.instructions),
        provider: backbone ? after.provider : null,
        model: backbone ? after.model : null,
        maxTurns: changed(after.maxTurns, before.maxTurns),
        maxTokens: changed(after.maxTokens, before.maxTokens),
        skills: reskilled ? after.skills : null,
        cpu: resized ? after.cpu : null,
        memoryMb: resized ? after.memoryMb : null,
        diskMb: resized ? after.diskMb : null,
      );
      messenger.showSnackBar(SnackBar(content: Text('${after.name} saved')));
      await _load();
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Save failed: $e')));
    }
  }

  /// A tool: its form filled with what it was made from; a tool made before
  /// tools had one form: its name and description.
  Future<void> _editTool(Bot bot) async {
    final service = widget.dependencies.service;
    final messenger = ScaffoldMessenger.of(context);
    if (!bot.isUnifiedTool) {
      await _editProfile(bot);
      return;
    }
    final api = ToolsApi.of(service);
    final ToolInfo tool;
    try {
      tool = await api.get(bot.id);
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Could not load: $e')));
      return;
    }
    if (!mounted) return;
    if (!tool.editable) {
      messenger.showSnackBar(
          const SnackBar(content: Text('Only the app’s owner can edit it.')));
      return;
    }
    final changes = await showEditToolForm(context, tool);
    if (changes == null || !mounted) return;
    try {
      final saved = await api.edit(bot.id, changes);
      messenger.showSnackBar(SnackBar(
          content:
              Text('${saved.name.isEmpty ? tool.name : saved.name} saved')));
      await _load();
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Save failed: $e')));
    }
  }

  Future<void> _editProfile(Bot bot) async {
    final service = widget.dependencies.service;
    final messenger = ScaffoldMessenger.of(context);
    final String description;
    try {
      description =
          '${(await service.fetchBotDetail(bot.id))['description'] ?? ''}';
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Could not load: $e')));
      return;
    }
    if (!mounted) return;
    final edited = await showAppForm<(String, String)>(
        context, _ProfileForm(name: bot.name, description: description));
    if (edited == null || !mounted) return;
    final (name, about) = edited;
    try {
      await service.editBot(bot.id,
          name: name == bot.name ? null : name,
          description: about == description ? null : about);
      messenger.showSnackBar(SnackBar(content: Text('$name saved')));
      await _load();
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Save failed: $e')));
    }
  }

  /// Sets or clears an agent's or an app's picture.
  Future<void> _setAvatar(Bot bot, String fileId) async {
    await widget.dependencies.service.setBotAvatar(bot.id, fileId);
    if (!mounted) return;
    setState(() => _bots = [
          for (final b in _bots) b.id == bot.id ? b.withAvatar(fileId) : b
        ]);
  }

  Future<void> _lifecycle(Bot bot, String op) async {
    try {
      await widget.dependencies.service.botLifecycle(bot.id, op);
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('$op failed: $e')));
    }
  }

  void _openApp(Bot bot) {
    if (bot.isUnifiedTool) {
      _openTool(bot);
      return;
    }
    Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) =>
            AppFrontendScreen(dependencies: widget.dependencies, bot: bot)));
  }

  /// A tool runs in a space; from here, the owner's home space (it is added
  /// there first when it is not yet).
  Future<void> _openTool(Bot bot) async {
    final service = widget.dependencies.service;
    final home =
        widget.dependencies.sessionController.session?.homeSpaceId ?? '';
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    if (home.isEmpty) {
      messenger.showSnackBar(const SnackBar(
          content: Text('Open the app from a workspace it was added to.')));
      return;
    }
    try {
      final inHome = await service.fetchSpaceBots(home);
      if (!inHome.any((b) => b.id == bot.id)) {
        await service.addBotToSpace(home, bot.id);
      }
      await navigator.push(MaterialPageRoute<void>(
          builder: (_) => ToolScreen(
              dependencies: widget.dependencies, bot: bot, spaceId: home)));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Could not open: $e')));
    }
  }

  Future<void> _chat(Bot bot) async {
    await showAdaptivePanel<void>(
      context,
      _AgentChatSheet(
        dependencies: widget.dependencies,
        bot: bot,
      ),
      breakpoint: 720,
      maxWidth: 560,
      maxHeight: 780,
      heightFactor: .92,
    );
  }

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 560;
    return DefaultTabController(
      length: 2,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
            compact ? 16 : 26, compact ? 16 : 22, compact ? 16 : 26, 0),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          PanelHeader(
            icon: Icons.smart_toy_outlined,
            title: 'My bots',
            subtitle: 'Agents & apps you created across the network',
            onClose: () => Navigator.pop(context),
            actions: [
              AppPopupMenuButton<String>(
                tooltip: 'Create',
                onSelected: _create,
                itemBuilder: (_) => const [
                  PopupMenuItem(
                      value: 'agent',
                      child: ListTile(
                          leading: Icon(Icons.smart_toy_outlined),
                          title: Text('Agent'),
                          subtitle: Text('An assistant with its own model'))),
                  PopupMenuItem(
                      value: 'tool',
                      child: ListTile(
                          leading: Icon(Icons.apps_outlined),
                          title: Text('App'),
                          subtitle: Text(
                              'A backend and the frontend it is used through'))),
                ],
                child: IgnorePointer(
                  child: FilledButton.icon(
                    onPressed: () {},
                    icon: const Icon(Icons.add_rounded, size: 18),
                    label: const Text('Create'),
                  ),
                ),
              ),
              IconButton(
                  tooltip: 'Refresh',
                  onPressed: _load,
                  icon: const Icon(Icons.refresh_rounded)),
            ],
          ),
          const SizedBox(height: 14),
          SegmentedTabBar(
            compact: compact,
            alignment: Alignment.centerLeft,
            labels: const ['Agents', 'Apps'],
            icons: const [Icons.smart_toy_outlined, Icons.apps_outlined],
          ),
          const SizedBox(height: 10),
          Expanded(
            child: _loading
                ? const SkeletonList(
                    item: SkeletonCard(mediaHeight: 0), spacing: 10)
                : _error != null
                    ? Center(child: Text(_error!))
                    : TabBarView(children: [
                        _AgentsTab(
                          service: widget.dependencies.service,
                          onAvatar: _setAvatar,
                          agents: _agents,
                          onChat: _chat,
                          onEdit: _editAgent,
                          onToggle: (b) => _lifecycle(
                              b, b.status == 'running' ? 'stop' : 'start'),
                        ),
                        _ToolsTab(
                            service: widget.dependencies.service,
                            onAvatar: _setAvatar,
                            tools: _tools,
                            onOpen: _openApp,
                            onEdit: _editTool),
                      ]),
          ),
        ]),
      ),
    );
  }
}

class _AgentsTab extends StatelessWidget {
  const _AgentsTab({
    required this.service,
    required this.onAvatar,
    required this.agents,
    required this.onChat,
    required this.onEdit,
    required this.onToggle,
  });

  final AsemanService service;
  final Future<void> Function(Bot bot, String fileId) onAvatar;
  final List<Bot> agents;
  final ValueChanged<Bot> onChat;
  final ValueChanged<Bot> onEdit;
  final ValueChanged<Bot> onToggle;

  @override
  Widget build(BuildContext context) {
    if (agents.isEmpty) {
      return const _PanelEmpty(
          icon: Icons.smart_toy_outlined,
          message: 'No agents yet — create one.');
    }
    return ListView(
      padding: const EdgeInsets.only(top: 4, bottom: 18),
      children: [
        _SummaryRow(
          cells: [
            _Summary('Total', '${agents.length}'),
            _Summary('Running',
                '${agents.where((b) => b.status == 'running').length}'),
          ],
        ),
        const SizedBox(height: 12),
        ...agents.map((b) => _AgentCard(
              key: ValueKey(b.id),
              service: service,
              onAvatar: (id) => onAvatar(b, id),
              bot: b,
              onChat: () => onChat(b),
              onEdit: () => onEdit(b),
              onToggle: () => onToggle(b),
            )),
      ],
    );
  }
}

class _ToolsTab extends StatelessWidget {
  const _ToolsTab(
      {required this.service,
      required this.onAvatar,
      required this.tools,
      required this.onOpen,
      required this.onEdit});

  final AsemanService service;
  final Future<void> Function(Bot bot, String fileId) onAvatar;
  final List<Bot> tools;
  final ValueChanged<Bot> onOpen;
  final ValueChanged<Bot> onEdit;

  @override
  Widget build(BuildContext context) {
    if (tools.isEmpty) {
      return const _PanelEmpty(
          icon: Icons.widgets_outlined, message: 'No apps yet — create one.');
    }
    return LayoutBuilder(builder: (context, box) {
      final columns = box.maxWidth > 900
          ? 4
          : box.maxWidth > 600
              ? 3
              : box.maxWidth > 380
                  ? 2
                  : 1;
      final width = (box.maxWidth - (columns - 1) * 10) / columns;
      return ListView(
        padding: const EdgeInsets.only(top: 4, bottom: 18),
        children: [
          _SummaryRow(
            cells: [
              _Summary('Total', '${tools.length}'),
              _Summary('Managed',
                  '${tools.where((b) => b.toolModeLabel.startsWith('Managed')).length}'),
              _Summary('Installed',
                  '${tools.where((b) => b.vmType == 'installed').length}'),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(spacing: 10, runSpacing: 10, children: [
            for (final bot in tools)
              SizedBox(
                  width: width,
                  child: _ToolCard(
                      key: ValueKey(bot.id),
                      service: service,
                      onAvatar: (id) => onAvatar(bot, id),
                      bot: bot,
                      onOpen: () => onOpen(bot),
                      onEdit: () => onEdit(bot))),
          ]),
        ],
      );
    });
  }
}

class _SummaryRow extends StatelessWidget {
  const _SummaryRow({required this.cells});

  final List<_Summary> cells;

  @override
  Widget build(BuildContext context) => Row(children: [
        for (final c in cells) ...[
          Expanded(child: c),
          if (c != cells.last) const SizedBox(width: 10),
        ],
      ]);
}

class _Summary extends StatelessWidget {
  const _Summary(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: .45),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label,
            style: TextStyle(fontSize: 10, color: scheme.onSurfaceVariant)),
        const SizedBox(height: 4),
        Text(value,
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900)),
      ]),
    );
  }
}

class _PanelEmpty extends StatelessWidget {
  const _PanelEmpty({required this.icon, required this.message});

  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 44, color: scheme.onSurfaceVariant),
        const SizedBox(height: 10),
        Text(message, style: TextStyle(color: scheme.onSurfaceVariant)),
      ]),
    );
  }
}

class _AgentCard extends StatelessWidget {
  const _AgentCard({
    super.key,
    required this.service,
    required this.onAvatar,
    required this.bot,
    required this.onChat,
    required this.onEdit,
    required this.onToggle,
  });

  final AsemanService service;
  final Future<void> Function(String fileId) onAvatar;
  final Bot bot;
  final VoidCallback onChat;
  final VoidCallback onEdit;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = bot.status == 'running'
        ? AppColors.success
        : bot.status == 'paused'
            ? AppColors.warning
            : Theme.of(context).colorScheme.onSurfaceVariant;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: .45),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(children: [
        AvatarEditor(
          service: service,
          avatar: bot.avatar,
          initials: _initials(bot.name, 'AI'),
          color: color,
          radius: 21,
          subject: 'agent picture',
          onChanged: onAvatar,
        ),
        const SizedBox(width: 13),
        Expanded(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Flexible(
                child: Text(bot.name,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w800)),
              ),
              const SizedBox(width: 7),
              StatusTag(bot.kind.toUpperCase(), color),
            ]),
            const SizedBox(height: 4),
            Text('${bot.vmType} · ${bot.status}',
                style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
          ]),
        ),
        IconButton(
            tooltip: 'Chat',
            onPressed: onChat,
            icon: const Icon(Icons.chat_bubble_outline_rounded)),
        IconButton(
            tooltip: 'Edit',
            onPressed: onEdit,
            icon: const Icon(Icons.edit_outlined)),
        IconButton(
          tooltip: bot.status == 'running' ? 'Stop' : 'Start',
          onPressed: onToggle,
          icon: Icon(bot.status == 'running'
              ? Icons.stop_rounded
              : Icons.play_arrow_rounded),
        ),
      ]),
    );
  }
}

class _ToolCard extends StatelessWidget {
  const _ToolCard(
      {super.key,
      required this.service,
      required this.onAvatar,
      required this.bot,
      required this.onOpen,
      required this.onEdit});

  final AsemanService service;
  final Future<void> Function(String fileId) onAvatar;
  final Bot bot;
  final VoidCallback onOpen;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerHighest.withValues(alpha: .45),
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onOpen,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: scheme.outlineVariant),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                AvatarEditor(
                  service: service,
                  avatar: bot.avatar,
                  initials: _initials(bot.name, 'T'),
                  color: AppColors.cyan,
                  radius: 17,
                  subject: 'app picture',
                  onChanged: onAvatar,
                ),
                const Spacer(),
                if (bot.hasFrontend) const StatusTag('ELPIAN', AppColors.cyan),
                IconButton(
                  tooltip: 'Edit',
                  visualDensity: VisualDensity.compact,
                  onPressed: onEdit,
                  icon: const Icon(Icons.edit_outlined, size: 18),
                ),
              ]),
              const SizedBox(height: 10),
              Text(bot.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w800)),
              const SizedBox(height: 3),
              Text('${bot.toolModeLabel} · ${bot.status}',
                  style:
                      TextStyle(fontSize: 10, color: scheme.onSurfaceVariant)),
              const SizedBox(height: 10),
              Row(children: [
                Icon(Icons.open_in_new_rounded,
                    size: 14, color: scheme.onSurfaceVariant),
                const SizedBox(width: 5),
                Text('Open app',
                    style: TextStyle(
                        fontSize: 10, color: scheme.onSurfaceVariant)),
              ]),
            ],
          ),
        ),
      ),
    );
  }
}

/// Up to two letters of [name] for an avatar without a picture.
String _initials(String name, String fallback) {
  final parts =
      name.trim().split(RegExp(r'[\s_-]+')).where((p) => p.isNotEmpty);
  if (parts.isEmpty) return fallback;
  if (parts.length == 1) return parts.first.substring(0, 1).toUpperCase();
  return (parts.first.substring(0, 1) + parts.last.substring(0, 1))
      .toUpperCase();
}

/// The name and description of a bot that has no form of its own (a tool
/// made before tools had one form).
class _ProfileForm extends StatefulWidget {
  const _ProfileForm({required this.name, required this.description});

  final String name;
  final String description;

  @override
  State<_ProfileForm> createState() => _ProfileFormState();
}

class _ProfileFormState extends State<_ProfileForm> {
  late final name = TextEditingController(text: widget.name);
  late final description = TextEditingController(text: widget.description);

  @override
  void dispose() {
    name.dispose();
    description.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AppFormFrame(
        icon: Icons.edit_outlined,
        title: 'Edit app',
        subtitle: 'Its name and what people and agents read about it.',
        submit: 'Save changes',
        onSubmit: () {
          if (name.text.trim().isEmpty) {
            ScaffoldMessenger.maybeOf(context)
                ?.showSnackBar(const SnackBar(content: Text('Name the app.')));
            return;
          }
          Navigator.pop(context, (name.text.trim(), description.text.trim()));
        },
        children: [
          TextField(
              controller: name,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Name')),
          TextField(
              controller: description,
              minLines: 2,
              maxLines: 2,
              decoration: const InputDecoration(
                  labelText: 'Description', alignLabelWithHint: true)),
        ],
      );
}

/// Chat sheet for talking to an agent (message.ask).
class _AgentChatSheet extends StatefulWidget {
  const _AgentChatSheet({required this.dependencies, required this.bot});

  final AppDependencies dependencies;
  final Bot bot;

  @override
  State<_AgentChatSheet> createState() => _AgentChatSheetState();
}

class _AgentChatSheetState extends State<_AgentChatSheet> {
  final controller = TextEditingController();
  final scroll = ScrollController();
  final List<Map<String, String>> _messages = [];
  bool _sending = false;

  @override
  void dispose() {
    controller.dispose();
    scroll.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = controller.text.trim();
    if (text.isEmpty || _sending) return;
    // History is the prior turns (excluding the current message being sent);
    // otherwise the current prompt would be replayed twice to the model.
    final history = [
      for (final m in _messages)
        if (m['role'] == 'user' || m['role'] == 'agent')
          {
            'role': m['role'] == 'user' ? 'user' : 'assistant',
            'content': m['body'] ?? '',
          },
    ];
    setState(() {
      _messages.add({'role': 'user', 'body': text});
      _sending = true;
    });
    controller.clear();
    try {
      final reply = await widget.dependencies.service
          .askBot(widget.bot.id, text, history: history);
      if (!mounted) return;
      setState(() {
        _messages.add({'role': 'agent', 'body': reply});
        _sending = false;
      });
      _scrollToBottom();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _messages.add({'role': 'agent', 'body': 'Error: $e'});
        _sending = false;
      });
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (scroll.hasClients) {
        scroll.animateTo(scroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * 0.7,
          child: Column(children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(children: [
                const Icon(Icons.smart_toy_outlined),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('Chat with ${widget.bot.name}',
                      style: const TextStyle(fontWeight: FontWeight.w800)),
                ),
                IconButton(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close_rounded),
                ),
              ]),
            ),
            const Divider(height: 1),
            Expanded(
              child: _messages.isEmpty
                  ? Center(
                      child: Text('Ask ${widget.bot.name} anything.',
                          style: TextStyle(color: scheme.onSurfaceVariant)))
                  : ListView.builder(
                      controller: scroll,
                      padding: const EdgeInsets.all(16),
                      itemCount: _messages.length,
                      itemBuilder: (context, i) {
                        final m = _messages[i];
                        final isUser = m['role'] == 'user';
                        return Align(
                          alignment: isUser
                              ? Alignment.centerRight
                              : Alignment.centerLeft,
                          child: Container(
                            margin: const EdgeInsets.only(bottom: 8),
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 8),
                            constraints: const BoxConstraints(maxWidth: 320),
                            decoration: BoxDecoration(
                              color: isUser
                                  ? scheme.primaryContainer
                                  : scheme.surfaceContainerHighest,
                              borderRadius: BorderRadius.circular(14),
                            ),
                            child: Text(m['body'] ?? ''),
                          ),
                        );
                      },
                    ),
            ),
            if (_sending)
              const Padding(
                padding: EdgeInsets.all(8),
                child: SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2)),
              ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(children: [
                Expanded(
                  child: TextField(
                    controller: controller,
                    minLines: 1,
                    maxLines: 4,
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => _send(),
                    decoration: const InputDecoration(
                      hintText: 'Message...',
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                    onPressed: _send, icon: const Icon(Icons.send_rounded)),
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}
