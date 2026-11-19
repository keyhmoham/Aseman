import 'dart:async';

import 'package:flutter/material.dart';

import 'card_frame.dart';

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
    this.connectBuilder,
    required super.child,
  });

  final AgUiInvoke invoke;
  final String spaceId;
  final String roomId;

  /// Opens the project computer (after taking control).
  final VoidCallback? onOpenComputer;

  /// Opens the person's tasks.
  final VoidCallback? onOpenTasks;

  /// Draws a login card (an app asks the person to sign in): the rooms give
  /// it the node, since signing in is the tools feature's to run.
  final Widget Function(BuildContext context, Map<String, dynamic> props)?
  connectBuilder;

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

Widget _note(BuildContext context, String text, {bool error = false}) =>
    AgUiNote(text, error: error);

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

  String get id => '${widget.props['approval'] ?? widget.props['id'] ?? ''}';
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
    final pending = answered.isEmpty;
    final needsYou = pending && AgUiActions.of(context) != null && canAnswer;
    final tool = '${p['tool'] ?? ''}';
    final effect = '${p['effect'] ?? ''}';
    final shortState = switch (status) {
      'approved' => 'Allowed',
      'refused' => 'Refused',
      'expired' => 'Expired',
      'canceled' => 'Canceled',
      _ => needsYou ? 'Needs you' : 'Waiting',
    };
    return AgUiCard(
      icon: Icons.verified_user_outlined,
      tone: pending ? AgUiTone.warning : AgUiTone.info,
      title: '${p['summary'] ?? 'An agent asks to act'}',
      subtitle: [tool, effect].where((e) => e.isNotEmpty).join(' · '),
      status: shortState,
      statusTone: switch (status) {
        'approved' => AgUiTone.success,
        'refused' => AgUiTone.danger,
        'pending' => AgUiTone.warning,
        _ => AgUiTone.neutral,
      },
      children: [
        if (recipients.isNotEmpty)
          Text.rich(
            TextSpan(
              style: const TextStyle(fontSize: 13),
              children: [
                const TextSpan(text: 'To '),
                TextSpan(
                  text: recipients.join(', '),
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ],
            ),
          ),
        if (text.isNotEmpty)
          Container(
            padding: const EdgeInsets.fromLTRB(12, 8, 10, 8),
            decoration: BoxDecoration(
              color: scheme.surface,
              borderRadius: BorderRadius.circular(10),
              border: Border(
                left: BorderSide(color: scheme.outlineVariant, width: 3),
              ),
            ),
            child: SelectableText(
              text,
              style: const TextStyle(fontSize: 13, height: 1.35),
            ),
          ),
        if ('${p['rule'] ?? ''}'.isNotEmpty)
          _note(context, 'Asked by the rule ${p['rule']}'),
        if (answered.isNotEmpty)
          AgUiAnswered(prefix: answered)
        else if (!needsYou)
          _note(context, 'Waiting on the person this agent works for.')
        else
          Wrap(
            spacing: 8,
            runSpacing: 8,
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
                style: TextButton.styleFrom(foregroundColor: scheme.error),
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
      final request = '${widget.props['request'] ?? widget.props['id'] ?? ''}';
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
    return AgUiCard(
      icon: Icons.key_rounded,
      title: 'An agent needs ${p['name'] ?? 'a credential'}',
      subtitle: site.isEmpty ? '' : 'For $site',
      status: done,
      statusTone: done == 'Declined' ? AgUiTone.neutral : AgUiTone.success,
      children: [
        if ('${p['reason'] ?? ''}'.isNotEmpty)
          Text(
            '${p['reason']}',
            style: const TextStyle(fontSize: 13, height: 1.35),
          ),
        if (done.isNotEmpty)
          const SizedBox.shrink()
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
              filled: true,
              fillColor: Theme.of(context).colorScheme.surface,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
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
    final held = status == 'controlled';
    return AgUiCard(
      icon: Icons.back_hand_outlined,
      tone: held ? AgUiTone.success : AgUiTone.info,
      title: 'Your turn on the project computer',
      status: held
          ? 'You have it'
          : status == 'released'
          ? 'Handed back'
          : '',
      statusTone: held ? AgUiTone.success : AgUiTone.neutral,
      children: [
        if ('${p['reason'] ?? ''}'.isNotEmpty)
          Text(
            '${p['reason']}',
            style: const TextStyle(fontSize: 13, height: 1.35),
          ),
        if ('${p['url'] ?? ''}'.isNotEmpty) _note(context, '${p['url']}'),
        if (a == null || a.spaceId.isEmpty)
          _note(context, 'Open this project in the app to take over.')
        else if (held) ...[
          TextField(
            controller: note,
            decoration: InputDecoration(
              isDense: true,
              filled: true,
              fillColor: Theme.of(context).colorScheme.surface,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              hintText: 'What you did (optional)',
            ),
          ),
          Wrap(
            spacing: 8,
            runSpacing: 6,
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
          _note(context, 'The agents continue.')
        else
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.icon(
              onPressed: busy ? null : () => _run('control_take'),
              icon: const Icon(Icons.mouse_outlined, size: 18),
              label: const Text('Take control'),
            ),
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
      await a.invoke('proactive', action, {
        'id': '${widget.props['task'] ?? widget.props['id'] ?? ''}',
      });
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
    return AgUiCard(
      icon: Icons.lightbulb_outline_rounded,
      title: '${p['title'] ?? 'A suggestion'}',
      status: done,
      statusTone: done == 'Started' ? AgUiTone.success : AgUiTone.neutral,
      children: [
        if ('${p['detail'] ?? ''}'.isNotEmpty)
          Text(
            '${p['detail']}',
            style: const TextStyle(fontSize: 13, height: 1.35),
          ),
        if (done.isNotEmpty)
          (a?.onOpenTasks != null && done == 'Started')
              ? Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    onPressed: a!.onOpenTasks,
                    child: const Text('See it in Tasks'),
                  ),
                )
              : const SizedBox.shrink()
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

/// A login card: an app the person needs asks them to sign in, here in the
/// chat. The card carries no credential; signing in is the tools feature's.
class AgUiConnect extends StatelessWidget {
  const AgUiConnect({super.key, required this.props});
  final Map<String, dynamic> props;

  @override
  Widget build(BuildContext context) {
    final build = AgUiActions.of(context)?.connectBuilder;
    if (build != null) return build(context, props);
    return AgUiCard(
      icon: Icons.login_rounded,
      title: 'Sign in to ${props['name'] ?? 'an app'}',
      children: [
        _note(context, 'Open this conversation in the app to sign in.'),
      ],
    );
  }
}
