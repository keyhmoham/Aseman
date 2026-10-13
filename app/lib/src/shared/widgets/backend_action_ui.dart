import 'dart:convert';

import 'package:flutter/material.dart';

import '../../core/formatting/billing_units.dart';

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

class _FieldValue {
  _FieldValue({
    required String name,
    required this.type,
    required this.required,
    required this.sensitive,
    required this.ledgerCredits,
    required this.fromInitialBody,
    this.hint,
    String value = '',
  })  : name = TextEditingController(text: name),
        value = TextEditingController(text: value);

  final TextEditingController name;
  final TextEditingController value;
  BackendFieldType type;
  bool required;
  bool sensitive;
  final bool ledgerCredits;
  final bool fromInitialBody;
  final String? hint;

  void dispose() {
    name.dispose();
    value.dispose();
  }
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
    _FieldTemplate('status', hint: 'pending, active, or disabled'),
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
        hint: 'status, provision, keepalive, sleep, or replace'),
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
    _FieldTemplate('kind', hint: 'agent, miniapp, or tool'),
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
    _FieldTemplate('bot', required: true, hint: 'Agent or miniapp ID'),
    _FieldTemplate('type', required: true, hint: 'agent or miniapp'),
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
    _FieldTemplate('bot', required: true, hint: 'MCP bot ID'),
    _FieldTemplate('url'),
    _FieldTemplate('token', sensitive: true),
    _FieldTemplate('headers', type: BackendFieldType.object, sensitive: true),
    _FieldTemplate('auth', hint: 'Empty for shared credentials or user'),
  ],
  'tools.mcp_delete': [
    _FieldTemplate('bot', required: true, hint: 'MCP bot ID'),
  ],
  'tools.mcp_oauth_get': [
    _FieldTemplate('bot', required: true, hint: 'MCP bot ID'),
  ],
  'tools.mcp_oauth_set': [
    _FieldTemplate('bot', required: true, hint: 'MCP bot ID'),
    _FieldTemplate('client_id', required: true),
    _FieldTemplate('client_secret', sensitive: true),
    _FieldTemplate('authorization_endpoint'),
    _FieldTemplate('token_endpoint'),
    _FieldTemplate('scopes', hint: 'Space- or comma-separated scopes'),
    _FieldTemplate('params', hint: 'name=value&other=value'),
  ],
  'tools.oauth_prepare': [
    _FieldTemplate('bot', hint: 'Registered MCP bot ID'),
    _FieldTemplate('url', hint: 'MCP URL when bot is omitted'),
    _FieldTemplate('redirect_uri', required: true),
    _FieldTemplate('client_id'),
    _FieldTemplate('client_secret', sensitive: true),
  ],
  'tools.oauth_exchange': [
    _FieldTemplate('state', required: true, sensitive: true),
    _FieldTemplate('code', required: true, sensitive: true),
  ],
  'tools.invoke': [
    _FieldTemplate('bot', required: true, hint: 'Tool bot ID'),
    _FieldTemplate('space', required: true),
    _FieldTemplate('function', required: true),
    _FieldTemplate('payload', type: BackendFieldType.object),
    _FieldTemplate('room'),
  ],
  'tools.connection_set': [
    _FieldTemplate('bot', required: true, hint: 'Tool bot ID'),
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
    _FieldTemplate('name', hint: 'Registered plugin name'),
    _FieldTemplate('path', hint: 'Or a native plugin path'),
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
    _FieldTemplate('type', required: true, hint: 'delayed or periodic'),
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

String _displayValue(Object? value) {
  if (value is Map || value is List) {
    return const JsonEncoder.withIndent('  ').convert(value);
  }
  return value?.toString() ?? '';
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
  'tools.mcp_register': 'Add MCP server',
  'tools.mcp_update': 'Edit MCP server',
  'tools.mcp_delete': 'Delete MCP server',
  'tools.mcp_oauth_set': 'Configure MCP sign-in',
  'tools.connection_set': 'Configure project connection',
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
  'tools.mcp_register': 'Connect an MCP endpoint and its shared credentials.',
  'spaces.proxy_create':
      'Publish a sandbox port behind a secure project preview link.',
  'finance.payout_request':
      'The requested amount is reserved until an operator resolves it.',
  'auth.account_delete': 'This permanently removes your account and access.',
};

const _fieldChoices = <String, List<String>>{
  'users.account_update.role': ['user', 'admin'],
  'users.account_update.status': ['pending', 'active', 'disabled'],
  'finance.payout_resolve.status': ['paid', 'rejected'],
  'bots.bot_create.kind': ['agent', 'tool', 'miniapp'],
  'market.publish.type': ['agent', 'tool', 'miniapp'],
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
};

String _humanLabel(String name) {
  const overrides = <String, String>{
    'account': 'User',
    'target': 'User',
    'space': 'Project',
    'bot': 'Agent or tool',
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
    'allowed_tools': 'Allowed tools',
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

/// Opens the standard validated action form used by every backend operation.
Future<Map<String, dynamic>?> showBackendActionForm(
  BuildContext context, {
  required String namespace,
  required String action,
  Map<String, dynamic> initialBody = const {},
}) {
  return showDialog<Map<String, dynamic>>(
    context: context,
    builder: (_) => BackendActionDialog(
      namespace: namespace,
      action: action,
      initialBody: initialBody,
    ),
  );
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
  late final List<_FieldValue> fields;

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
        _makeField(
            name, templates.where((item) => item.name == name).firstOrNull),
    ];
  }

  _FieldValue _makeField(String name, _FieldTemplate? template) {
    final hasInitial = widget.initialBody.containsKey(name);
    final initial = widget.initialBody[name];
    final lowered = name.toLowerCase();
    return _FieldValue(
      name: name,
      type: template?.type ?? _inferType(name, initial),
      required: template?.required ?? false,
      sensitive: template?.sensitive ??
          lowered.contains('password') ||
              lowered.contains('secret') ||
              lowered.contains('token') ||
              lowered.contains('api_key'),
      ledgerCredits: template?.ledgerCredits ?? false,
      fromInitialBody: hasInitial,
      hint: template?.hint,
      value: template?.ledgerCredits == true && initial is num
          ? ledgerCreditsField(initial)
          : _displayValue(initial),
    );
  }

  @override
  void dispose() {
    for (final field in fields) {
      field.dispose();
    }
    super.dispose();
  }

  Object? _parse(_FieldValue field) {
    final value = field.value.text.trim();
    if (field.ledgerCredits) {
      final units = parseCreditsToLedger(value);
      if (units == null) throw const FormatException('Invalid credit amount');
      return units;
    }
    switch (field.type) {
      case BackendFieldType.text:
      case BackendFieldType.multiline:
        return field.value.text;
      case BackendFieldType.integer:
        return int.parse(value);
      case BackendFieldType.decimal:
        return double.parse(value);
      case BackendFieldType.boolean:
        return value.toLowerCase() == 'true';
      case BackendFieldType.stringList:
        if (value.startsWith('[')) {
          final decoded = jsonDecode(value);
          if (decoded is! List) throw const FormatException('Expected a list');
          return decoded;
        }
        return value
            .split(',')
            .map((part) => part.trim())
            .where((part) => part.isNotEmpty)
            .toList();
      case BackendFieldType.object:
        final decoded = jsonDecode(value.isEmpty ? '{}' : value);
        if (decoded is! Map) throw const FormatException('Expected an object');
        return decoded.cast<String, dynamic>();
    }
  }

  void submit() {
    if (!(formKey.currentState?.validate() ?? false)) return;
    final body = <String, dynamic>{};
    try {
      for (final field in fields) {
        final name = field.name.text.trim();
        final value = field.value.text.trim();
        if (name.isEmpty || (value.isEmpty && !field.fromInitialBody)) continue;
        if (body.containsKey(name)) {
          throw FormatException('Duplicate field: $name');
        }
        body[name] = _parse(field);
      }
      Navigator.pop(context, body);
    } catch (error) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Check the form: $error')));
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(_actionTitles[key] ?? _humanLabel(widget.action)),
        content: SizedBox(
          width: 680,
          child: Form(
            key: formKey,
            child: SingleChildScrollView(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (_actionDescriptions[key] case final description?)
                      Text(description,
                          style: TextStyle(
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant)),
                    if (destructive) ...[
                      const SizedBox(height: 12),
                      Card(
                        color: Theme.of(context).colorScheme.errorContainer,
                        child: const ListTile(
                          leading: Icon(Icons.warning_amber_rounded),
                          title:
                              Text('This action can remove or disable data.'),
                          subtitle:
                              Text('Review the identifiers before continuing.'),
                        ),
                      ),
                    ],
                    const SizedBox(height: 14),
                    for (var index = 0; index < fields.length; index++)
                      _FieldEditor(
                        key: ValueKey(fields[index]),
                        field: fields[index],
                        actionKey: key,
                      ),
                  ]),
            ),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          FilledButton.icon(
            onPressed: submit,
            icon: Icon(destructive
                ? Icons.warning_amber_rounded
                : Icons.play_arrow_rounded),
            label: Text(destructive
                ? 'Confirm'
                : widget.action.contains('create') ||
                        widget.action.contains('register') ||
                        widget.action.contains('request')
                    ? 'Create'
                    : 'Save'),
          ),
        ],
      );
}

class _FieldEditor extends StatefulWidget {
  const _FieldEditor({
    super.key,
    required this.field,
    required this.actionKey,
  });

  final _FieldValue field;
  final String actionKey;

  @override
  State<_FieldEditor> createState() => _FieldEditorState();
}

class _FieldEditorState extends State<_FieldEditor> {
  bool obscure = true;

  Widget _valueEditor(_FieldValue field) {
    final choices = _fieldChoices['${widget.actionKey}.${field.name.text}'];
    if (choices != null) {
      final value =
          choices.contains(field.value.text) ? field.value.text : null;
      return DropdownButtonFormField<String>(
        initialValue: value,
        decoration: InputDecoration(
          labelText: _humanLabel(field.name.text),
          hintText: field.hint ?? 'Choose an option',
        ),
        items: [
          for (final choice in choices)
            DropdownMenuItem(value: choice, child: Text(_humanLabel(choice))),
        ],
        onChanged: (value) => field.value.text = value ?? '',
        validator: (value) =>
            field.required && value == null ? 'Required' : null,
      );
    }
    if (field.type == BackendFieldType.boolean) {
      final current = field.value.text == 'true' || field.value.text == 'false'
          ? field.value.text
          : null;
      return DropdownButtonFormField<String>(
        initialValue: current,
        decoration: InputDecoration(
          labelText: _humanLabel(field.name.text),
          hintText: field.hint ?? 'Choose yes or no',
        ),
        items: const [
          DropdownMenuItem(value: 'true', child: Text('Yes')),
          DropdownMenuItem(value: 'false', child: Text('No')),
        ],
        onChanged: (value) => field.value.text = value ?? '',
        validator: (value) =>
            field.required && value == null ? 'Required' : null,
      );
    }
    return TextFormField(
      controller: field.value,
      obscureText: field.sensitive && obscure,
      minLines: field.type == BackendFieldType.multiline ||
              field.type == BackendFieldType.object
          ? 3
          : 1,
      maxLines: field.sensitive && obscure
          ? 1
          : field.type == BackendFieldType.multiline ||
                  field.type == BackendFieldType.object
              ? 8
              : 1,
      keyboardType: switch (field.type) {
        BackendFieldType.integer => TextInputType.number,
        BackendFieldType.decimal =>
          const TextInputType.numberWithOptions(decimal: true),
        _ => TextInputType.text,
      },
      decoration: InputDecoration(
        labelText: _humanLabel(field.name.text),
        hintText: field.hint,
        suffixText: field.ledgerCredits ? 'credits' : null,
        suffixIcon: field.sensitive
            ? IconButton(
                onPressed: () => setState(() => obscure = !obscure),
                icon: Icon(obscure
                    ? Icons.visibility_off_outlined
                    : Icons.visibility_outlined),
              )
            : null,
      ),
      validator: (value) {
        final text = (value ?? '').trim();
        if (field.required && text.isEmpty) return 'Required';
        if (text.isEmpty) return null;
        try {
          switch (field.type) {
            case BackendFieldType.integer:
              int.parse(text);
              break;
            case BackendFieldType.decimal:
              double.parse(text);
              break;
            case BackendFieldType.object:
              if (jsonDecode(text) is! Map) return 'Use a JSON object';
              break;
            case BackendFieldType.stringList:
              if (text.startsWith('[') && jsonDecode(text) is! List) {
                return 'Use comma-separated values or a JSON list';
              }
              break;
            case BackendFieldType.boolean:
            case BackendFieldType.text:
            case BackendFieldType.multiline:
              break;
          }
        } catch (_) {
          return 'Invalid ${field.type.name}';
        }
        return null;
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final field = widget.field;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: _valueEditor(field),
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
