import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';

/// Owns the native/provider SDK sessions and emits identity tokens that the
/// Tradera backend exchanges for a platform session.
class FederatedSignIn {
  FederatedSignIn._();

  static final FederatedSignIn instance = FederatedSignIn._();

  final _googleTokens = StreamController<String>.broadcast();
  final _googleErrors = StreamController<Object>.broadcast();
  bool _googleInitialized = false;
  Future<void>? _googleInitialization;

  Stream<String> get googleTokens => _googleTokens.stream;
  Stream<Object> get googleErrors => _googleErrors.stream;
  bool get googleReady => _googleInitialized;

  Future<void> initializeGoogle(String clientId) {
    if (_googleInitialized) return Future.value();
    return _googleInitialization ??= _initializeGoogle(clientId);
  }

  Future<void> _initializeGoogle(String clientId) async {
    final google = GoogleSignIn.instance;
    google.authenticationEvents.listen((event) {
      if (event is GoogleSignInAuthenticationEventSignIn) {
        final token = event.user.authentication.idToken;
        if (token != null && token.isNotEmpty) _googleTokens.add(token);
      }
    }, onError: (Object error) => _googleErrors.add(error));

    const iosClientId = String.fromEnvironment('GOOGLE_IOS_CLIENT_ID');
    await google.initialize(
      clientId: kIsWeb
          ? clientId
          : defaultTargetPlatform == TargetPlatform.iOS ||
                  defaultTargetPlatform == TargetPlatform.macOS
              ? (iosClientId.isEmpty ? clientId : iosClientId)
              : null,
      serverClientId: clientId,
    );
    _googleInitialized = true;
  }

  Future<void> authenticateGoogle() async {
    final google = GoogleSignIn.instance;
    if (!_googleInitialized) {
      throw StateError('Google Sign-In is not configured');
    }
    if (!google.supportsAuthenticate()) {
      throw UnsupportedError(
          'Use the Google-provided sign-in button on this platform');
    }
    await google.authenticate();
  }

  bool get applePlatform =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.macOS);

  Future<bool> appleAvailable() async =>
      applePlatform && await SignInWithApple.isAvailable();

  Future<String> authenticateApple() async {
    if (!await appleAvailable()) {
      throw UnsupportedError('Sign in with Apple is unavailable');
    }
    final credential = await SignInWithApple.getAppleIDCredential(
      scopes: const [
        AppleIDAuthorizationScopes.email,
        AppleIDAuthorizationScopes.fullName,
      ],
    );
    final token = credential.identityToken;
    if (token == null || token.isEmpty) {
      throw StateError('Apple did not return an identity token');
    }
    return token;
  }

  Future<void> signOutGoogle() async {
    if (_googleInitialized) await GoogleSignIn.instance.signOut();
  }
}
