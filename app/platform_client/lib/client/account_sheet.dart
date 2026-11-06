import 'package:flutter/material.dart';

import 'node_api.dart';

/// Signs a person in to (or up on) the platform's own accounts.
///
/// Resolves to true when someone signed in.
Future<bool> showAccountSheet(BuildContext context, NodeApi api, String platformName) async {
  final done = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: _AccountForm(api: api, platformName: platformName),
    ),
  );
  return done ?? false;
}

class _AccountForm extends StatefulWidget {
  const _AccountForm({required this.api, required this.platformName});

  final NodeApi api;
  final String platformName;

  @override
  State<_AccountForm> createState() => _AccountFormState();
}

class _AccountFormState extends State<_AccountForm> {
  final _account = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _signUp = false;
  bool _busy = false;
  String _error = '';

  @override
  void dispose() {
    _account.dispose();
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = '';
    });
    try {
      if (_signUp) {
        await widget.api.signUp(_account.text.trim(), _email.text.trim(), _password.text);
      } else {
        await widget.api.signIn(_account.text.trim(), _password.text);
      }
      if (mounted) Navigator.of(context).pop(true);
    } on NodeException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        child: AutofillGroup(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
            Text(_signUp ? 'Join ${widget.platformName}' : 'Sign in to ${widget.platformName}',
                style: theme.textTheme.titleLarge),
            const SizedBox(height: 16),
            TextField(
              key: const ValueKey('account'),
              controller: _account,
              autofillHints: [_signUp ? AutofillHints.newUsername : AutofillHints.username],
              decoration: InputDecoration(labelText: _signUp ? 'Username' : 'Username or email'),
              textInputAction: TextInputAction.next,
            ),
            if (_signUp) ...[
              const SizedBox(height: 12),
              TextField(
                key: const ValueKey('email'),
                controller: _email,
                keyboardType: TextInputType.emailAddress,
                autofillHints: const [AutofillHints.email],
                decoration: const InputDecoration(labelText: 'Email'),
                textInputAction: TextInputAction.next,
              ),
            ],
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('password'),
              controller: _password,
              obscureText: true,
              autofillHints: [_signUp ? AutofillHints.newPassword : AutofillHints.password],
              decoration: const InputDecoration(labelText: 'Password'),
              onSubmitted: (_) => _busy ? null : _submit(),
            ),
            if (_error.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(_error, style: TextStyle(color: theme.colorScheme.error)),
            ],
            const SizedBox(height: 20),
            FilledButton(
              onPressed: _busy ? null : _submit,
              child: _busy
                  ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : Text(_signUp ? 'Create account' : 'Sign in'),
            ),
            TextButton(
              onPressed: _busy ? null : () => setState(() => _signUp = !_signUp),
              child: Text(_signUp ? 'I have an account' : 'Create an account'),
            ),
          ]),
        ),
      ),
    );
  }
}
