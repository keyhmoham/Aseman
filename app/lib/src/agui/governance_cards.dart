import 'dart:async';

import 'package:flutter/material.dart';

/// Calls a node action for a card (an approval's answer, a secret, a task).
typedef AgUiInvoke =
    Future<dynamic> Function(
      String namespace,
      String action,
      Map<String, dynamic> body,
    );

/// What governance cards need from the conversation around them: a way to
/// call the node and the project the message belongs to. Rooms provide it;
/// without one the cards show their content and say where to answer.
class AgUiActions extends InheritedWidget {
  const AgUiActions({
    super.key,
    required this.invoke,
    this.spaceId = '',
    this.roomId = '',
    this.onOpenComputer,
    this.onOpenTasks,
    required super.child,
  });

  final AgUiInvoke invoke;
  final String spaceId;
  final String roomId;

  /// Opens the project computer (after taking control).
  final VoidCallback? onOpenComputer;

  /// Opens the person's tasks.
  final VoidCallback? onOpenTasks;

  static AgUiActions? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AgUiActions>();

  @override
  bool updateShouldNotify(AgUiActions old) =>
      old.invoke != invoke || old.spaceId != spaceId || old.roomId != roomId;
}

Map<String, dynamic> _map(dynamic v) =>
    v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};

String _error(Object e) {
  final text = '$e';
  final i = text.indexOf(':');
  return i > 0 && i < 40 ? text.substring(i + 1).trim() : text;
}

class _CardFrame extends StatelessWidget {
  const _CardFrame({
    required this.icon,
    required this.title,
    required this.children,
    this.tone,
  });
  final IconData icon;
  final String title;
  final List<Widget> children;
  final Color? tone;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = tone ?? scheme.primary;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Icon(icon, size: 18, color: color),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                title,
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 14,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        ...children,
      ],
    );
  }
}

Widget _note(BuildContext context, String text, {bool error = false}) {
  final scheme = Theme.of(context).colorScheme;
  return Padding(
    padding: const EdgeInsets.only(top: 6),
    child: Text(
      text,
      style: TextStyle(
        fontSize: 12,
        color: error ? scheme.error : scheme.onSurfaceVariant,
      ),
    ),
  );
}

/// An agent action waiting on a person: the exact action, the rule that
/// asked and, for a message, who gets it and what it says. Allow once,
/// Always allow (this agent, this kind of action, here) or Refuse. The card
/// reads the approval's live state, so an answer given elsewhere (another
/// device, Slack, SMS) shows here too.
class AgUiApproval extends StatefulWidget {
  const AgUiApproval({super.key, required this.props});
  final Map<String, dynamic> props;

  @override
  State<AgUiApproval> createState() => _AgUiApprovalState();
}

class _AgUiApprovalState extends State<AgUiApproval> {
  Map<String, dynamic> approval = const {};
  bool canAnswer = true;
  bool busy = false;
  String error = '';
  Timer? poll;

  String get id => '${widget.props['approval'] ?? ''}';
  String get status => '${approval['status'] ?? 'pending'}';

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (poll == null) {
      _load();
      poll = Timer.periodic(const Duration(seconds: 8), (_) {
        if (status == 'pending') _load();
      });
    }
  }

  @override
  void dispose() {
    poll?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final actions = AgUiActions.of(context);
    if (actions == null || id.isEmpty) return;
    try {
      final out = _map(
        await actions.invoke('governance', 'approval_get', {'id': id}),
      );
      if (!mounted) return;
      setState(() {
        approval = _map(out['approval']);
        canAnswer = out['can_answer'] != false;
      });
    } catch (_) {
      // The card still shows what the agent asked; answering reports errors.
    }
  }

  Future<void> _answer(String answer) async {
    final actions = AgUiActions.of(context);
    if (actions == null) return;
    setState(() {
      busy = true;
      error = '';
    });
    try {
      final out = _map(
        await actions.invoke('governance', 'approval_answer', {
          'id': id,
          'answer': answer,
        }),
      );
      if (mounted) setState(() => approval = _map(out['approval']));
    } catch (e) {
      if (mounted) setState(() => error = _error(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.props;
    final scheme = Theme.of(context).colorScheme;
    final recipients = [
      for (final r
          in (p['recipients'] is List ? p['recipients'] as List : const []))
        '$r',
    ];
    final text = '${p['text'] ?? ''}';
    final answered = switch (status) {
      'approved' =>
        approval['answer'] == 'always'
            ? 'Allowed, and always allowed from now on'
            : 'Allowed once',
      'refused' => 'Refused',
      'expired' => 'No answer in time: not done',
      'canceled' => 'Canceled',
      _ => '',
    };
    return _CardFrame(
      icon: Icons.verified_user_outlined,
      tone: scheme.tertiary,
      title: '${p['summary'] ?? 'An agent asks to act'}',
      children: [
        Wrap(
          spacing: 6,
          runSpacing: 4,
          children: [
            if ('${p['tool'] ?? ''}'.isNotEmpty)
              Chip(label: Text('${p['tool']}')),
            if ('${p['effect'] ?? ''}'.isNotEmpty)
              Chip(
                label: Text('${p['effect']}'),
                avatar: const Icon(Icons.bolt, size: 14),
              ),
          ],
        ),
        if (recipients.isNotEmpty)
          _note(context, 'To: ${recipients.join(', ')}'),
        if (text.isNotEmpty)
          Container(
            margin: const EdgeInsets.only(top: 6),
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: scheme.surface,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: scheme.outlineVariant),
            ),
            child: SelectableText(text, style: const TextStyle(fontSize: 13)),
          ),
        if ('${p['rule'] ?? ''}'.isNotEmpty)
          _note(context, 'Asked by the rule ${p['rule']}'),
        const SizedBox(height: 8),
        if (answered.isNotEmpty)
          Text(answered, style: const TextStyle(fontWeight: FontWeight.w600))
        else if (AgUiActions.of(context) == null || !canAnswer)
          _note(context, 'Waiting on the person this agent works for.')
        else
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              FilledButton(
                onPressed: busy ? null : () => _answer('once'),
                child: const Text('Allow once'),
              ),
              OutlinedButton(
                onPressed: busy ? null : () => _answer('always'),
                child: const Text('Always allow'),
              ),
              TextButton(
                onPressed: busy ? null : () => _answer('refuse'),
                child: const Text('Refuse'),
              ),
            ],
          ),
        if (error.isNotEmpty) _note(context, error, error: true),
      ],
    );
  }
}

/// A masked box for a credential an agent needs. The value goes to the
/// node's vault and never into the conversation; the agent uses it by name.
class AgUiSecret extends StatefulWidget {
  const AgUiSecret({super.key, required this.props});
  final Map<String, dynamic> props;

  @override
  State<AgUiSecret> createState() => _AgUiSecretState();
}

class _AgUiSecretState extends State<AgUiSecret> {
  final value = TextEditingController();
  bool hidden = true;
  bool busy = false;
  String done = '';
  String error = '';

  @override
  void dispose() {
    value.dispose();
    super.dispose();
  }

  Future<void> _send({bool decline = false}) async {
    final actions = AgUiActions.of(context);
    if (actions == null) return;
    if (!decline && value.text.isEmpty) return;
    setState(() {
      busy = true;
      error = '';
    });
    try {
      final request = '${widget.props['request']}';
      await actions.invoke(
        'governance',
        decline ? 'secret_decline' : 'secret_submit',
        {'request': request, if (!decline) 'value': value.text},
      );
      value.clear();
      if (mounted)
        setState(() => done = decline ? 'Declined' : 'Saved to the vault');
    } catch (e) {
      if (mounted) setState(() => error = _error(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.props;
    final site = '${p['site'] ?? ''}';
    return _CardFrame(
      icon: Icons.key_rounded,
      title: 'An agent needs ${p['name'] ?? 'a credential'}',
      children: [
        if ('${p['reason'] ?? ''}'.isNotEmpty) Text('${p['reason']}'),
        if (site.isNotEmpty) _note(context, 'For $site'),
        const SizedBox(height: 8),
        if (done.isNotEmpty)
          Text(done, style: const TextStyle(fontWeight: FontWeight.w600))
        else if (AgUiActions.of(context) == null)
          _note(context, 'Open this conversation in the app to answer.')
        else ...[
          TextField(
            controller: value,
            obscureText: hidden,
            enableSuggestions: false,
            autocorrect: false,
            onSubmitted: (_) => _send(),
            decoration: InputDecoration(
              isDense: true,
              border: const OutlineInputBorder(),
              labelText: '${p['name'] ?? 'Secret'}',
              suffixIcon: IconButton(
                tooltip: hidden ? 'Show' : 'Hide',
                icon: Icon(hidden ? Icons.visibility : Icons.visibility_off),
                onPressed: () => setState(() => hidden = !hidden),
              ),
            ),
          ),
          _note(
            context,
            'The agent never sees it: it is sealed in this node\'s vault.',
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              FilledButton(
                onPressed: busy ? null : _send,
                child: const Text('Save'),
              ),
              TextButton(
                onPressed: busy ? null : () => _send(decline: true),
                child: const Text('Decline'),
              ),
            ],
          ),
        ],
        if (error.isNotEmpty) _note(context, error, error: true),
      ],
    );
  }
}

/// An agent asks a person to take over the project computer (a sign-in, a
/// captcha). Taking control pauses the project's agents until it is handed
/// back.
class AgUiHandover extends StatefulWidget {
  const AgUiHandover({super.key, required this.props});
  final Map<String, dynamic> props;

  @override
  State<AgUiHandover> createState() => _AgUiHandoverState();
}

class _AgUiHandoverState extends State<AgUiHandover> {
  String status = '';
  bool busy = false;
  String error = '';
  final note = TextEditingController();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (status.isEmpty) _load();
  }

  @override
  void dispose() {
    note.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final a = AgUiActions.of(context);
    if (a == null || a.spaceId.isEmpty) return;
    try {
      final out = _map(
        await a.invoke('governance', 'control_state', {'space': a.spaceId}),
      );
      final h = _map(out['handover']);
      if (!mounted) return;
      setState(
        () => status = h['id'] == widget.props['handover'] || h.isEmpty
            ? '${out['status'] ?? ''}'
            : 'other',
      );
    } catch (_) {}
  }

  Future<void> _run(String action) async {
    final a = AgUiActions.of(context);
    if (a == null) return;
    setState(() {
      busy = true;
      error = '';
    });
    try {
      final out = _map(
        await a.invoke('governance', action, {
          'space': a.spaceId,
          if (action == 'control_release') 'note': note.text,
        }),
      );
      if (!mounted) return;
      setState(() => status = '${_map(out['handover'])['status'] ?? ''}');
      if (action == 'control_take') a.onOpenComputer?.call();
    } catch (e) {
      if (mounted) setState(() => error = _error(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.props;
    final a = AgUiActions.of(context);
    return _CardFrame(
      icon: Icons.back_hand_outlined,
      title: 'Your turn on the project computer',
      children: [
        if ('${p['reason'] ?? ''}'.isNotEmpty) Text('${p['reason']}'),
        if ('${p['url'] ?? ''}'.isNotEmpty) _note(context, '${p['url']}'),
        const SizedBox(height: 8),
        if (a == null || a.spaceId.isEmpty)
          _note(context, 'Open this project in the app to take over.')
        else if (status == 'controlled') ...[
          TextField(
            controller: note,
            decoration: const InputDecoration(
              isDense: true,
              border: OutlineInputBorder(),
              hintText: 'What you did (optional)',
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              FilledButton.icon(
                onPressed: busy ? null : () => _run('control_release'),
                icon: const Icon(Icons.smart_toy_outlined, size: 18),
                label: const Text('Hand back to the agents'),
              ),
              if (a.onOpenComputer != null)
                TextButton(
                  onPressed: a.onOpenComputer,
                  child: const Text('Open computer'),
                ),
            ],
          ),
        ] else if (status == 'released')
          const Text(
            'Handed back: the agents continue.',
            style: TextStyle(fontWeight: FontWeight.w600),
          )
        else
          FilledButton.icon(
            onPressed: busy ? null : () => _run('control_take'),
            icon: const Icon(Icons.mouse_outlined, size: 18),
            label: const Text('Take control'),
          ),
        if (error.isNotEmpty) _note(context, error, error: true),
      ],
    );
  }
}

/// A task an agent suggests: Start hands it to the lead, Hide drops it.
class AgUiSuggestion extends StatefulWidget {
  const AgUiSuggestion({super.key, required this.props});
  final Map<String, dynamic> props;

  @override
  State<AgUiSuggestion> createState() => _AgUiSuggestionState();
}

class _AgUiSuggestionState extends State<AgUiSuggestion> {
  String done = '';
  bool busy = false;
  String error = '';

  Future<void> _run(String action) async {
    final a = AgUiActions.of(context);
    if (a == null) return;
    setState(() {
      busy = true;
      error = '';
    });
    try {
      await a.invoke('proactive', action, {'id': '${widget.props['task']}'});
      if (mounted)
        setState(() => done = action == 'task_start' ? 'Started' : 'Hidden');
    } catch (e) {
      if (mounted) setState(() => error = _error(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.props;
    final a = AgUiActions.of(context);
    return _CardFrame(
      icon: Icons.lightbulb_outline_rounded,
      title: '${p['title'] ?? 'A suggestion'}',
      children: [
        if ('${p['detail'] ?? ''}'.isNotEmpty) Text('${p['detail']}'),
        const SizedBox(height: 8),
        if (done.isNotEmpty)
          Row(
            children: [
              Text(done, style: const TextStyle(fontWeight: FontWeight.w600)),
              if (a?.onOpenTasks != null)
                TextButton(
                  onPressed: a!.onOpenTasks,
                  child: const Text('Tasks'),
                ),
            ],
          )
        else if (a != null)
          Wrap(
            spacing: 8,
            children: [
              FilledButton(
                onPressed: busy ? null : () => _run('task_start'),
                child: const Text('Start'),
              ),
              TextButton(
                onPressed: busy ? null : () => _run('task_hide'),
                child: const Text('Hide'),
              ),
            ],
          ),
        if (error.isNotEmpty) _note(context, error, error: true),
      ],
    );
  }
}
