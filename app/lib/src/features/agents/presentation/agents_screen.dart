import 'package:flutter/material.dart';

import '../../../app_dependencies.dart';
import '../../../core/theme/app_colors.dart';
import '../../../data/models/bot.dart';
import '../../../shared/widgets/avatar.dart';
import '../../../shared/widgets/panel_header.dart';
import '../../../shared/widgets/segmented_tab_bar.dart';
import '../../../shared/widgets/status_tag.dart';
import '../../miniapps/presentation/miniapp_sandbox_screen.dart';
import '../../tools/data/tools_api.dart';
import '../../tools/presentation/tool_create_form.dart';
import '../../tools/presentation/tool_screen.dart';
import 'agent_create_form.dart';

/// "My bots" — a modal panel (dialog on desktop, bottom sheet on mobile) that
/// shows the agents and tools (miniapps) the signed-in user created. Follows
/// the app's panel convention: icon + title header, TabBar, and tabbed content.
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
  List<Bot> get _tools => _bots.where((b) => b.isMiniapp || b.isTool).toList();

  /// Create an agent or a tool.
  Future<void> _create(String what) =>
      what == 'tool' ? _createTool() : _createAgent();

  /// A tool: one form for its backend (external, managed or installed) and
  /// its frontend (static or generative).
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

  void _openMiniapp(Bot bot) {
    if (bot.isUnifiedTool) {
      _openTool(bot);
      return;
    }
    Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) =>
            MiniappSandboxScreen(dependencies: widget.dependencies, bot: bot)));
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
          content: Text('Open the tool from a workspace it was added to.')));
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
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => _AgentChatSheet(
        dependencies: widget.dependencies,
        bot: bot,
      ),
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
            subtitle: 'Agents & tools you created across the network',
            onClose: () => Navigator.pop(context),
            actions: [
              PopupMenuButton<String>(
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
                          leading: Icon(Icons.widgets_outlined),
                          title: Text('Tool'),
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
            labels: const ['Agents', 'Tools'],
            icons: const [Icons.smart_toy_outlined, Icons.widgets_outlined],
          ),
          const SizedBox(height: 10),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                    ? Center(child: Text(_error!))
                    : TabBarView(children: [
                        _AgentsTab(
                          agents: _agents,
                          onChat: _chat,
                          onToggle: (b) => _lifecycle(
                              b, b.status == 'running' ? 'stop' : 'start'),
                        ),
                        _ToolsTab(tools: _tools, onOpen: _openMiniapp),
                      ]),
          ),
        ]),
      ),
    );
  }
}

class _AgentsTab extends StatelessWidget {
  const _AgentsTab({
    required this.agents,
    required this.onChat,
    required this.onToggle,
  });

  final List<Bot> agents;
  final ValueChanged<Bot> onChat;
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
              bot: b,
              onChat: () => onChat(b),
              onToggle: () => onToggle(b),
            )),
      ],
    );
  }
}

class _ToolsTab extends StatelessWidget {
  const _ToolsTab({required this.tools, required this.onOpen});

  final List<Bot> tools;
  final ValueChanged<Bot> onOpen;

  @override
  Widget build(BuildContext context) {
    if (tools.isEmpty) {
      return const _PanelEmpty(
          icon: Icons.widgets_outlined, message: 'No tools yet — create one.');
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
                  child: _ToolCard(bot: bot, onOpen: () => onOpen(bot))),
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
    required this.bot,
    required this.onChat,
    required this.onToggle,
  });

  final Bot bot;
  final VoidCallback onChat;
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
        AppAvatar('AI', color: color, radius: 21),
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
  const _ToolCard({required this.bot, required this.onOpen});

  final Bot bot;
  final VoidCallback onOpen;

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
                const AppAvatar('T', color: AppColors.cyan, radius: 17),
                const Spacer(),
                if (bot.hasFrontend) const StatusTag('ELPIAN', AppColors.cyan),
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
                Text('Open tool',
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
