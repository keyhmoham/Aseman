import 'dart:async';

import 'package:flutter/material.dart';

import '../../../app_dependencies.dart';
import '../../../core/auth/federated_sign_in.dart';
import '../../../core/network/session_controller.dart';
import '../../../shared/widgets/app_brand.dart';
import '../../../shared/widgets/glow_painter.dart';
import '../../../shared/widgets/segmented_tab_bar.dart';
import '../../../shared/widgets/skeleton.dart';
import 'google_sign_in_button.dart';

/// Gates the whole app behind authentication. Shows the auth screen until a
/// session exists, then the main shell.
class AuthGate extends StatelessWidget {
  const AuthGate({super.key, required this.dependencies, required this.child});

  final AppDependencies dependencies;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: dependencies.sessionController,
      builder: (context, _) {
        if (!dependencies.sessionController.isReady) {
          return const Scaffold(body: SafeArea(child: SkeletonPage()));
        }
        if (!dependencies.sessionController.isLoggedIn) {
          return AuthScreen(dependencies: dependencies);
        }
        return child;
      },
    );
  }
}

/// Login / register screen against the Aseman auth namespace.
class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key, required this.dependencies});

  final AppDependencies dependencies;

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen>
    with SingleTickerProviderStateMixin {
  late final TabController tabs;
  final handleController = TextEditingController();
  final emailController = TextEditingController();
  final accountController = TextEditingController();
  final passwordController = TextEditingController();
  bool _obscure = true;
  bool _providersLoading = true;
  bool _googleEnabled = false;
  bool _googleReady = false;
  bool _appleEnabled = false;
  StreamSubscription<String>? _googleTokens;
  StreamSubscription<Object>? _googleErrors;

  @override
  void initState() {
    super.initState();
    tabs = TabController(length: 2, vsync: this)
      ..addListener(() {
        if (!tabs.indexIsChanging && mounted) setState(() {});
      });
    _googleTokens = FederatedSignIn.instance.googleTokens.listen(_finishGoogle);
    _googleErrors =
        FederatedSignIn.instance.googleErrors.listen(_providerError);
    _loadProviders();
  }

  @override
  void dispose() {
    tabs.dispose();
    handleController.dispose();
    emailController.dispose();
    accountController.dispose();
    passwordController.dispose();
    _googleTokens?.cancel();
    _googleErrors?.cancel();
    super.dispose();
  }

  SessionController get session => widget.dependencies.sessionController;

  Future<void> _submit() async {
    FocusScope.of(context).unfocus();
    final controller = session;
    final bool ok;
    if (tabs.index == 0) {
      ok = await controller.login(
          accountController.text.trim(), passwordController.text);
    } else {
      ok = await controller.register(
        handleController.text.trim(),
        emailController.text.trim(),
        passwordController.text,
      );
    }
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(controller.error ?? 'Authentication failed')),
      );
    }
  }

  Future<void> _loadProviders() async {
    try {
      final value = await widget.dependencies.service
          .invokeAction('auth', 'config') as Map?;
      final google = value?['google'] == true;
      final clientId = '${value?['google_client_id'] ?? ''}'.trim();
      var googleReady = false;
      if (google && clientId.isNotEmpty) {
        await FederatedSignIn.instance.initializeGoogle(clientId);
        googleReady = true;
      }
      var apple = value?['apple'] == true;
      if (apple) apple = await FederatedSignIn.instance.appleAvailable();
      if (!mounted) return;
      setState(() {
        _googleEnabled = google;
        _googleReady = googleReady;
        _appleEnabled = apple;
        _providersLoading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _providersLoading = false);
    }
  }

  Future<void> _finishGoogle(String token) async {
    final ok = await session.oauth('google', token);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(session.error ?? 'Sign-in failed')));
    }
  }

  void _providerError(Object error) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('Google sign-in failed: $error')));
  }

  Future<void> _googleOAuth() async {
    try {
      await FederatedSignIn.instance.authenticateGoogle();
    } catch (error) {
      _providerError(error);
    }
  }

  Future<void> _appleOAuth() async {
    try {
      final token = await FederatedSignIn.instance.authenticateApple();
      final ok = await session.oauth('apple', token);
      if (!ok && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(session.error ?? 'Sign-in failed')));
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Apple sign-in failed: $error')));
      }
    }
  }

  Future<String?> _textDialog({
    required String title,
    required String label,
    bool obscure = false,
  }) async {
    final controller = TextEditingController();
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          obscureText: obscure,
          autofocus: true,
          decoration: InputDecoration(labelText: label),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, controller.text),
              child: const Text('Continue')),
        ],
      ),
    );
    controller.dispose();
    return value;
  }

  Future<void> _forgotPassword() async {
    final email = await _textDialog(title: 'Reset password', label: 'Email');
    if (email == null || email.trim().isEmpty || !mounted) return;
    try {
      await widget.dependencies.service.invokeAction('auth', 'password_forgot',
          body: {'email': email.trim()});
      if (!mounted) return;
      final code = await _textDialog(title: 'Verification code', label: 'Code');
      if (code == null || code.trim().isEmpty || !mounted) return;
      final password = await _textDialog(
          title: 'Choose a new password', label: 'New password', obscure: true);
      if (password == null || password.isEmpty || !mounted) return;
      await widget.dependencies.service
          .invokeAction('auth', 'password_reset', body: {
        'email': email.trim(),
        'code': code.trim(),
        'password': password,
      });
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Password updated. You can sign in now.')));
    } catch (error) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Password reset failed: $error')));
    }
  }

  Future<void> _verifyEmail() async {
    final email = emailController.text.trim().isNotEmpty
        ? emailController.text.trim()
        : await _textDialog(title: 'Verify email', label: 'Email');
    if (email == null || email.isEmpty || !mounted) return;
    try {
      await widget.dependencies.service
          .invokeAction('auth', 'send_verification', body: {'email': email});
      if (!mounted) return;
      final code =
          await _textDialog(title: 'Verify email', label: '6-digit code');
      if (code == null || code.isEmpty || !mounted) return;
      final verified = await widget.dependencies.service.verifyEmail(
          email: email, code: code, password: passwordController.text);
      if (verified != null) await session.adopt(verified);
      if (mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Email verified')));
    } catch (error) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Verification failed: $error')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: Stack(children: [
        Positioned.fill(
            child: CustomPaint(
                painter: GlowPainter(scheme.primary, scheme.tertiary))),
        SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: AnimatedBuilder(
                  animation: session,
                  builder: (context, _) => Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const AppBrand(),
                      const SizedBox(height: 8),
                      Text(
                        'Aseman',
                        style:
                            Theme.of(context).textTheme.headlineSmall?.copyWith(
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: -0.5,
                                ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Your federated agentic workspace',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color:
                                Theme.of(context).colorScheme.onSurfaceVariant),
                      ),
                      const SizedBox(height: 28),
                      _panel(context, scheme),
                      const SizedBox(height: 16),
                      if (session.isBusy)
                        const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ]),
    );
  }

  Widget _panel(BuildContext context, ColorScheme scheme) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        SegmentedTabBar(
          controller: tabs,
          labels: const ['Log in', 'Create account'],
          icons: const [Icons.login_rounded, Icons.person_add_alt_rounded],
        ),
        const SizedBox(height: 20),
        if (tabs.index == 0) ...[
          TextField(
            controller: accountController,
            textInputAction: TextInputAction.next,
            decoration: const InputDecoration(
              labelText: 'Handle or email',
              prefixIcon: Icon(Icons.person_outline),
            ),
          ),
          const SizedBox(height: 12),
        ] else ...[
          TextField(
            controller: handleController,
            textInputAction: TextInputAction.next,
            decoration: const InputDecoration(
              labelText: 'Handle',
              prefixIcon: Icon(Icons.alternate_email),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: emailController,
            textInputAction: TextInputAction.next,
            keyboardType: TextInputType.emailAddress,
            decoration: const InputDecoration(
              labelText: 'Email',
              prefixIcon: Icon(Icons.mail_outline),
            ),
          ),
          const SizedBox(height: 12),
        ],
        TextField(
          controller: passwordController,
          obscureText: _obscure,
          onSubmitted: (_) => _submit(),
          decoration: InputDecoration(
            labelText: 'Password',
            prefixIcon: const Icon(Icons.lock_outline),
            suffixIcon: IconButton(
              icon: Icon(_obscure ? Icons.visibility_off : Icons.visibility),
              onPressed: () => setState(() => _obscure = !_obscure),
            ),
          ),
        ),
        const SizedBox(height: 20),
        SizedBox(
          width: double.infinity,
          height: 48,
          child: FilledButton(
            onPressed: session.isBusy ? null : _submit,
            child: Text(tabs.index == 0 ? 'Log in' : 'Create account'),
          ),
        ),
        if (tabs.index == 0)
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
                onPressed: _forgotPassword,
                child: const Text('Forgot password?')),
          )
        else
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
                onPressed: _verifyEmail, child: const Text('Verify email')),
          ),
        if (_providersLoading || _googleEnabled || _appleEnabled) ...[
          const SizedBox(height: 8),
          const Row(children: [
            Expanded(child: Divider()),
            Padding(
                padding: EdgeInsets.symmetric(horizontal: 10),
                child: Text('OR')),
            Expanded(child: Divider())
          ]),
          const SizedBox(height: 10),
          if (_providersLoading) ...const [
            SkeletonField(height: 48),
            SizedBox(height: 10),
            SkeletonField(height: 48),
          ] else ...[
            if (_googleEnabled)
              SizedBox(
                width: double.infinity,
                child: buildGoogleSignInButton(
                  ready: _googleReady,
                  busy: session.isBusy,
                  onPressed: _googleOAuth,
                ),
              ),
            if (_googleEnabled && _appleEnabled) const SizedBox(height: 10),
            if (_appleEnabled)
              SizedBox(
                width: double.infinity,
                height: 48,
                child: OutlinedButton.icon(
                  onPressed: session.isBusy ? null : _appleOAuth,
                  icon: const Icon(Icons.apple),
                  label: const Text('Continue with Apple'),
                ),
              ),
          ],
        ],
      ]),
    );
  }
}
