import 'package:flutter/material.dart';

import '../../../core/formatting/billing_units.dart';
import '../../../shared/widgets/app_form.dart';
import '../../../shared/widgets/app_inputs.dart';
import '../../../shared/widgets/backend_action_ui.dart';
import '../../../shared/widgets/skeleton.dart';

/// Reads backend data a form needs to offer choices (providers, categories).
typedef AdminLookup = Future<dynamic> Function(
    String namespace, String action, Map<String, dynamic> body);

/// Keys in an initial body that only describe the target to the form (its
/// display name, current figures). They are never sent to the backend.
const _contextKeys = {'_name', '_cap', '_spent', '_amount', '_kind', '_cost'};

/// Opens the purpose-built form for an admin action and returns the request
/// body, or null when the operator cancels. Actions without a dedicated form
/// fall back to the generic validated form.
Future<Map<String, dynamic>?> showAdminActionForm(
  BuildContext context, {
  required String namespace,
  required String action,
  Map<String, dynamic> initialBody = const {},
  required AdminLookup lookup,
}) {
  final key = '$namespace.$action';
  final body = initialBody;
  final name = '${body['_name'] ?? ''}';
  Widget? form = switch (key) {
    'users.account_update' => _UserForm(initial: body),
    'users.account_password' => _PasswordForm(initial: body),
    'users.account_delete' => _ConfirmForm(
        initial: body,
        icon: Icons.person_remove_rounded,
        title: 'Delete ${name.isEmpty ? 'this user' : name}?',
        message:
            'The account, its sign-in and its profile are removed. Projects it owns lose their owner. This cannot be undone.',
        submit: 'Delete user',
        destructive: true),
    'spaces.space_delete' => _ConfirmForm(
        initial: body,
        icon: Icons.folder_delete_rounded,
        title: 'Delete ${name.isEmpty ? 'this project' : name}?',
        message:
            'Its rooms, files, machine and volume are removed for everyone in it. This cannot be undone.',
        submit: 'Delete project',
        destructive: true),
    'bots.bot_delete' => _ConfirmForm(
        initial: body,
        icon: Icons.delete_forever_rounded,
        title: 'Delete ${name.isEmpty ? 'this agent' : name}?',
        message:
            'Projects using it lose it and its marketplace listing is removed. This cannot be undone.',
        submit: 'Delete agent',
        destructive: true),
    'tools.mcp_delete' => _ConfirmForm(
        initial: body,
        icon: Icons.delete_forever_rounded,
        title: 'Delete ${name.isEmpty ? 'this app' : name}?',
        message:
            'Projects that added it can no longer call it. This cannot be undone.',
        submit: 'Delete',
        destructive: true),
    'bots.agent_import_samples' => _ConfirmForm(
        initial: body,
        icon: Icons.download_rounded,
        title: 'Import sample agents?',
        message:
            'Adds the ready-made sample agents to this node. Existing agents are left as they are.',
        submit: 'Import'),
    'tools.mcp_import_samples' => _ConfirmForm(
        initial: body,
        icon: Icons.download_rounded,
        title: 'Import the app catalog?',
        message:
            'Adds the sample MCP servers to this node. Servers already registered are skipped.',
        submit: 'Import'),
    'spaces.computer' => _computerForm(body),
    'finance.wallet_mint' => _GrantForm(initial: body),
    'finance.budget_set' => _BudgetForm(initial: body),
    'finance.payout_resolve' => _PayoutForm(initial: body),
    'bots.bot_create' ||
    'bots.bot_edit' =>
      _AgentForm(initial: body, lookup: lookup, editing: action == 'bot_edit'),
    'market.publish' => _PublishForm(initial: body, lookup: lookup),
    'market.deny' => _DenyForm(initial: body),
    'tools.mcp_register' ||
    'tools.mcp_update' =>
      _McpForm(initial: body, editing: action == 'mcp_update'),
    _ => null,
  };
  if (form == null) {
    return showBackendActionForm(context,
        namespace: namespace,
        action: action,
        initialBody: {
          for (final e in body.entries)
            if (!_contextKeys.contains(e.key)) e.key: e.value
        });
  }
  return showAppForm<Map<String, dynamic>>(context, form);
}

/// What to tell the operator after an action succeeds.
String adminActionDone(String namespace, String action) =>
    const {
      'users.account_update': 'User updated',
      'users.account_password': 'Password changed',
      'users.account_delete': 'User deleted',
      'finance.wallet_mint': 'Credits granted',
      'finance.budget_set': 'Budget saved',
      'finance.purchases_label': 'Purchases relabelled',
      'finance.payout_resolve': 'Payout resolved',
      'spaces.space_delete': 'Project deleted',
      'spaces.computer': 'Computer updated',
      'spaces.admins_space_set': 'Admins space saved',
      'spaces.admin_chat_report_resolve': 'Report updated',
      'talent.admin_request_status': 'Request updated',
      'talent.partner_key_create': 'Partner key created',
      'talent.partner_key_revoke': 'Partner key revoked',
      'spaces.admin_terminate_sandbox': 'Machine terminated',
      'bots.bot_create': 'Agent created',
      'bots.bot_edit': 'Agent saved',
      'bots.bot_delete': 'Agent deleted',
      'bots.agent_import_samples': 'Sample agents imported',
      'tools.mcp_import_samples': 'App catalog imported',
      'tools.mcp_register': 'Server added',
      'tools.mcp_update': 'Server saved',
      'tools.mcp_delete': 'Deleted',
      'tools.mcp_oauth_set': 'Sign-in client saved',
      'market.publish': 'Listed in the market',
      'market.approve': 'Listing approved',
      'market.deny': 'Listing denied',
      'market.unpublish': 'Removed from the market',
      'llm.llm_provider_set': 'Models saved',
      'llm.llm_decision_set': 'Decision model saved',
      'llm.llm_memory_set': 'Memory models saved',
      'llm.llm_image_set': 'Image model saved',
      'llm.llm_voice_set': 'Voice model saved',
      'spaces.opencode_set': 'OpenCode setting saved',
      'spaces.agent_engine_set': 'Agentic engine saved',
      'admin.plugins_load': 'Module loaded',
      'admin.plugins_unload': 'Module unloaded',
      'admin.plugins_stop': 'Module stopped',
      'admin.plugins_set_active': 'Active adapter switched',
      'settings.update': 'Settings saved',
    }['$namespace.$action'] ??
    'Done';

Widget _computerForm(Map<String, dynamic> body) {
  final op = '${body['operation'] ?? 'status'}';
  final (icon, title, message, destructive) = switch (op) {
    'provision' => (
        Icons.power_settings_new_rounded,
        'Start the computer?',
        'Creates or wakes the project computer. It is billed while awake.',
        false
      ),
    'keepalive' => (
        Icons.coffee_rounded,
        'Keep the computer awake?',
        'Resets its idle timer so it does not fall asleep soon.',
        false
      ),
    'sleep' => (
        Icons.bedtime_rounded,
        'Put the computer to sleep?',
        'Running work in the project stops; files stay on its volume.',
        true
      ),
    'replace' => (
        Icons.autorenew_rounded,
        'Replace the computer?',
        'A fresh machine is created from the base image. Anything outside the project volume is lost.',
        true
      ),
    'forget_logins' => (
        Icons.no_accounts_rounded,
        'Forget the browser\'s logins?',
        'The desktop browser keeps the sites it is signed in to across sleeps and replacements. This signs it out of all of them; nothing else is touched.',
        true
      ),
    _ => (
        Icons.info_outline_rounded,
        'Check the computer?',
        'Asks the provider for the machine’s current state.',
        false
      ),
  };
  return _ConfirmForm(
      initial: body,
      icon: icon,
      title: title,
      message: message,
      submit: op == 'status' ? 'Check' : 'Continue',
      destructive: destructive,
      needsCheck: false);
}

Map<String, dynamic> _clean(Map<String, dynamic> body) => {
      for (final e in body.entries)
        if (!_contextKeys.contains(e.key)) e.key: e.value
    };

double _num(dynamic v) =>
    v is num ? v.toDouble() : double.tryParse('${v ?? ''}') ?? 0;

Map<String, dynamic> _asMap(dynamic v) =>
    v is Map ? v.map((k, x) => MapEntry('$k', x)) : <String, dynamic>{};

class _ConfirmForm extends StatefulWidget {
  const _ConfirmForm({
    required this.initial,
    required this.icon,
    required this.title,
    required this.message,
    required this.submit,
    this.destructive = false,
    bool? needsCheck,
  }) : needsCheck = needsCheck ?? destructive;
  final Map<String, dynamic> initial;
  final IconData icon;
  final String title;
  final String message;
  final String submit;
  final bool destructive;
  final bool needsCheck;

  @override
  State<_ConfirmForm> createState() => _ConfirmFormState();
}

class _ConfirmFormState extends State<_ConfirmForm> {
  bool understood = false;

  @override
  Widget build(BuildContext context) => AppFormFrame(
        icon: widget.icon,
        title: widget.title,
        subtitle: widget.message,
        destructive: widget.destructive,
        submit: widget.submit,
        onSubmit: widget.needsCheck && !understood
            ? null
            : () => Navigator.pop(context, _clean(widget.initial)),
        children: [
          if (widget.needsCheck)
            AppConfirmCheck(
                value: understood,
                onChanged: (v) => setState(() => understood = v),
                label: 'I understand this cannot be undone'),
        ],
      );
}

class _UserForm extends StatefulWidget {
  const _UserForm({required this.initial});
  final Map<String, dynamic> initial;
  @override
  State<_UserForm> createState() => _UserFormState();
}

class _UserFormState extends State<_UserForm> {
  final formKey = GlobalKey<FormState>();
  late final Map<String, dynamic> profile = _asMap(widget.initial['profile']);
  late final first = TextEditingController(
      text: '${profile['firstName'] ?? profile['first_name'] ?? ''}');
  late final last = TextEditingController(
      text: '${profile['lastName'] ?? profile['last_name'] ?? ''}');
  late final handle =
      TextEditingController(text: '${widget.initial['handle'] ?? ''}');
  late final email =
      TextEditingController(text: '${widget.initial['email'] ?? ''}');
  late String role = '${widget.initial['role'] ?? ''}' == 'admin' ||
          widget.initial['is_admin'] == true
      ? 'admin'
      : 'user';
  late String status = '${widget.initial['status'] ?? 'active'}' == 'disabled'
      ? 'disabled'
      : 'active';
  late bool hireable = profile['hireable'] == true;
  late String market = switch ('${profile['marketStatus'] ?? 'pending'}') {
    'approved' => 'approved',
    'rejected' || 'denied' => 'rejected',
    _ => 'pending',
  };

  @override
  void dispose() {
    for (final c in [first, last, handle, email]) {
      c.dispose();
    }
    super.dispose();
  }

  void submit() {
    if (!(formKey.currentState?.validate() ?? false)) return;
    final i = widget.initial;
    final body = <String, dynamic>{'account': i['account']};
    void put(String key, String value, dynamic was) {
      if (value.trim() != '${was ?? ''}'.trim()) body[key] = value.trim();
    }

    put('handle', handle.text.replaceFirst(RegExp(r'^@+'), ''), i['handle']);
    put('email', email.text, i['email']);
    final wasAdmin = '${i['role'] ?? ''}' == 'admin' || i['is_admin'] == true;
    if ((role == 'admin') != wasAdmin) body['role'] = role;
    if (status !=
        ('${i['status'] ?? 'active'}' == 'disabled' ? 'disabled' : 'active')) {
      body['status'] = status;
    }
    final nextProfile = <String, dynamic>{};
    if (first.text.trim() !=
        '${profile['firstName'] ?? profile['first_name'] ?? ''}') {
      nextProfile['firstName'] = first.text.trim();
    }
    if (last.text.trim() !=
        '${profile['lastName'] ?? profile['last_name'] ?? ''}') {
      nextProfile['lastName'] = last.text.trim();
    }
    if (hireable != (profile['hireable'] == true)) {
      nextProfile['hireable'] = hireable;
    }
    if (hireable && market != '${profile['marketStatus'] ?? 'pending'}') {
      nextProfile['marketStatus'] = market;
    }
    if (nextProfile.isNotEmpty) body['profile'] = nextProfile;
    Navigator.pop(context, body);
  }

  @override
  Widget build(BuildContext context) {
    final name = [first.text, last.text].where((x) => x.trim().isNotEmpty);
    return AppFormFrame(
      formKey: formKey,
      icon: Icons.manage_accounts_rounded,
      title: 'Edit ${name.isEmpty ? '@${handle.text}' : name.join(' ')}',
      subtitle: 'Identity, role and access. Only what you change is saved.',
      submit: 'Save changes',
      onSubmit: submit,
      children: [
        Row(children: [
          Expanded(
              child: TextFormField(
                  controller: first,
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(labelText: 'First name'))),
          const SizedBox(width: 12),
          Expanded(
              child: TextFormField(
                  controller: last,
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(labelText: 'Last name'))),
        ]),
        Column(children: [
          TextFormField(
            controller: handle,
            decoration: const InputDecoration(
                labelText: 'Username',
                prefixIcon: Icon(Icons.alternate_email_rounded)),
            validator: (v) =>
                (v ?? '').trim().isEmpty ? 'A username is required' : null,
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: email,
            keyboardType: TextInputType.emailAddress,
            decoration: const InputDecoration(
                labelText: 'Email',
                prefixIcon: Icon(Icons.mail_outline_rounded)),
            validator: (v) {
              final t = (v ?? '').trim();
              return t.isNotEmpty && !RegExp(r'^\S+@\S+\.\S+$').hasMatch(t)
                  ? 'Enter a valid email address'
                  : null;
            },
          ),
        ]),
        AppSegmentedField<String>(
          label: 'Role',
          value: role,
          onChanged: (v) => setState(() => role = v),
          choices: const [
            AppChoice('user', 'Member',
                icon: Icons.person_outline_rounded,
                hint: 'Uses the platform; no access to this console.'),
            AppChoice('admin', 'Administrator',
                icon: Icons.admin_panel_settings_outlined,
                hint:
                    'Full access to this console, every project and the node’s money.'),
          ],
        ),
        AppSegmentedField<String>(
          label: 'Access',
          value: status,
          onChanged: (v) => setState(() => status = v),
          choices: const [
            AppChoice('active', 'Can sign in', icon: Icons.lock_open_rounded),
            AppChoice('disabled', 'Blocked',
                icon: Icons.block_rounded,
                hint: 'Sign-in is refused; their data and wallet are kept.'),
          ],
        ),
        Column(children: [
          AppSwitchCard(
            icon: Icons.badge_outlined,
            title: 'Listed for hire',
            subtitle: 'Shown in the talent directory once approved.',
            value: hireable,
            onChanged: (v) => setState(() => hireable = v),
          ),
          if (hireable) ...[
            const SizedBox(height: 14),
            AppSegmentedField<String>(
              label: 'Talent review',
              value: market,
              onChanged: (v) => setState(() => market = v),
              choices: const [
                AppChoice('pending', 'Pending',
                    icon: Icons.hourglass_empty_rounded),
                AppChoice('approved', 'Approved',
                    icon: Icons.verified_outlined),
                AppChoice('rejected', 'Denied', icon: Icons.block_rounded),
              ],
            ),
          ],
        ]),
      ],
    );
  }
}

class _PasswordForm extends StatefulWidget {
  const _PasswordForm({required this.initial});
  final Map<String, dynamic> initial;
  @override
  State<_PasswordForm> createState() => _PasswordFormState();
}

class _PasswordFormState extends State<_PasswordForm> {
  final formKey = GlobalKey<FormState>();
  final password = TextEditingController();

  @override
  void dispose() {
    password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final name = '${widget.initial['_name'] ?? ''}';
    return AppFormFrame(
      formKey: formKey,
      icon: Icons.password_rounded,
      title: 'Set a new password',
      subtitle:
          '${name.isEmpty ? 'The user' : name} signs in with it from now on. Share it with them over a private channel.',
      submit: 'Set password',
      onSubmit: () {
        if (!(formKey.currentState?.validate() ?? false)) return;
        Navigator.pop(context,
            {'account': widget.initial['account'], 'password': password.text});
      },
      children: [AppPasswordField(controller: password)],
    );
  }
}

class _GrantForm extends StatefulWidget {
  const _GrantForm({required this.initial});
  final Map<String, dynamic> initial;
  @override
  State<_GrantForm> createState() => _GrantFormState();
}

class _GrantFormState extends State<_GrantForm> {
  double credits = 500;
  String reason = 'Support credit';
  final note = TextEditingController();
  DateTime? expires;

  static const reasons = [
    AppChoice('Welcome bonus', 'Welcome bonus',
        icon: Icons.celebration_outlined),
    AppChoice('Support credit', 'Support credit',
        icon: Icons.support_agent_rounded),
    AppChoice('Refund', 'Refund', icon: Icons.undo_rounded),
    AppChoice('Promotion', 'Promotion', icon: Icons.campaign_outlined),
    AppChoice('Testing', 'Testing', icon: Icons.science_outlined),
    AppChoice('Other', 'Other', icon: Icons.more_horiz_rounded),
  ];

  @override
  void dispose() {
    note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final name = '${widget.initial['_name'] ?? ''}';
    return AppFormFrame(
      icon: Icons.add_card_rounded,
      title: 'Grant credits',
      subtitle:
          'Added to ${name.isEmpty ? 'this wallet' : '$name’s wallet'} right away. 100 credits = \$1.',
      submit: 'Grant ${compactDecimal(credits)} credits',
      onSubmit: credits <= 0 || (reason == 'Other' && note.text.trim().isEmpty)
          ? null
          : () {
              final text = [
                if (reason != 'Other') reason,
                if (note.text.trim().isNotEmpty) note.text.trim(),
              ].join(' — ');
              Navigator.pop(context, {
                'target': widget.initial['target'],
                'amount': creditsToLedger(credits),
                'reason': text,
                if (expires != null)
                  'expires_at': DateTime.utc(expires!.year, expires!.month,
                          expires!.day, 23, 59, 59)
                      .toIso8601String(),
              });
            },
      children: [
        AppAmountField(
          label: 'Amount',
          hint: '≈ ${formatLedgerUsd(creditsToLedger(credits))} of usage',
          value: credits,
          min: 0,
          max: 10000,
          step: 50,
          decimals: 0,
          unit: 'credits',
          presets: const [100, 500, 1000, 2500, 5000, 10000],
          format: (v) => '${compactDecimal(v)} credits',
          presetLabel: (v) => compactDecimal(v),
          onChanged: (v) => setState(() => credits = v),
        ),
        AppChoiceField<String>(
          label: 'Reason',
          hint: 'Shown on the user’s wallet activity.',
          choices: reasons,
          value: reason,
          onChanged: (v) => setState(() => reason = v),
        ),
        TextField(
          controller: note,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
              labelText:
                  reason == 'Other' ? 'Describe the reason' : 'Note (optional)',
              prefixIcon: const Icon(Icons.notes_rounded)),
        ),
        AppExpiryField(
          label: 'Expires',
          hint: 'Unused granted credits disappear after this date.',
          value: expires,
          onChanged: (v) => setState(() => expires = v),
        ),
      ],
    );
  }
}

class _BudgetForm extends StatefulWidget {
  const _BudgetForm({required this.initial});
  final Map<String, dynamic> initial;
  @override
  State<_BudgetForm> createState() => _BudgetFormState();
}

class _BudgetFormState extends State<_BudgetForm> {
  late double credits =
      ledgerToCredits(_num(widget.initial['_cap'])).toDouble();

  @override
  Widget build(BuildContext context) {
    final spent = ledgerToCredits(_num(widget.initial['_spent']));
    final scheme = Theme.of(context).colorScheme;
    return AppFormFrame(
      icon: Icons.savings_outlined,
      title: 'Project budget',
      subtitle:
          'Work stops when the project has spent this much. Set no limit to let it run on its owner’s wallet alone.',
      submit: credits == 0 ? 'Remove limit' : 'Save budget',
      onSubmit: () => Navigator.pop(context, {
        'space': widget.initial['space'],
        'cap': creditsToLedger(credits),
      }),
      children: [
        AppAmountField(
          label: 'Spending limit',
          hint: credits == 0
              ? 'No limit'
              : '≈ ${formatLedgerUsd(creditsToLedger(credits))}',
          value: credits,
          max: 50000,
          step: 100,
          decimals: 0,
          unit: 'credits',
          presets: const [0, 1000, 5000, 10000, 25000, 50000],
          presetLabel: (v) => v == 0 ? 'No limit' : compactDecimal(v),
          format: (v) => v == 0 ? 'No limit' : '${compactDecimal(v)} credits',
          onChanged: (v) => setState(() => credits = v),
        ),
        if (spent > 0)
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            AppFieldLabel('Spent so far',
                hint: credits == 0
                    ? '${compactDecimal(spent)} credits'
                    : '${compactDecimal(spent)} of ${compactDecimal(credits)} credits'),
            AppMeter(
                value: credits == 0 ? 0 : spent / credits,
                color: credits > 0 && spent >= credits
                    ? scheme.error
                    : scheme.primary),
          ]),
      ],
    );
  }
}

class _PayoutForm extends StatefulWidget {
  const _PayoutForm({required this.initial});
  final Map<String, dynamic> initial;
  @override
  State<_PayoutForm> createState() => _PayoutFormState();
}

class _PayoutFormState extends State<_PayoutForm> {
  late String status =
      '${widget.initial['status']}' == 'rejected' ? 'rejected' : 'paid';
  final reference = TextEditingController();
  final note = TextEditingController();
  String reason = 'Payment details are invalid';

  static const reasons = [
    AppChoice('Payment details are invalid', 'Invalid details'),
    AppChoice('Requested by the creator', 'Creator asked'),
    AppChoice('Suspicious activity', 'Suspicious'),
    AppChoice('Other', 'Other'),
  ];

  @override
  void dispose() {
    reference.dispose();
    note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final id = '${widget.initial['payout_id']}';
    final amount = widget.initial['_amount'];
    final name = '${widget.initial['_name'] ?? ''}';
    final paid = status == 'paid';
    return AppFormFrame(
      icon: paid ? Icons.price_check_rounded : Icons.money_off_rounded,
      destructive: !paid,
      title: '${amount == null ? 'Payout' : formatLedgerUsd(_num(amount))}'
          '${name.isEmpty ? '' : ' to @$name'}',
      subtitle: paid
          ? 'Pay the creator outside Aseman first, then record the transfer here.'
          : 'The reserved amount goes back to the creator’s wallet.',
      submit: paid ? 'Mark paid' : 'Reject and return funds',
      onSubmit: paid && reference.text.trim().isEmpty
          ? null
          : () => Navigator.pop(context, {
                'payout_id': widget.initial['payout_id'],
                'resolution_id': '$id-$status',
                'status': status,
                if (paid) 'provider_reference': reference.text.trim(),
                if (!paid)
                  'reason': [
                    if (reason != 'Other') reason,
                    if (note.text.trim().isNotEmpty) note.text.trim(),
                  ].join(' — '),
              }),
      children: [
        AppSegmentedField<String>(
          label: 'Outcome',
          value: status,
          onChanged: (v) => setState(() => status = v),
          choices: const [
            AppChoice('paid', 'Paid', icon: Icons.check_circle_outline),
            AppChoice('rejected', 'Rejected', icon: Icons.undo_rounded),
          ],
        ),
        if (paid)
          TextField(
            controller: reference,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
                labelText: 'Transfer reference',
                helperText:
                    'The confirmation number from your bank or payment provider.',
                prefixIcon: Icon(Icons.receipt_long_outlined)),
          )
        else ...[
          AppChoiceField<String>(
            label: 'Why',
            hint: 'The creator sees this reason.',
            choices: reasons,
            value: reason,
            onChanged: (v) => setState(() => reason = v),
          ),
          TextField(
            controller: note,
            minLines: 2,
            maxLines: 4,
            decoration: InputDecoration(
                labelText: reason == 'Other' ? 'Reason' : 'Note (optional)',
                alignLabelWithHint: true),
          ),
        ],
      ],
    );
  }
}

/// Creates or edits an agent (or, with a non-agent kind, a tool's name and
/// rate). The backbone is chosen from the node's configured models.
class _AgentForm extends StatefulWidget {
  const _AgentForm(
      {required this.initial, required this.lookup, required this.editing});
  final Map<String, dynamic> initial;
  final AdminLookup lookup;
  final bool editing;
  @override
  State<_AgentForm> createState() => _AgentFormState();
}

class _AgentFormState extends State<_AgentForm> {
  final formKey = GlobalKey<FormState>();
  late final name =
      TextEditingController(text: '${widget.initial['name'] ?? ''}');
  late final description =
      TextEditingController(text: '${widget.initial['description'] ?? ''}');
  late final instructions =
      TextEditingController(text: '${widget.initial['instructions'] ?? ''}');
  late final Map<String, dynamic> cost = _asMap(widget.initial['cost']);
  late double rate =
      ledgerToUsd(_num(cost['per_minute'] ?? widget.initial['_cost'] ?? 0))
          .toDouble();
  late String provider = '${widget.initial['provider'] ?? ''}';
  late String model = '${widget.initial['model'] ?? ''}';
  List<Map<String, dynamic>> providers = const [];
  bool loading = true;

  String get kind =>
      '${widget.initial['kind'] ?? widget.initial['_kind'] ?? 'agent'}';
  bool get agent => kind == 'agent';

  @override
  void initState() {
    super.initState();
    if (!agent) {
      loading = false;
      return;
    }
    widget.lookup('llm', 'llm_providers_list', const {}).then((value) {
      if (!mounted) return;
      final list = (_asMap(value)['providers'] is List
              ? _asMap(value)['providers'] as List
              : const <dynamic>[])
          .map(_asMap)
          .where((p) => p['enabled'] != false)
          .toList();
      setState(() {
        providers = list;
        loading = false;
        // Agents may store the provider's kind or name: match it to an id.
        final match = list.where((p) =>
            '${p['id']}' == provider ||
            '${p['kind']}' == provider ||
            '${p['name']}' == provider);
        if (match.isNotEmpty) provider = '${match.first['id']}';
      });
    }).catchError((_) {
      if (mounted) setState(() => loading = false);
    });
  }

  @override
  void dispose() {
    name.dispose();
    description.dispose();
    instructions.dispose();
    super.dispose();
  }

  List<Map<String, dynamic>> _models(String providerId) {
    final p = providers.where((p) => '${p['id']}' == providerId).firstOrNull;
    final models =
        p?['models'] is List ? p!['models'] as List : const <dynamic>[];
    return models.map(_asMap).where((m) {
      final caps = m['capabilities'] is List
          ? (m['capabilities'] as List).map((c) => '$c').toList()
          : const <String>[];
      return !caps
          .any((c) => c.contains('embedding') || c.contains('decision'));
    }).toList();
  }

  void submit() {
    if (!(formKey.currentState?.validate() ?? false)) return;
    final i = widget.initial;
    final perMinute = usdToLedger(rate);
    final costChanged = perMinute != _num(cost['per_minute']).round();
    if (!widget.editing) {
      Navigator.pop(context, {
        'kind': kind,
        'name': name.text.trim(),
        if (description.text.trim().isNotEmpty)
          'description': description.text.trim(),
        if (agent && instructions.text.trim().isNotEmpty)
          'instructions': instructions.text,
        if (agent && provider.isNotEmpty) 'provider': provider,
        if (agent && model.isNotEmpty) 'model': model,
        if (perMinute > 0) 'cost': {...cost, 'per_minute': perMinute},
      });
      return;
    }
    final body = <String, dynamic>{'bot': i['bot']};
    if (name.text.trim() != '${i['name'] ?? ''}')
      body['name'] = name.text.trim();
    if (agent && instructions.text != '${i['instructions'] ?? ''}') {
      body['instructions'] = instructions.text;
    }
    // Only a changed backbone is sent, so saving a rename never pins an
    // agent that follows the default model to today's default.
    if (agent && model != '${i['model'] ?? ''}') {
      body['provider'] = provider;
      body['model'] = model;
    }
    if (costChanged) body['cost'] = {...cost, 'per_minute': perMinute};
    Navigator.pop(context, body);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final models = _models(provider);
    final noun = agent ? 'agent' : 'app';
    return AppFormFrame(
      formKey: formKey,
      icon: agent ? Icons.smart_toy_outlined : Icons.build_outlined,
      title: widget.editing ? 'Edit $noun' : 'New $noun',
      subtitle: agent
          ? 'Its name, how it works, the model it thinks with and what it costs per minute.'
          : 'Its name and what it costs per minute of use.',
      submit: widget.editing ? 'Save' : 'Create $noun',
      onSubmit: submit,
      children: [
        TextFormField(
          controller: name,
          decoration: InputDecoration(
              labelText: 'Name',
              prefixIcon: const Icon(Icons.label_outline_rounded),
              hintText: agent ? 'Research analyst' : null),
          validator: (v) => (v ?? '').trim().isEmpty ? 'Give it a name' : null,
        ),
        if (!widget.editing)
          TextFormField(
            controller: description,
            minLines: 2,
            maxLines: 4,
            decoration: const InputDecoration(
                labelText: 'Short description',
                hintText: 'What people hire it for',
                alignLabelWithHint: true),
          ),
        if (agent)
          TextFormField(
            controller: instructions,
            minLines: 4,
            maxLines: 10,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
                labelText: 'Instructions',
                hintText:
                    'You are a careful research analyst. Cite every source…',
                helperText:
                    '${instructions.text.length} characters · its system prompt',
                alignLabelWithHint: true),
          ),
        if (agent)
          loading
              ? const SkeletonField()
              : providers.isEmpty
                  ? Text(
                      'No LLM provider is enabled yet. Add one under AI › Providers, then pick the model here.',
                      style: TextStyle(color: scheme.onSurfaceVariant))
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                          AppChoiceField<String>(
                            label: 'Provider',
                            value: provider,
                            onChanged: (v) => setState(() {
                              provider = v;
                              model = '';
                            }),
                            choices: [
                              for (final p in providers)
                                AppChoice('${p['id']}', '${p['name']}',
                                    icon: Icons.hub_outlined),
                            ],
                          ),
                          const SizedBox(height: 18),
                          AppChoiceField<String>(
                            label: 'Model',
                            hint: provider.isEmpty
                                ? 'Pick a provider first, or keep the platform default.'
                                : null,
                            value: model,
                            onChanged: (v) => setState(() => model = v),
                            choices: [
                              const AppChoice('', 'Platform default',
                                  icon: Icons.auto_mode_rounded),
                              for (final m in models)
                                AppChoice(
                                    '${m['id']}', '${m['name'] ?? m['id']}'),
                              if (model.isNotEmpty &&
                                  !models.any((m) => '${m['id']}' == model))
                                AppChoice(model, '$model (current)'),
                            ],
                          ),
                        ]),
        AppAmountField(
          label: 'Price per minute',
          hint: rate == 0
              ? 'Uses the platform’s ${agent ? 'agent' : 'app'} rate from Settings › Pricing.'
              : '${compactDecimal(rate * 100)} credits a minute, on top of model tokens.',
          value: rate,
          max: 1,
          step: .01,
          unit: '\$',
          presets: const [0, .02, .05, .1, .25],
          presetLabel: (v) =>
              v == 0 ? 'Platform rate' : '\$${v.toStringAsFixed(2)}',
          format: (v) =>
              v == 0 ? 'Platform rate' : '\$${compactDecimal(v)} / min',
          onChanged: (v) => setState(() => rate = v),
        ),
      ],
    );
  }
}

class _PublishForm extends StatefulWidget {
  const _PublishForm({required this.initial, required this.lookup});
  final Map<String, dynamic> initial;
  final AdminLookup lookup;
  @override
  State<_PublishForm> createState() => _PublishFormState();
}

class _PublishFormState extends State<_PublishForm> {
  late final name =
      TextEditingController(text: '${widget.initial['name'] ?? ''}');
  late final description =
      TextEditingController(text: '${widget.initial['description'] ?? ''}');
  double price = 0;
  String category = '';
  List<String> categories = const [];

  @override
  void initState() {
    super.initState();
    widget.lookup('settings', 'get', const {}).then((value) {
      final list = _asMap(value)['categories'];
      if (mounted && list is List) {
        setState(() => categories = list.map((c) => '$c').toList()..sort());
      }
    }).catchError((_) {});
  }

  @override
  void dispose() {
    name.dispose();
    description.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final type = '${widget.initial['type'] ?? 'agent'}';
    return AppFormFrame(
      icon: Icons.storefront_outlined,
      title: 'List in the market',
      subtitle:
          'How this $type appears to people browsing, and what it costs to add.',
      submit: 'Publish',
      onSubmit: name.text.trim().isEmpty
          ? null
          : () => Navigator.pop(context, {
                'bot': widget.initial['bot'],
                'type': type,
                'name': name.text.trim(),
                if (description.text.trim().isNotEmpty)
                  'description': description.text.trim(),
                if (price > 0) 'price': creditsToLedger(price),
                if (category.isNotEmpty) 'category': category,
              }),
      children: [
        TextField(
          controller: name,
          onChanged: (_) => setState(() {}),
          decoration: const InputDecoration(
              labelText: 'Listing title',
              prefixIcon: Icon(Icons.label_outline_rounded)),
        ),
        TextField(
          controller: description,
          minLines: 3,
          maxLines: 6,
          decoration: const InputDecoration(
              labelText: 'Description',
              hintText: 'What it does and who it is for',
              alignLabelWithHint: true),
        ),
        if (categories.isNotEmpty)
          AppChoiceField<String>(
            label: 'Category',
            value: category,
            onChanged: (v) => setState(() => category = v),
            choices: [
              const AppChoice('', 'None'),
              for (final c in categories)
                AppChoice(c, '${c[0].toUpperCase()}${c.substring(1)}'),
            ],
          ),
        AppAmountField(
          label: 'Price',
          hint: price == 0
              ? 'Free to add; usage is still billed per minute.'
              : '≈ ${formatLedgerUsd(creditsToLedger(price))}, paid once when added.',
          value: price,
          max: 5000,
          step: 10,
          decimals: 0,
          unit: 'credits',
          presets: const [0, 50, 100, 500, 1000],
          presetLabel: (v) => v == 0 ? 'Free' : compactDecimal(v),
          format: (v) => v == 0 ? 'Free' : '${compactDecimal(v)} credits',
          onChanged: (v) => setState(() => price = v),
        ),
      ],
    );
  }
}

class _DenyForm extends StatefulWidget {
  const _DenyForm({required this.initial});
  final Map<String, dynamic> initial;
  @override
  State<_DenyForm> createState() => _DenyFormState();
}

class _DenyFormState extends State<_DenyForm> {
  String reason = 'Description is unclear';
  final note = TextEditingController();

  @override
  void dispose() {
    note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final name = '${widget.initial['_name'] ?? ''}';
    return AppFormFrame(
      icon: Icons.block_rounded,
      destructive: true,
      title: 'Deny ${name.isEmpty ? 'this listing' : name}?',
      subtitle: 'The owner sees why and can fix it and submit again.',
      submit: 'Deny listing',
      onSubmit: reason == 'Other' && note.text.trim().isEmpty
          ? null
          : () => Navigator.pop(context, {
                ..._clean(widget.initial),
                'reason': [
                  if (reason != 'Other') reason,
                  if (note.text.trim().isNotEmpty) note.text.trim(),
                ].join(' — '),
              }),
      children: [
        AppChoiceField<String>(
          label: 'Reason',
          value: reason,
          onChanged: (v) => setState(() => reason = v),
          choices: const [
            AppChoice('Description is unclear', 'Unclear description'),
            AppChoice('Does not work as described', 'Does not work'),
            AppChoice('Price is not justified', 'Price too high'),
            AppChoice('Violates the content policy', 'Policy violation'),
            AppChoice('Duplicates an existing listing', 'Duplicate'),
            AppChoice('Other', 'Other'),
          ],
        ),
        TextField(
          controller: note,
          minLines: 2,
          maxLines: 4,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
              labelText: reason == 'Other'
                  ? 'Reason'
                  : 'Advice for the owner (optional)',
              alignLabelWithHint: true),
        ),
      ],
    );
  }
}

class _McpForm extends StatefulWidget {
  const _McpForm({required this.initial, required this.editing});
  final Map<String, dynamic> initial;
  final bool editing;
  @override
  State<_McpForm> createState() => _McpFormState();
}

class _McpFormState extends State<_McpForm> {
  final formKey = GlobalKey<FormState>();
  late final name =
      TextEditingController(text: '${widget.initial['name'] ?? ''}');
  late final url =
      TextEditingController(text: '${widget.initial['url'] ?? ''}');
  final token = TextEditingController();
  late String auth = '${widget.initial['auth'] ?? ''}' == 'user' ? 'user' : '';
  Map<String, String> headers = const {};
  bool listed = true;
  bool obscure = true;

  @override
  void dispose() {
    name.dispose();
    url.dispose();
    token.dispose();
    super.dispose();
  }

  void submit() {
    if (!(formKey.currentState?.validate() ?? false)) return;
    final shared = auth.isEmpty;
    Navigator.pop(context, {
      if (widget.editing)
        'bot': widget.initial['bot']
      else
        'name': name.text.trim(),
      'url': url.text.trim(),
      'auth': auth,
      if (shared && token.text.trim().isNotEmpty) 'token': token.text.trim(),
      if (shared && headers.isNotEmpty) 'headers': headers,
      if (!widget.editing) 'listed': listed,
    });
  }

  @override
  Widget build(BuildContext context) {
    return AppFormFrame(
      formKey: formKey,
      icon: Icons.hub_outlined,
      title: widget.editing
          ? 'Edit ${name.text.isEmpty ? 'app' : name.text}'
          : 'Add an app',
      subtitle:
          'An app served by an MCP server. With shared credentials the node checks that it answers before saving.',
      submit: widget.editing ? 'Save' : 'Add app',
      onSubmit: submit,
      children: [
        if (!widget.editing)
          TextFormField(
            controller: name,
            decoration: const InputDecoration(
                labelText: 'Name',
                hintText: 'Market data',
                prefixIcon: Icon(Icons.label_outline_rounded)),
            validator: (v) =>
                (v ?? '').trim().isEmpty ? 'Give it a name' : null,
          ),
        TextFormField(
          controller: url,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(
              labelText: 'Server URL',
              hintText: 'https://mcp.example.com/sse',
              prefixIcon: Icon(Icons.link_rounded)),
          validator: (v) {
            final uri = Uri.tryParse((v ?? '').trim());
            return uri == null ||
                    !(uri.scheme == 'https' || uri.scheme == 'http') ||
                    uri.host.isEmpty
                ? 'Enter the full http(s) address'
                : null;
          },
        ),
        AppSegmentedField<String>(
          label: 'Sign-in',
          value: auth,
          onChanged: (v) => setState(() => auth = v),
          choices: const [
            AppChoice('', 'Shared key',
                icon: Icons.key_rounded,
                hint: 'Everyone uses the credentials you enter here.'),
            AppChoice('user', 'Each person',
                icon: Icons.person_pin_outlined,
                hint:
                    'People connect their own account the first time they use it.'),
          ],
        ),
        if (auth.isEmpty) ...[
          TextField(
            controller: token,
            obscureText: obscure,
            decoration: InputDecoration(
                labelText: widget.editing ? 'New access token' : 'Access token',
                helperText: widget.editing
                    ? 'Leave empty to keep the current one.'
                    : 'Sent as a bearer token. Optional for open servers.',
                prefixIcon: const Icon(Icons.vpn_key_outlined),
                suffixIcon: IconButton(
                    onPressed: () => setState(() => obscure = !obscure),
                    icon: Icon(obscure
                        ? Icons.visibility_outlined
                        : Icons.visibility_off_outlined))),
          ),
          AppPairsEditor(
            label: 'Extra headers',
            hint: 'For servers that expect their own key header.',
            keyHint: 'Header',
            valueHint: 'Value',
            obscureValues: true,
            initial: const {},
            onChanged: (v) => headers = v,
          ),
        ],
        if (!widget.editing)
          AppSwitchCard(
            icon: Icons.public_rounded,
            title: 'List in the catalog',
            subtitle: 'Every project on this node can add it.',
            value: listed,
            onChanged: (v) => setState(() => listed = v),
          ),
      ],
    );
  }
}
