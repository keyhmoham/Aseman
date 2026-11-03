import 'dart:async';

import 'package:flutter/material.dart';

import '../../../app_dependencies.dart';
import '../../../core/auth/federated_sign_in.dart';
import '../../../core/network/session_controller.dart';
import '../../../core/theme/app_shape.dart';
import '../../../core/theme/theme_pack_controller.dart';
import '../../../shared/widgets/app_brand.dart';
import '../../../shared/widgets/overlay_panels.dart';
import '../../../shared/widgets/segmented_tab_bar.dart';
import '../../../shared/widgets/skeleton.dart';
import '../../../shared/widgets/sky_ui.dart';
import '../../brain/brain_avatar.dart';
import '../../marketing/marketing_links.dart';
import 'google_sign_in_button.dart';
import 'sso_sign_in.dart';

/// Gates the whole app behind authentication. Shows the auth screen until a
/// session exists, then the main shell.
class AuthGate extends StatefulWidget {
  const AuthGate({super.key, required this.dependencies, required this.child});

  final AppDependencies dependencies;
  final Widget child;

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  String? _themeSyncedFor;

  @override
  void initState() {
    super.initState();
    widget.dependencies.sessionController.addListener(_syncViewer);
    _syncViewer();
  }

  @override
  void didUpdateWidget(covariant AuthGate old) {
    super.didUpdateWidget(old);
    if (old.dependencies.sessionController !=
        widget.dependencies.sessionController) {
      old.dependencies.sessionController.removeListener(_syncViewer);
      widget.dependencies.sessionController.addListener(_syncViewer);
      _syncViewer();
    }
  }

  @override
  void dispose() {
    widget.dependencies.sessionController.removeListener(_syncViewer);
    super.dispose();
  }

  void _syncViewer() {
    final session = widget.dependencies.sessionController;
    if (!session.isReady) return;
    if (!session.isLoggedIn) {
      BrainAvatarPrefs.viewerId = '';
      BrainAvatarPrefs.clearLive();
      _themeSyncedFor = null;
      return;
    }
    final accountId = session.session?.accountId ?? '';
    if (BrainAvatarPrefs.viewerId != accountId) {
      BrainAvatarPrefs.viewerId = accountId;
    }
    if (_themeSyncedFor != accountId) {
      _themeSyncedFor = accountId;
      unawaited(_pullActiveTheme());
    }
  }

  Future<void> _pullActiveTheme() async {
    try {
      final active = await widget.dependencies.service.fetchActiveTheme();
      if (!mounted || active == null) return;
      final packs = ThemePackScope.maybeOf(context);
      if (packs == null) return;
      await packs.syncFromServer(
        next: active.pack,
        listing: active.listingId.isEmpty ? null : active.listingId,
        botId: active.themeId,
      );
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.dependencies.sessionController,
      builder: (context, _) {
        if (!widget.dependencies.sessionController.isReady) {
          return const Scaffold(body: SafeArea(child: SkeletonPage()));
        }
        if (!widget.dependencies.sessionController.isLoggedIn) {
          return AuthScreen(dependencies: widget.dependencies);
        }
        return widget.child;
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
  List<String> _ssoProviders = const [];
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
    _loadSso();
  }

  Future<void> _loadSso() async {
    if (returnedFromSso) {
      try {
        await completeSso(widget.dependencies, Uri.base);
        return;
      } catch (e) {
        _snack('Single sign-on failed: $e');
      }
    }
    final providers = await ssoProviders(widget.dependencies);
    if (mounted) setState(() => _ssoProviders = providers);
  }

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _sso() async {
    final email = await _textDialog(
        title: 'Continue with single sign-on', label: 'Work email');
    if (email == null || email.trim().isEmpty || !mounted) return;
    try {
      await signInWithSso(context, widget.dependencies, email.trim());
    } catch (e) {
      _snack('$e');
    }
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
    final value = await showAppDialog<String>(
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
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SkyBackdrop(
        child: SafeArea(
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
                                  fontWeight: FontWeight.w900,
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
                      _panel(context),
                      const SizedBox(height: 12),
                      const MarketingLinkRow(),
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
      ),
    );
  }

  Widget _panel(BuildContext context) {
    return SoftCard(
      radius: AppShape.card,
      elevated: true,
      padding: const EdgeInsets.all(20),
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
        if (_providersLoading ||
            _googleEnabled ||
            _appleEnabled ||
            _ssoProviders.isNotEmpty) ...[
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
            if (_ssoProviders.isNotEmpty) ...[
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                height: 48,
                child: OutlinedButton.icon(
                  onPressed: session.isBusy ? null : _sso,
                  icon: const Icon(Icons.business_rounded),
                  label: Text(_ssoProviders.length == 1
                      ? 'Continue with ${_ssoProviders.first}'
                      : 'Continue with single sign-on'),
                ),
              ),
            ],
          ],
        ],
      ]),
    );
  }
}
