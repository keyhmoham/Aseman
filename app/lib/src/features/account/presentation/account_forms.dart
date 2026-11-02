import 'package:flutter/material.dart';

import '../../../core/formatting/billing_units.dart';
import '../../../shared/widgets/app_form.dart';
import '../../../shared/widgets/app_inputs.dart';
import '../../../shared/widgets/backend_action_ui.dart';

/// Opens the purpose-built form for an account action, falling back to the
/// generic action form. Returns the request body, or null when cancelled.
///
/// `auth.profile_update` takes a `_mode` of `profile`, `identity` or
/// `password`; `finance.payout_request` takes the withdrawable balance in
/// ledger units as `_available`.
Future<Map<String, dynamic>?> showAccountActionForm(
  BuildContext context, {
  required String namespace,
  required String action,
  Map<String, dynamic> initialBody = const {},
}) {
  final key = '$namespace.$action';
  final Widget? form = switch (key) {
    'auth.profile_update' => switch ('${initialBody['_mode'] ?? ''}') {
        'password' => const _PasswordForm(),
        'identity' => _IdentityForm(initial: initialBody),
        _ => _ProfileForm(initial: initialBody),
      },
    'finance.payout_request' => _PayoutRequestForm(initial: initialBody),
    _ => null,
  };
  if (form == null) {
    return showBackendActionForm(context,
        namespace: namespace,
        action: action,
        initialBody: {
          for (final e in initialBody.entries)
            if (!e.key.startsWith('_')) e.key: e.value
        });
  }
  return showAppForm<Map<String, dynamic>>(context, form);
}

Map<String, dynamic> _asMap(dynamic v) =>
    v is Map ? v.map((k, x) => MapEntry('$k', x)) : <String, dynamic>{};

class _ProfileForm extends StatefulWidget {
  const _ProfileForm({required this.initial});
  final Map<String, dynamic> initial;
  @override
  State<_ProfileForm> createState() => _ProfileFormState();
}

class _ProfileFormState extends State<_ProfileForm> {
  late final Map<String, dynamic> profile = _asMap(widget.initial['profile']);
  late final first = TextEditingController(
      text: '${profile['firstName'] ?? profile['first_name'] ?? ''}');
  late final last = TextEditingController(
      text: '${profile['lastName'] ?? profile['last_name'] ?? ''}');
  late final bio = TextEditingController(text: '${profile['bio'] ?? ''}');
  late bool hireable = profile['hireable'] == true;
  late List<String> skills = profile['skills'] is List
      ? [for (final s in profile['skills'] as List) '$s']
      : <String>[];
  late double rate = ledgerToCredits(profile['rate'] is num
          ? profile['rate'] as num
          : num.tryParse('${profile['rate'] ?? ''}') ?? 0)
      .toDouble();

  @override
  void dispose() {
    first.dispose();
    last.dispose();
    bio.dispose();
    super.dispose();
  }

  void submit() {
    final next = <String, dynamic>{};
    void put(String key, dynamic value, dynamic was) {
      if ('$value' != '${was ?? ''}') next[key] = value;
    }

    put('firstName', first.text.trim(),
        profile['firstName'] ?? profile['first_name']);
    put('lastName', last.text.trim(),
        profile['lastName'] ?? profile['last_name']);
    put('bio', bio.text.trim(), profile['bio']);
    if (hireable != (profile['hireable'] == true)) next['hireable'] = hireable;
    final was = profile['skills'] is List
        ? [for (final s in profile['skills'] as List) '$s']
        : <String>[];
    if (skills.join('\u0000') != was.join('\u0000')) next['skills'] = skills;
    final units = creditsToLedger(rate);
    if (hireable && units != (profile['rate'] is num ? profile['rate'] : 0)) {
      next['rate'] = units;
    }
    Navigator.pop(context, {'profile': next});
  }

  @override
  Widget build(BuildContext context) => AppFormFrame(
        icon: Icons.person_outline_rounded,
        title: 'Edit profile',
        subtitle: 'How people see you across Aseman.',
        submit: 'Save profile',
        onSubmit: submit,
        children: [
          Row(children: [
            Expanded(
                child: TextField(
                    controller: first,
                    decoration:
                        const InputDecoration(labelText: 'First name'))),
            const SizedBox(width: 12),
            Expanded(
                child: TextField(
                    controller: last,
                    decoration: const InputDecoration(labelText: 'Last name'))),
          ]),
          TextField(
            controller: bio,
            minLines: 3,
            maxLines: 6,
            maxLength: 280,
            decoration: const InputDecoration(
                labelText: 'Bio',
                hintText: 'What you do and what you are good at',
                alignLabelWithHint: true),
          ),
          AppSwitchCard(
            icon: Icons.badge_outlined,
            title: 'Available for hire',
            subtitle:
                'List yourself in the talent directory once an operator approves you.',
            value: hireable,
            onChanged: (v) => setState(() => hireable = v),
          ),
          if (hireable) ...[
            AppTagsField(
              label: 'Skills',
              values: skills,
              onChanged: (v) => setState(() => skills = v),
              suggestions: const [
                'collaboration',
                'research',
                'agents',
                'python',
                'product',
                'design',
                'writing',
              ],
            ),
            AppAmountField(
              label: 'Hourly rate',
              hint: rate == 0
                  ? 'Discuss with each client'
                  : '≈ ${formatLedgerUsd(creditsToLedger(rate))} an hour',
              value: rate,
              max: 20000,
              step: 100,
              decimals: 0,
              unit: 'credits',
              presets: const [0, 2500, 5000, 10000],
              presetLabel: (v) => v == 0 ? 'Negotiable' : compactDecimal(v),
              format: (v) =>
                  v == 0 ? 'Negotiable' : '${compactDecimal(v)} credits / h',
              onChanged: (v) => setState(() => rate = v),
            ),
          ],
        ],
      );
}

class _IdentityForm extends StatefulWidget {
  const _IdentityForm({required this.initial});
  final Map<String, dynamic> initial;
  @override
  State<_IdentityForm> createState() => _IdentityFormState();
}

class _IdentityFormState extends State<_IdentityForm> {
  final formKey = GlobalKey<FormState>();
  late final handle =
      TextEditingController(text: '${widget.initial['handle'] ?? ''}');
  late final email =
      TextEditingController(text: '${widget.initial['email'] ?? ''}');

  @override
  void dispose() {
    handle.dispose();
    email.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AppFormFrame(
        formKey: formKey,
        icon: Icons.alternate_email_rounded,
        title: 'Sign-in identity',
        subtitle:
            'Your username is your public @handle. A new email needs verifying again.',
        submit: 'Save',
        onSubmit: () {
          if (!(formKey.currentState?.validate() ?? false)) return;
          final body = <String, dynamic>{};
          final h = handle.text.trim().replaceFirst(RegExp(r'^@+'), '');
          if (h != '${widget.initial['handle'] ?? ''}') body['handle'] = h;
          final e = email.text.trim();
          if (e != '${widget.initial['email'] ?? ''}') body['email'] = e;
          Navigator.pop(context, body);
        },
        children: [
          TextFormField(
            controller: handle,
            decoration: const InputDecoration(
                labelText: 'Username',
                prefixIcon: Icon(Icons.alternate_email_rounded)),
            validator: (v) =>
                RegExp(r'^@?[A-Za-z0-9_.-]{2,}$').hasMatch((v ?? '').trim())
                    ? null
                    : 'Letters, numbers, dots, dashes and underscores',
          ),
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
        ],
      );
}

class _PasswordForm extends StatefulWidget {
  const _PasswordForm();
  @override
  State<_PasswordForm> createState() => _PasswordFormState();
}

class _PasswordFormState extends State<_PasswordForm> {
  final formKey = GlobalKey<FormState>();
  final current = TextEditingController();
  final next = TextEditingController();
  bool showCurrent = false;

  @override
  void dispose() {
    current.dispose();
    next.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AppFormFrame(
        formKey: formKey,
        icon: Icons.password_rounded,
        title: 'Change password',
        subtitle: 'Other devices stay signed in until their session expires.',
        submit: 'Change password',
        onSubmit: () {
          if (!(formKey.currentState?.validate() ?? false)) return;
          Navigator.pop(context,
              {'current_password': current.text, 'password': next.text});
        },
        children: [
          TextFormField(
            controller: current,
            obscureText: !showCurrent,
            autofillHints: const [AutofillHints.password],
            decoration: InputDecoration(
              labelText: 'Current password',
              prefixIcon: const Icon(Icons.lock_open_rounded),
              suffixIcon: IconButton(
                  onPressed: () => setState(() => showCurrent = !showCurrent),
                  icon: Icon(showCurrent
                      ? Icons.visibility_off_outlined
                      : Icons.visibility_outlined)),
            ),
            validator: (v) =>
                (v ?? '').isEmpty ? 'Enter your current password' : null,
          ),
          AppPasswordField(controller: next),
        ],
      );
}

class _PayoutRequestForm extends StatefulWidget {
  const _PayoutRequestForm({required this.initial});
  final Map<String, dynamic> initial;
  @override
  State<_PayoutRequestForm> createState() => _PayoutRequestFormState();
}

class _PayoutRequestFormState extends State<_PayoutRequestForm> {
  final formKey = GlobalKey<FormState>();
  late final double available = ledgerToCredits(
          widget.initial['_available'] is num
              ? widget.initial['_available'] as num
              : 0)
      .toDouble();
  late double credits = available;
  String method = 'bank';
  String network = 'Ethereum';
  final holder = TextEditingController();
  final iban = TextEditingController();
  final swift = TextEditingController();
  final paypal = TextEditingController();
  final wallet = TextEditingController();

  @override
  void dispose() {
    for (final c in [holder, iban, swift, paypal, wallet]) {
      c.dispose();
    }
    super.dispose();
  }

  Map<String, String> get destination => switch (method) {
        'paypal' => {'email': paypal.text.trim()},
        'crypto' => {'network': network, 'address': wallet.text.trim()},
        _ => {
            'name': holder.text.trim(),
            'iban': iban.text.replaceAll(' ', '').toUpperCase(),
            if (swift.text.trim().isNotEmpty)
              'swift': swift.text.trim().toUpperCase(),
          },
      };

  String? required(String? v) => (v ?? '').trim().isEmpty ? 'Required' : null;

  @override
  Widget build(BuildContext context) {
    final max = available > 0 ? available : 10000.0;
    return AppFormFrame(
      formKey: formKey,
      icon: Icons.north_east_rounded,
      title: 'Request a payout',
      subtitle:
          'The amount is reserved until an operator pays it or returns it to your wallet.',
      submit: 'Request ${compactDecimal(credits)} credits',
      onSubmit: credits <= 0
          ? null
          : () {
              if (!(formKey.currentState?.validate() ?? false)) return;
              Navigator.pop(context, {
                'amount': creditsToLedger(credits),
                'request_id': 'payout-${DateTime.now().microsecondsSinceEpoch}',
                'method': method,
                'destination': destination,
              });
            },
      children: [
        AppAmountField(
          label: 'Amount',
          hint: available > 0
              ? '${compactDecimal(available)} credits available · ≈ ${formatLedgerUsd(creditsToLedger(credits))}'
              : '≈ ${formatLedgerUsd(creditsToLedger(credits))}',
          value: credits.clamp(0, max).toDouble(),
          max: max,
          step: max >= 1000 ? 50 : 1,
          decimals: 0,
          unit: 'credits',
          presets: available > 0
              ? [
                  (available / 4).floorToDouble(),
                  (available / 2).floorToDouble(),
                  available.floorToDouble(),
                ]
              : const [],
          presetLabel: (v) =>
              v == available.floorToDouble() ? 'All' : compactDecimal(v),
          format: (v) => '${compactDecimal(v)} credits',
          onChanged: (v) => setState(() => credits = v),
        ),
        AppSegmentedField<String>(
          label: 'Pay me by',
          value: method,
          onChanged: (v) => setState(() => method = v),
          choices: const [
            AppChoice('bank', 'Bank', icon: Icons.account_balance_outlined),
            AppChoice('paypal', 'PayPal', icon: Icons.alternate_email_rounded),
            AppChoice('crypto', 'Crypto', icon: Icons.currency_bitcoin_rounded),
          ],
        ),
        if (method == 'bank')
          Column(children: [
            TextFormField(
                controller: holder,
                validator: required,
                decoration: const InputDecoration(
                    labelText: 'Account holder',
                    prefixIcon: Icon(Icons.person_outline_rounded))),
            const SizedBox(height: 12),
            TextFormField(
                controller: iban,
                validator: (v) =>
                    RegExp(r'^[A-Za-z]{2}[0-9]{2}[A-Za-z0-9 ]{10,}$')
                            .hasMatch((v ?? '').trim())
                        ? null
                        : 'Enter a valid IBAN',
                decoration: const InputDecoration(
                    labelText: 'IBAN',
                    hintText: 'DE89 3704 0044 0532 0130 00',
                    prefixIcon: Icon(Icons.numbers_rounded))),
            const SizedBox(height: 12),
            TextFormField(
                controller: swift,
                decoration: const InputDecoration(
                    labelText: 'SWIFT / BIC (optional)',
                    prefixIcon: Icon(Icons.public_rounded))),
          ])
        else if (method == 'paypal')
          TextFormField(
              controller: paypal,
              keyboardType: TextInputType.emailAddress,
              validator: (v) =>
                  RegExp(r'^\S+@\S+\.\S+$').hasMatch((v ?? '').trim())
                      ? null
                      : 'Enter your PayPal email',
              decoration: const InputDecoration(
                  labelText: 'PayPal email',
                  prefixIcon: Icon(Icons.mail_outline_rounded)))
        else
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            AppChoiceField<String>(
              label: 'Network',
              value: network,
              onChanged: (v) => setState(() => network = v),
              choices: const [
                AppChoice('Ethereum', 'Ethereum'),
                AppChoice('Base', 'Base'),
                AppChoice('Solana', 'Solana'),
                AppChoice('Bitcoin', 'Bitcoin'),
              ],
            ),
            const SizedBox(height: 14),
            TextFormField(
                controller: wallet,
                validator: required,
                decoration: const InputDecoration(
                    labelText: 'Wallet address',
                    prefixIcon: Icon(Icons.account_balance_wallet_outlined))),
          ]),
      ],
    );
  }
}
