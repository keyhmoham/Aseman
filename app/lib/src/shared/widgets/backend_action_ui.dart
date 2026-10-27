import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/formatting/billing_units.dart';
import 'app_form.dart';
import 'app_inputs.dart';

enum BackendFieldType {
  text,
  multiline,
  integer,
  decimal,
  boolean,
  stringList,
  object,
}

class _FieldTemplate {
  const _FieldTemplate(this.name,
      {this.type = BackendFieldType.text,
      this.required = false,
      this.sensitive = false,
      this.ledgerCredits = false,
      this.hint});

  final String name;
  final BackendFieldType type;
  final bool required;
  final bool sensitive;
  final bool ledgerCredits;
  final String? hint;
}

const _destructiveWords = <String>{
  'delete',
  'deny',
  'remove',
  'revoke',
  'stop',
  'uninstall',
  'unload',
  'unpublish',
};

const _templates = <String, List<_FieldTemplate>>{
  'users.account_update': [
    _FieldTemplate('account', required: true, hint: 'Account ID'),
    _FieldTemplate('handle'),
    _FieldTemplate('email'),
    _FieldTemplate('role', hint: 'user or admin'),
    _FieldTemplate('status'),
    _FieldTemplate('profile', type: BackendFieldType.object),
  ],
  'users.account_password': [
    _FieldTemplate('account', required: true, hint: 'Account ID'),
    _FieldTemplate('password', required: true, sensitive: true),
  ],
  'users.account_delete': [
    _FieldTemplate('account', required: true, hint: 'Account ID'),
  ],
  'finance.wallet_mint': [
    _FieldTemplate('target', required: true, hint: 'Account ID'),
    _FieldTemplate('amount',
        type: BackendFieldType.decimal,
        required: true,
        ledgerCredits: true,
        hint: 'Credits shown to the user'),
    _FieldTemplate('reason'),
    _FieldTemplate('expires_at', hint: 'Optional RFC 3339 timestamp'),
  ],
  'finance.admin_account': [
    _FieldTemplate('account', required: true, hint: 'Account ID'),
    _FieldTemplate('limit', type: BackendFieldType.integer),
  ],
  'finance.budget_set': [
    _FieldTemplate('space', required: true, hint: 'Project ID'),
    _FieldTemplate('cap',
        type: BackendFieldType.decimal, required: true, ledgerCredits: true),
  ],
  'finance.purchases_label': [
    _FieldTemplate('transaction_ids',
        type: BackendFieldType.stringList, required: true),
    _FieldTemplate('sandbox', type: BackendFieldType.boolean, required: true),
  ],
  'finance.payout_resolve': [
    _FieldTemplate('payout_id', required: true, hint: 'Payout ID'),
    _FieldTemplate('resolution_id', required: true),
    _FieldTemplate('status', required: true, hint: 'paid or rejected'),
    _FieldTemplate('provider_reference'),
    _FieldTemplate('reason', type: BackendFieldType.multiline),
  ],
  'finance.purchase_confirm': [
    _FieldTemplate('product_id', required: true),
    _FieldTemplate('transaction_id', required: true),
    _FieldTemplate('listed_amount', type: BackendFieldType.decimal),
    _FieldTemplate('listed_currency'),
  ],
  'finance.payout_request': [
    _FieldTemplate('amount',
        type: BackendFieldType.decimal, required: true, ledgerCredits: true),
    _FieldTemplate('request_id', required: true),
    _FieldTemplate('method', required: true),
    _FieldTemplate('destination',
        type: BackendFieldType.object, required: true),
  ],
  'spaces.space_detail': [
    _FieldTemplate('space', required: true, hint: 'Project ID'),
    _FieldTemplate('admin', type: BackendFieldType.boolean),
  ],
  'spaces.admin_work_log': [
    _FieldTemplate('space', required: true, hint: 'Project ID'),
    _FieldTemplate('limit', type: BackendFieldType.integer),
  ],
  'spaces.admin_files': [
    _FieldTemplate('space', required: true, hint: 'Project ID'),
  ],
  'spaces.space_delete': [
    _FieldTemplate('space', required: true, hint: 'Project ID'),
  ],
  'spaces.computer': [
    _FieldTemplate('space', required: true, hint: 'Project ID'),
    _FieldTemplate('operation',
        required: true,
        hint: 'status, provision, keepalive, sleep, replace or forget_logins'),
  ],
  'spaces.sandbox_files': [
    _FieldTemplate('space', required: true, hint: 'Project ID'),
    _FieldTemplate('operation',
        required: true, hint: 'list, read, write, mkdir, delete, or preview'),
    _FieldTemplate('path', required: true),
    _FieldTemplate('content', type: BackendFieldType.multiline),
  ],
  'spaces.widget_action': [
    _FieldTemplate('space', required: true),
    _FieldTemplate('widget', required: true),
    _FieldTemplate('action', required: true),
    _FieldTemplate('arguments', type: BackendFieldType.object),
  ],
  'spaces.proxy_create': [
    _FieldTemplate('space', required: true),
    _FieldTemplate('room'),
    _FieldTemplate('port', type: BackendFieldType.integer, required: true),
    _FieldTemplate('title'),
    _FieldTemplate('preserve_path', type: BackendFieldType.boolean),
  ],
  'spaces.proxy_open': [
    _FieldTemplate('proxy', required: true, hint: 'Preview/proxy ID'),
  ],
  'spaces.proxy_delete': [
    _FieldTemplate('proxy', required: true, hint: 'Preview/proxy ID'),
  ],
  'spaces.desktop_install': [
    _FieldTemplate('space', required: true),
  ],
  'spaces.desktop_uninstall': [
    _FieldTemplate('space', required: true),
  ],
  'bots.bot_create': [
    _FieldTemplate('name', required: true),
    _FieldTemplate('kind', hint: 'agent or tool (an app)'),
    _FieldTemplate('vm_type', hint: 'Defaults to deepagents for agents'),
    _FieldTemplate('image_ref'),
    _FieldTemplate('spec_yml', type: BackendFieldType.multiline),
    _FieldTemplate('resources', type: BackendFieldType.object),
    _FieldTemplate('cost', type: BackendFieldType.object),
    _FieldTemplate('env', type: BackendFieldType.object, sensitive: true),
    _FieldTemplate('args', type: BackendFieldType.stringList),
    _FieldTemplate('frontend', type: BackendFieldType.multiline),
    _FieldTemplate('frontend_ref'),
    _FieldTemplate('entities', type: BackendFieldType.object),
    _FieldTemplate('description', type: BackendFieldType.multiline),
    _FieldTemplate('instructions', type: BackendFieldType.multiline),
    _FieldTemplate('provider'),
    _FieldTemplate('model'),
    _FieldTemplate('max_tokens', type: BackendFieldType.integer),
    _FieldTemplate('allowed_tools', type: BackendFieldType.stringList),
    _FieldTemplate('max_turns', type: BackendFieldType.integer),
    _FieldTemplate('skills',
        type: BackendFieldType.stringList, hint: 'JSON list of skill objects'),
    _FieldTemplate('module'),
    _FieldTemplate('widget_dsl', type: BackendFieldType.multiline),
  ],
  'bots.bot_edit': [
    _FieldTemplate('bot', required: true, hint: 'Agent ID'),
    _FieldTemplate('name'),
    _FieldTemplate('instructions', type: BackendFieldType.multiline),
    _FieldTemplate('provider'),
    _FieldTemplate('model'),
    _FieldTemplate('cost', type: BackendFieldType.object),
    _FieldTemplate('descriptor', type: BackendFieldType.object),
  ],
  'bots.bot_delete': [
    _FieldTemplate('bot', required: true, hint: 'Agent ID'),
  ],
  'market.publish': [
    _FieldTemplate('bot', required: true, hint: 'Agent or app ID'),
    _FieldTemplate('type', required: true, hint: 'agent or tool (an app)'),
    _FieldTemplate('name'),
    _FieldTemplate('description', type: BackendFieldType.multiline),
    _FieldTemplate('price',
        type: BackendFieldType.decimal, ledgerCredits: true),
    _FieldTemplate('category'),
    _FieldTemplate('image_ref'),
  ],
  'market.approve': [
    _FieldTemplate('listing', hint: 'Listing ID (or supply bot)'),
    _FieldTemplate('bot', hint: 'Bot ID (or supply listing)'),
  ],
  'market.deny': [
    _FieldTemplate('listing', hint: 'Listing ID (or supply bot)'),
    _FieldTemplate('bot', hint: 'Bot ID (or supply listing)'),
    _FieldTemplate('reason', type: BackendFieldType.multiline),
  ],
  'market.unpublish': [
    _FieldTemplate('listing', required: true),
  ],
  'tools.mcp_register': [
    _FieldTemplate('name', required: true),
    _FieldTemplate('url', required: true),
    _FieldTemplate('auth', hint: 'Empty for shared credentials or user'),
    _FieldTemplate('token', sensitive: true),
    _FieldTemplate('headers', type: BackendFieldType.object, sensitive: true),
    _FieldTemplate('descriptor', type: BackendFieldType.object),
    _FieldTemplate('listed', type: BackendFieldType.boolean),
  ],
  'tools.mcp_update': [
    _FieldTemplate('bot', required: true, hint: 'App ID'),
    _FieldTemplate('url'),
    _FieldTemplate('token', sensitive: true),
    _FieldTemplate('headers', type: BackendFieldType.object, sensitive: true),
    _FieldTemplate('auth', hint: 'Empty for shared credentials or user'),
  ],
  'tools.mcp_delete': [
    _FieldTemplate('bot', required: true, hint: 'App ID'),
  ],
  'tools.mcp_oauth_get': [
    _FieldTemplate('bot', required: true, hint: 'App ID'),
  ],
  'tools.mcp_oauth_set': [
    _FieldTemplate('bot', required: true, hint: 'App ID'),
    _FieldTemplate('client_id', required: true),
    _FieldTemplate('client_secret', sensitive: true),
    _FieldTemplate('authorization_endpoint'),
    _FieldTemplate('token_endpoint'),
    _FieldTemplate('scopes', hint: 'Space- or comma-separated scopes'),
    _FieldTemplate('params', hint: 'name=value&other=value'),
  ],
  'tools.oauth_prepare': [
    _FieldTemplate('bot', hint: 'App ID'),
    _FieldTemplate('url', hint: 'MCP server address when the app is omitted'),
    _FieldTemplate('redirect_uri', required: true),
    _FieldTemplate('client_id'),
    _FieldTemplate('client_secret', sensitive: true),
  ],
  'tools.oauth_exchange': [
    _FieldTemplate('state', required: true, sensitive: true),
    _FieldTemplate('code', required: true, sensitive: true),
  ],
  'tools.invoke': [
    _FieldTemplate('bot', required: true, hint: 'App ID'),
    _FieldTemplate('space', required: true),
    _FieldTemplate('function', required: true),
    _FieldTemplate('payload', type: BackendFieldType.object),
    _FieldTemplate('room'),
  ],
  'tools.connection_set': [
    _FieldTemplate('bot', required: true, hint: 'App ID'),
    _FieldTemplate('space', required: true),
    _FieldTemplate('token', sensitive: true),
    _FieldTemplate('refresh_token', sensitive: true),
    _FieldTemplate('expires_at', hint: 'RFC 3339 timestamp'),
    _FieldTemplate('grant', sensitive: true, hint: 'OAuth exchange state'),
  ],
  'talent.create': [
    _FieldTemplate('space', required: true),
    _FieldTemplate('recipient', required: true),
    _FieldTemplate('amount',
        type: BackendFieldType.decimal, required: true, ledgerCredits: true),
    _FieldTemplate('message', type: BackendFieldType.multiline),
    _FieldTemplate('request_id', required: true),
  ],
  'talent.list_project': [
    _FieldTemplate('space', required: true),
  ],
  'talent.respond': [
    _FieldTemplate('id', required: true, hint: 'Offer ID'),
    _FieldTemplate('status', required: true, hint: 'accepted or declined'),
  ],
  'admin.plugins_load': [
    _FieldTemplate('name', hint: 'Registered module name'),
    _FieldTemplate('path', hint: 'Or a native module path'),
    _FieldTemplate('config', type: BackendFieldType.object),
  ],
  'admin.plugins_unload': [
    _FieldTemplate('name', required: true),
  ],
  'admin.plugins_stop': [
    _FieldTemplate('name', required: true),
  ],
  'admin.plugins_set_active': [
    _FieldTemplate('category',
        required: true, hint: 'database, cache, network, filesystem, or vmm'),
    _FieldTemplate('plugin', required: true),
  ],
  'routines.create': [
    _FieldTemplate('space', required: true),
    _FieldTemplate('room'),
    _FieldTemplate('name'),
    _FieldTemplate('type', required: true),
    _FieldTemplate('target'),
    _FieldTemplate('task', type: BackendFieldType.multiline, required: true),
    _FieldTemplate('delay_sec', type: BackendFieldType.integer),
    _FieldTemplate('interval_sec', type: BackendFieldType.integer),
    _FieldTemplate('at', hint: 'Daily time, for example 09:00'),
    _FieldTemplate('timezone', hint: 'IANA timezone'),
  ],
  'routines.get': [_FieldTemplate('routine', required: true)],
  'routines.update': [
    _FieldTemplate('routine', required: true),
    _FieldTemplate('name'),
    _FieldTemplate('target'),
    _FieldTemplate('task', type: BackendFieldType.multiline),
    _FieldTemplate('delay_sec', type: BackendFieldType.integer),
    _FieldTemplate('interval_sec', type: BackendFieldType.integer),
  ],
  'routines.pause': [_FieldTemplate('routine', required: true)],
  'routines.resume': [_FieldTemplate('routine', required: true)],
  'routines.delete': [_FieldTemplate('routine', required: true)],
  'auth.profile_update': [
    _FieldTemplate('handle'),
    _FieldTemplate('email'),
    _FieldTemplate('profile', type: BackendFieldType.object),
    _FieldTemplate('current_password', sensitive: true),
    _FieldTemplate('password', sensitive: true),
  ],
  'auth.send_verification': [
    _FieldTemplate('email', required: true),
  ],
  'auth.resend_verification': [
    _FieldTemplate('email', required: true),
  ],
  'auth.verify_email': [
    _FieldTemplate('email', required: true),
    _FieldTemplate('code', required: true),
    _FieldTemplate('password', sensitive: true),
  ],
  'auth.account_delete': [
    _FieldTemplate('confirmation', required: true, hint: 'DELETE'),
  ],
  'users.metadata_public': [
    _FieldTemplate('paths', type: BackendFieldType.stringList, required: true),
  ],
  'users.file_upload': [
    _FieldTemplate('name', required: true),
    _FieldTemplate('mime'),
    _FieldTemplate('meta_path'),
    _FieldTemplate('data', type: BackendFieldType.multiline, required: true),
    _FieldTemplate('public', type: BackendFieldType.boolean),
  ],
  'users.file_delete': [
    _FieldTemplate('file', required: true),
  ],
  'users.dm_list': [
    _FieldTemplate('peer', required: true),
    _FieldTemplate('limit', type: BackendFieldType.integer),
  ],
  'users.dm_send': [
    _FieldTemplate('to', required: true, hint: 'Account or agent ID'),
    _FieldTemplate('body', type: BackendFieldType.multiline, required: true),
  ],
  'users.push_register': [
    _FieldTemplate('token', required: true, sensitive: true),
    _FieldTemplate('platform', required: true, hint: 'ios'),
    _FieldTemplate('environment',
        required: true, hint: 'development or production'),
  ],
  'users.push_unregister': [
    _FieldTemplate('token', required: true, sensitive: true),
  ],
  'usage.summary': [
    _FieldTemplate('space'),
    _FieldTemplate('limit', type: BackendFieldType.integer),
  ],
  'usage.list': [
    _FieldTemplate('space'),
    _FieldTemplate('limit', type: BackendFieldType.integer),
    _FieldTemplate('offset', type: BackendFieldType.integer),
  ],
  'usage.model_summary': [_FieldTemplate('space')],
  'spaces.invitation_accept': [
    _FieldTemplate('invitation', required: true),
  ],
  'spaces.invitation_decline': [
    _FieldTemplate('invitation', required: true),
  ],
  'llm.llm_provider_set': [
    _FieldTemplate('id', hint: 'Leave empty to create'),
    _FieldTemplate('name'),
    _FieldTemplate('kind', required: true),
    _FieldTemplate('base_url'),
    _FieldTemplate('api_key', sensitive: true),
    _FieldTemplate('enabled', type: BackendFieldType.boolean),
    _FieldTemplate('is_default', type: BackendFieldType.boolean),
    _FieldTemplate('models',
        type: BackendFieldType.stringList,
        required: true,
        hint: 'JSON list of model objects'),
    _FieldTemplate('image_model'),
    _FieldTemplate('image_price',
        type: BackendFieldType.decimal, ledgerCredits: true),
  ],
  'llm.llm_provider_delete': [
    _FieldTemplate('id', required: true, hint: 'Provider ID'),
  ],
  'llm.llm_decision_set': [
    _FieldTemplate('enabled', type: BackendFieldType.boolean, required: true),
    _FieldTemplate('provider_id'),
    _FieldTemplate('model_id'),
    _FieldTemplate('auto_approve', type: BackendFieldType.boolean),
  ],
  'spaces.opencode_set': [
    _FieldTemplate('enabled', type: BackendFieldType.boolean, required: true),
  ],
  'llm.llm_memory_set': [
    _FieldTemplate('chat_provider_id'),
    _FieldTemplate('chat_model_id'),
    _FieldTemplate('embedding_provider_id'),
    _FieldTemplate('embedding_model_id'),
  ],
};

BackendFieldType _inferType(String name, Object? value) {
  if (value is bool) return BackendFieldType.boolean;
  if (value is int) return BackendFieldType.integer;
  if (value is double || value is num) return BackendFieldType.decimal;
  if (value is List) return BackendFieldType.stringList;
  if (value is Map) return BackendFieldType.object;
  final key = name.toLowerCase();
  if (key.contains('password') ||
      key.contains('token') ||
      key.contains('secret') ||
      key.contains('api_key')) {
    return BackendFieldType.text;
  }
  if (key == 'content' ||
      key.contains('description') ||
      key.contains('instructions') ||
      key == 'prompt' ||
      key == 'reason' ||
      key == 'note') {
    return BackendFieldType.multiline;
  }
  if (key == 'limit' || key == 'offset' || key == 'port') {
    return BackendFieldType.integer;
  }
  if (key == 'amount' || key == 'cap' || key.contains('price')) {
    return BackendFieldType.decimal;
  }
  return BackendFieldType.text;
}

const _actionTitles = <String, String>{
  'users.account_update': 'Edit user',
  'users.account_password': 'Set user password',
  'users.account_delete': 'Delete user',
  'finance.wallet_mint': 'Grant credits',
  'finance.budget_set': 'Set project budget',
  'finance.purchases_label': 'Update purchase environment',
  'finance.payout_resolve': 'Resolve payout',
  'spaces.space_delete': 'Delete project',
  'spaces.computer': 'Computer operation',
  'spaces.sandbox_files': 'Workspace file',
  'spaces.proxy_create': 'Publish a preview',
  'bots.bot_create': 'Create agent',
  'bots.bot_edit': 'Edit agent',
  'bots.bot_delete': 'Delete agent',
  'market.publish': 'Publish marketplace listing',
  'market.approve': 'Approve listing',
  'market.deny': 'Deny listing',
  'market.unpublish': 'Unpublish listing',
  'tools.mcp_register': 'Add an app',
  'tools.mcp_update': 'Edit app',
  'tools.mcp_delete': 'Delete app',
  'tools.mcp_oauth_set': 'Configure app sign-in',
  'tools.connection_set': 'Connect an app',
  'finance.purchase_confirm': 'Confirm credit purchase',
  'finance.payout_request': 'Request payout',
  'auth.profile_update': 'Edit profile',
  'auth.account_delete': 'Delete account',
  'routines.create': 'Create routine',
  'routines.update': 'Edit routine',
};

const _actionDescriptions = <String, String>{
  'users.account_update': 'Update this person’s identity, role, and access.',
  'finance.wallet_mint': 'Add expiring or permanent credits to this wallet.',
  'finance.budget_set': 'Set the maximum credits this project may spend.',
  'finance.payout_resolve':
      'Record the external payment confirmation or return the reserved funds.',
  'bots.bot_create':
      'Choose the model, public details, price, and working instructions.',
  'bots.bot_edit': 'Update the agent’s model, price, and instructions.',
  'market.publish':
      'Set how this item appears and what it costs in the market.',
  'tools.mcp_register':
      'Connect an app\'s MCP server and its shared credentials.',
  'spaces.proxy_create':
      'Publish a sandbox port behind a secure project preview link.',
  'finance.payout_request':
      'The requested amount is reserved until an operator resolves it.',
  'auth.account_delete': 'This permanently removes your account and access.',
};

const _fieldChoices = <String, List<String>>{
  'users.account_update.role': ['user', 'admin'],
  'users.account_update.status': ['active', 'disabled'],
  'finance.payout_resolve.status': ['paid', 'rejected'],
  'bots.bot_create.kind': ['agent', 'tool'],
  'market.publish.type': ['agent', 'tool'],
  'spaces.computer.operation': [
    'status',
    'provision',
    'keepalive',
    'sleep',
    'replace'
  ],
  'spaces.sandbox_files.operation': [
    'list',
    'read',
    'write',
    'mkdir',
    'delete',
    'preview'
  ],
  'talent.respond.status': ['accepted', 'declined'],
  'routines.create.type': ['delayed', 'periodic'],
  'users.push_register.environment': ['development', 'production'],
  'admin.plugins_set_active.category': [
    'database',
    'cache',
    'network',
    'filesystem',
    'vmm'
  ],
};

String _humanLabel(String name) {
  const overrides = <String, String>{
    'account': 'User',
    'target': 'User',
    'space': 'Project',
    'bot': 'Agent or app',
    'listing': 'Listing',
    'payout_id': 'Payout',
    'provider_reference': 'External provider confirmation reference',
    'resolution_id': 'Resolution id',
    'api_key': 'API key',
    'client_id': 'Client id',
    'client_secret': 'Client secret',
    'base_url': 'Base URL',
    'image_ref': 'Image',
    'per_minute': 'Credits per minute',
    'max_tokens': 'Maximum tokens',
    'max_turns': 'Maximum turns',
    'allowed_tools': 'Allowed apps and functions',
    'transaction_ids': 'Transactions',
    'expires_at': 'Expires at',
    'meta_path': 'Profile location',
  };
  if (overrides[name] case final label?) return label;
  final words = name.replaceAll('_', ' ');
  return words.isEmpty
      ? 'Field'
      : '${words[0].toUpperCase()}${words.substring(1)}';
}

/// Field names that identify the record an action works on. When the screen
/// already supplies one it is passed through instead of shown as a field.
const _identifiers = {
  'account',
  'target',
  'space',
  'bot',
  'listing',
  'proxy',
  'routine',
  'invitation',
  'file',
  'payout_id',
  'id',
  'room',
  'widget',
  'peer',
  'resolution_id',
  'confirmation',
};

/// Objects whose shape is free-form; everything else that is a flat map is
/// edited as name/value rows.
const _structuredObjects = {
  'arguments',
  'payload',
  'descriptor',
  'config',
  'entities',
  'resources',
  'cost',
  'profile',
};

const _actionIcons = <String, IconData>{
  'users': Icons.person_outline_rounded,
  'finance': Icons.account_balance_wallet_outlined,
  'spaces': Icons.workspaces_outline,
  'bots': Icons.smart_toy_outlined,
  'market': Icons.storefront_outlined,
  'tools': Icons.build_outlined,
  'talent': Icons.badge_outlined,
  'admin': Icons.admin_panel_settings_outlined,
  'routines': Icons.schedule_rounded,
  'auth': Icons.manage_accounts_outlined,
  'usage': Icons.query_stats_rounded,
  'llm': Icons.memory_rounded,
};

/// Opens the standard validated action form used by every backend operation.
/// It shows as a bottom sheet on phones and a dialog elsewhere.
Future<Map<String, dynamic>?> showBackendActionForm(
  BuildContext context, {
  required String namespace,
  required String action,
  Map<String, dynamic> initialBody = const {},
}) =>
    showAppForm<Map<String, dynamic>>(
      context,
      BackendActionDialog(
        namespace: namespace,
        action: action,
        initialBody: initialBody,
      ),
    );

class _Field {
  _Field({
    required this.name,
    required this.type,
    required this.required,
    required this.sensitive,
    required this.ledgerCredits,
    required this.hidden,
    required this.fromInitialBody,
    required this.value,
    this.hint,
  }) : text = TextEditingController(
            text: value is String || value is num ? '$value' : '');

  final String name;
  final BackendFieldType type;
  final bool required;
  final bool sensitive;
  final bool ledgerCredits;
  final bool hidden;
  final bool fromInitialBody;
  final String? hint;

  /// The value of non-text editors (switches, chips, pickers, lists, maps).
  dynamic value;
  final TextEditingController text;
}

class BackendActionDialog extends StatefulWidget {
  const BackendActionDialog({
    super.key,
    required this.namespace,
    required this.action,
    this.initialBody = const {},
  });

  final String namespace;
  final String action;
  final Map<String, dynamic> initialBody;

  @override
  State<BackendActionDialog> createState() => _BackendActionDialogState();
}

class _BackendActionDialogState extends State<BackendActionDialog> {
  final formKey = GlobalKey<FormState>();
  late final List<_Field> fields;
  bool understood = false;
  final obscured = <String>{};

  String get key => '${widget.namespace}.${widget.action}';
  bool get destructive => _destructiveWords.any(widget.action.contains);

  @override
  void initState() {
    super.initState();
    final templates = _templates[key] ?? const <_FieldTemplate>[];
    final names = <String>{
      ...widget.initialBody.keys,
      ...templates.map((e) => e.name)
    };
    fields = [
      for (final name in names)
        _make(name, templates.where((item) => item.name == name).firstOrNull),
    ];
    obscured.addAll(fields.where((f) => f.sensitive).map((f) => f.name));
  }

  _Field _make(String name, _FieldTemplate? template) {
    final hasInitial = widget.initialBody.containsKey(name);
    final initial = widget.initialBody[name];
    final lowered = name.toLowerCase();
    final type = template?.type ?? _inferType(name, initial);
    final ledger = template?.ledgerCredits ?? false;
    final supplied = hasInitial && initial != null && '$initial'.isNotEmpty;
    dynamic value = initial;
    if (ledger) {
      value = initial is num ? ledgerToCredits(initial).toDouble() : 0.0;
    } else if (type == BackendFieldType.stringList) {
      value = initial is List ? initial : <dynamic>[];
    } else if (type == BackendFieldType.object) {
      value = initial is Map ? initial : <String, dynamic>{};
    } else if (type == BackendFieldType.boolean) {
      value = initial == true;
    }
    if (name == 'request_id' && !supplied) {
      value = 'req-${DateTime.now().microsecondsSinceEpoch}';
    }
    return _Field(
      name: name,
      type: type,
      required: template?.required ?? false,
      sensitive: template?.sensitive ??
          lowered.contains('password') ||
              lowered.contains('secret') ||
              lowered.contains('token') ||
              lowered.contains('api_key'),
      ledgerCredits: ledger,
      hidden: (supplied && _identifiers.contains(name)) || name == 'request_id',
      fromInitialBody: hasInitial,
      value: value,
      hint: template?.hint,
    );
  }

  @override
  void dispose() {
    for (final field in fields) {
      field.text.dispose();
    }
    super.dispose();
  }

  bool _flat(dynamic value) =>
      value is Map &&
      value.values.every((v) => v == null || v is! Map && v is! List);

  bool _jsonEditor(_Field f) =>
      (f.type == BackendFieldType.object &&
          (_structuredObjects.contains(f.name) || !_flat(f.value))) ||
      (f.type == BackendFieldType.stringList &&
          ((f.hint ?? '').contains('JSON') ||
              (f.value as List).any((v) => v is Map || v is List)));

  /// The value to send, or null to leave the field out.
  Object? _parse(_Field f) {
    if (f.hidden) return f.value;
    if (f.ledgerCredits) {
      final credits = (f.value as num?) ?? 0;
      return credits == 0 && !f.required ? null : creditsToLedger(credits);
    }
    if (_jsonEditor(f)) {
      final raw = f.text.text.trim();
      if (raw.isEmpty) return f.fromInitialBody ? f.value : null;
      return jsonDecode(raw);
    }
    final text = f.text.text.trim();
    switch (f.type) {
      case BackendFieldType.text:
      case BackendFieldType.multiline:
        if (_choicesOf(f) != null || f.name == 'expires_at' || f.name == 'at') {
          final v = f.value;
          if (v == null || '$v'.isEmpty) return null;
          return v;
        }
        return text.isEmpty && !f.fromInitialBody ? null : f.text.text;
      case BackendFieldType.integer:
        if (f.name == 'limit' || f.name.endsWith('_sec')) return f.value;
        return text.isEmpty ? null : int.parse(text);
      case BackendFieldType.decimal:
        return text.isEmpty ? null : double.parse(text);
      case BackendFieldType.boolean:
        return f.value == true;
      case BackendFieldType.stringList:
        final list = f.value as List;
        return list.isEmpty && !f.required ? null : list;
      case BackendFieldType.object:
        final map = f.value as Map;
        return map.isEmpty && !f.fromInitialBody ? null : map;
    }
  }

  List<String>? _choicesOf(_Field f) => _fieldChoices['$key.${f.name}'];

  void submit() {
    if (!(formKey.currentState?.validate() ?? false)) return;
    final body = <String, dynamic>{};
    final missing = <String>[];
    try {
      for (final f in fields) {
        final value = _parse(f);
        if (value == null) {
          if (f.required) missing.add(_humanLabel(f.name));
          continue;
        }
        body[f.name] = value;
      }
    } catch (error) {
      _toast('Check the form: $error');
      return;
    }
    if (missing.isNotEmpty) {
      _toast('Fill in: ${missing.join(', ')}');
      return;
    }
    Navigator.pop(context, body);
  }

  void _toast(String text) => ScaffoldMessenger.maybeOf(context)
      ?.showSnackBar(SnackBar(content: Text(text)));

  @override
  Widget build(BuildContext context) {
    final visible = fields.where((f) => !f.hidden).toList();
    return AppFormFrame(
      formKey: formKey,
      icon: destructive
          ? Icons.warning_amber_rounded
          : _actionIcons[widget.namespace] ?? Icons.tune_rounded,
      title: _actionTitles[key] ?? _humanLabel(widget.action),
      subtitle: _actionDescriptions[key] ??
          (destructive ? 'This action can remove or disable data.' : null),
      destructive: destructive,
      submit: destructive
          ? 'Confirm'
          : widget.action.contains('create') ||
                  widget.action.contains('register') ||
                  widget.action.contains('request')
              ? 'Create'
              : 'Save',
      onSubmit: destructive && !understood ? null : submit,
      children: [
        for (final f in visible) _editor(f),
        if (destructive)
          AppConfirmCheck(
              value: understood,
              onChanged: (v) => setState(() => understood = v),
              label: 'I understand this cannot be undone'),
      ],
    );
  }

  Widget _editor(_Field f) {
    final label = _humanLabel(f.name);
    final choices = _choicesOf(f);
    if (choices != null) {
      final options = [
        for (final c in choices) AppChoice<String>(c, _humanLabel(c)),
      ];
      final current = choices.contains('${f.value}') ? '${f.value}' : null;
      if (choices.length <= 3 && current != null) {
        return AppSegmentedField<String>(
            label: label,
            hint: f.hint,
            value: current,
            choices: options,
            onChanged: (v) => setState(() => f.value = v));
      }
      return AppChoiceField<String>(
          label: label,
          hint: f.hint,
          value: current,
          choices: options,
          onChanged: (v) => setState(() => f.value = v));
    }
    if (f.type == BackendFieldType.boolean) {
      return AppSwitchCard(
          title: label,
          subtitle: f.hint,
          value: f.value == true,
          onChanged: (v) => setState(() => f.value = v));
    }
    if (f.ledgerCredits) {
      final max = switch (f.name) {
        'cap' => 50000.0,
        'price' || 'image_price' => 5000.0,
        _ => 10000.0,
      };
      return AppAmountField(
        label: label,
        hint: f.hint ??
            '≈ ${formatLedgerUsd(creditsToLedger((f.value as num?) ?? 0))}',
        value: ((f.value as num?) ?? 0).toDouble(),
        max: max,
        step: max >= 10000 ? 50 : 10,
        decimals: 2,
        unit: 'credits',
        presets: [max / 100, max / 20, max / 10, max / 2]
            .map((v) => v.roundToDouble())
            .toList(),
        presetLabel: (v) => compactDecimal(v),
        format: (v) => '${compactDecimal(v)} credits',
        onChanged: (v) => setState(() => f.value = v),
      );
    }
    if (f.name == 'expires_at') {
      return AppExpiryField(
          label: label,
          hint: f.hint == null || f.hint!.contains('RFC') ? null : f.hint,
          value: DateTime.tryParse('${f.value ?? ''}')?.toLocal(),
          onChanged: (v) => setState(() => f.value = v == null
              ? null
              : DateTime.utc(v.year, v.month, v.day, 23, 59, 59)
                  .toIso8601String()));
    }
    if (f.name == 'at') {
      final parts = '${f.value ?? ''}'.split(':');
      final time = parts.length == 2
          ? TimeOfDay(
              hour: int.tryParse(parts[0]) ?? 9,
              minute: int.tryParse(parts[1]) ?? 0)
          : null;
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        AppFieldLabel(label, hint: 'Runs every day at this time.'),
        Wrap(spacing: 8, runSpacing: 8, children: [
          ChoiceChip(
              selected: time == null,
              label: const Text('Not daily'),
              onSelected: (_) => setState(() => f.value = null)),
          ActionChip(
            avatar: const Icon(Icons.schedule_rounded, size: 18),
            label: Text(time == null ? 'Pick a time' : time.format(context)),
            onPressed: () async {
              final picked = await showTimePicker(
                  context: context,
                  initialTime: time ?? const TimeOfDay(hour: 9, minute: 0));
              if (picked != null) {
                setState(() => f.value =
                    '${picked.hour.toString().padLeft(2, '0')}:${picked.minute.toString().padLeft(2, '0')}');
              }
            },
          ),
        ]),
      ]);
    }
    if (f.type == BackendFieldType.integer && f.name.endsWith('_sec')) {
      return AppDurationField(
          label: label.replaceAll(' sec', ''),
          hint: f.hint,
          seconds: f.value is num ? (f.value as num).toInt() : null,
          onChanged: (v) => setState(() => f.value = v));
    }
    if (f.type == BackendFieldType.integer && f.name == 'limit') {
      f.value ??= 50;
      return AppChoiceField<int>(
          label: 'How many',
          value: f.value as int?,
          choices: const [
            AppChoice(25, '25'),
            AppChoice(50, '50'),
            AppChoice(100, '100'),
            AppChoice(200, '200'),
          ],
          onChanged: (v) => setState(() => f.value = v));
    }
    if (_jsonEditor(f)) {
      if (f.text.text.isEmpty && f.value != null) {
        final v = f.value;
        if ((v is Map && v.isNotEmpty) || (v is List && v.isNotEmpty)) {
          f.text.text = const JsonEncoder.withIndent('  ').convert(v);
        }
      }
      return TextFormField(
        controller: f.text,
        minLines: 3,
        maxLines: 10,
        style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
        decoration: InputDecoration(
            labelText: label,
            helperText: f.hint ?? 'Advanced: JSON',
            alignLabelWithHint: true),
        validator: (value) {
          final text = (value ?? '').trim();
          if (text.isEmpty) return f.required ? 'Required' : null;
          try {
            final decoded = jsonDecode(text);
            if (f.type == BackendFieldType.object && decoded is! Map) {
              return 'Use a JSON object';
            }
            if (f.type == BackendFieldType.stringList && decoded is! List) {
              return 'Use a JSON list';
            }
          } catch (_) {
            return 'Not valid JSON';
          }
          return null;
        },
      );
    }
    if (f.type == BackendFieldType.stringList) {
      return AppTagsField(
          label: label,
          hint: f.hint,
          values: [for (final v in f.value as List) '$v'],
          onChanged: (v) => setState(() => f.value = v));
    }
    if (f.type == BackendFieldType.object) {
      return AppPairsEditor(
          label: label,
          hint: f.hint,
          obscureValues: f.sensitive,
          initial: {
            for (final e in (f.value as Map).entries) '${e.key}': '${e.value}'
          },
          onChanged: (v) => f.value = v);
    }
    final numeric = f.type == BackendFieldType.integer ||
        f.type == BackendFieldType.decimal;
    final multiline = f.type == BackendFieldType.multiline;
    final hidden = f.sensitive && obscured.contains(f.name);
    return TextFormField(
      controller: f.text,
      obscureText: hidden,
      minLines: multiline ? 3 : 1,
      maxLines: hidden ? 1 : (multiline ? 8 : 1),
      keyboardType: switch (f.type) {
        BackendFieldType.integer => TextInputType.number,
        BackendFieldType.decimal =>
          const TextInputType.numberWithOptions(decimal: true),
        _ => f.name.contains('email')
            ? TextInputType.emailAddress
            : f.name.contains('url')
                ? TextInputType.url
                : TextInputType.text,
      },
      inputFormatters: numeric
          ? [
              FilteringTextInputFormatter.allow(RegExp(
                  f.type == BackendFieldType.integer ? r'[0-9]' : r'[0-9.]'))
            ]
          : null,
      decoration: InputDecoration(
        labelText: label,
        hintText: f.hint,
        alignLabelWithHint: multiline,
        suffixIcon: f.sensitive
            ? IconButton(
                onPressed: () => setState(() =>
                    hidden ? obscured.remove(f.name) : obscured.add(f.name)),
                icon: Icon(hidden
                    ? Icons.visibility_outlined
                    : Icons.visibility_off_outlined),
              )
            : null,
      ),
      validator: (value) {
        final text = (value ?? '').trim();
        if (f.required && text.isEmpty) return 'Required';
        if (text.isEmpty) return null;
        if (f.type == BackendFieldType.integer && int.tryParse(text) == null) {
          return 'Enter a whole number';
        }
        if (f.type == BackendFieldType.decimal &&
            double.tryParse(text) == null) {
          return 'Enter a number';
        }
        if (f.name.contains('email') &&
            !RegExp(r'^\S+@\S+\.\S+$').hasMatch(text)) {
          return 'Enter a valid email address';
        }
        return null;
      },
    );
  }
}

/// Responsive renderer for action results. Lists of records become tables and
/// nested objects remain expandable instead of being presented as raw JSON.
class BackendResultView extends StatelessWidget {
  const BackendResultView({super.key, required this.results, this.padding});

  final Map<String, dynamic> results;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    if (results.isEmpty) {
      return const Center(child: Text('No records returned.'));
    }
    return ListView(
      padding: padding ?? const EdgeInsets.fromLTRB(24, 8, 24, 32),
      children: [
        for (final entry in results.entries)
          Card(
            margin: const EdgeInsets.only(bottom: 12),
            child: ExpansionTile(
              initiallyExpanded: true,
              leading: Icon(entry.value is Map &&
                      (entry.value as Map).containsKey('error')
                  ? Icons.error_outline_rounded
                  : Icons.cloud_done_outlined),
              title: Text(entry.key,
                  style: const TextStyle(fontWeight: FontWeight.w800)),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
                  child: _StructuredValue(value: entry.value),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _StructuredValue extends StatelessWidget {
  const _StructuredValue({required this.value});
  final dynamic value;

  bool _scalar(dynamic item) =>
      item == null || item is String || item is num || item is bool;

  @override
  Widget build(BuildContext context) {
    if (value is List) {
      final list = value as List;
      if (list.isEmpty) return const ListTile(title: Text('No records'));
      if (list.every(_scalar)) {
        return Wrap(spacing: 7, runSpacing: 7, children: [
          for (final item in list) Chip(label: Text('${item ?? '—'}')),
        ]);
      }
      if (list.every((item) => item is Map)) {
        final maps =
            list.map((item) => (item as Map).cast<String, dynamic>()).toList();
        final columns = <String>{
          for (final map in maps)
            for (final entry in map.entries)
              if (_scalar(entry.value)) entry.key,
        }.take(7).toList();
        if (columns.isNotEmpty) {
          return SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(
              columns: [
                for (final name in columns) DataColumn(label: Text(name))
              ],
              rows: [
                for (final map in maps)
                  DataRow(cells: [
                    for (final name in columns)
                      DataCell(SelectableText('${map[name] ?? '—'}')),
                  ]),
              ],
            ),
          );
        }
      }
      return Column(children: [
        for (var i = 0; i < list.length; i++)
          ExpansionTile(
            title: Text('Item ${i + 1}'),
            children: [
              Padding(
                padding: const EdgeInsets.all(12),
                child: _StructuredValue(value: list[i]),
              )
            ],
          ),
      ]);
    }
    if (value is Map) {
      final map = (value as Map).cast<String, dynamic>();
      return Column(children: [
        for (final entry in map.entries)
          if (_scalar(entry.value))
            ListTile(
              dense: true,
              title: Text(entry.key),
              trailing: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: SelectableText('${entry.value ?? '—'}',
                    textAlign: TextAlign.end),
              ),
            )
          else
            ExpansionTile(
              tilePadding: const EdgeInsets.symmetric(horizontal: 16),
              title: Text(entry.key),
              subtitle: Text(entry.value is List
                  ? '${(entry.value as List).length} records'
                  : 'Details'),
              children: [
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: _StructuredValue(value: entry.value),
                )
              ],
            ),
      ]);
    }
    return Align(
      alignment: Alignment.centerLeft,
      child: SelectableText('${value ?? '—'}'),
    );
  }
}
