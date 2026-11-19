import 'package:flutter/widgets.dart';

import '../../../data/services/aseman_service.dart';
import 'oauth_window.dart';

/// Overrides where providers send people back after signing in
/// (`--dart-define=OAUTH_REDIRECT_URI=https://app.example.com/oauth.html`),
/// e.g. to match the one redirect an OAuth client was created with.
const String kOAuthRedirectUri = String.fromEnvironment('OAUTH_REDIRECT_URI');

/// The provider wants an OAuth client someone creates (it will not register
/// Aseman by itself): the person supplies its id.
class McpNeedsClient implements Exception {
  McpNeedsClient(this.message, this.redirectUri);
  final String message;

  /// The redirect address to create the client with.
  final String redirectUri;
  @override
  String toString() => message;
}

/// Opens [authorizationUrl] and returns the address the provider sent the
/// person back to. [McpSignIn] uses the platform's window; tests replace it.
typedef OAuthOpener = Future<String> Function(
    String authorizationUrl, String redirectUri, String state);

/// What connecting a person to a server came to.
class McpConnectOutcome {
  const McpConnectOutcome(this.status, {this.credential = ''});

  /// connected (signed in, or already was), ready (the server needs no one
  /// to sign in) or needs_token (it has no sign-in page: the person pastes its key).
  final String status;

  /// What the server's key is called, when it wants one.
  final String credential;

  bool get needsToken => status == 'needs_token';
  bool get connected => status == 'connected' || status == 'ready';
}

/// Signing a person in to an MCP server that each person connects with their
/// own account. The node does everything but the one step that needs a
/// browser: it finds the provider the server names, gets a client there,
/// builds the sign-in address (OAuth 2.1 with PKCE) and, when the person comes
/// back with a code, trades it for tokens and keeps them, sealed, as theirs.
/// The app only shows the provider's page and brings the code back: no token
/// ever reaches it. One sign-in serves every space the server is added to.
class McpSignIn {
  McpSignIn(this.service);
  final AsemanService service;

  String get redirectUri => kOAuthRedirectUri.isNotEmpty
      ? kOAuthRedirectUri
      : oauthRedirectUri(service.client.baseUrl);

  /// A server whose sign-in failed is signed in to afresh next time: the
  /// provider may no longer know the client the node kept.
  static final _failed = <String>{};

  /// Signs in to the tool [botId] from [spaceId]. With [clientId], that OAuth
  /// client is used instead of the one saved for the tool or registered on
  /// the fly. [open] shows the provider's page; by default it is the
  /// platform's sign-in window, opened right away so a browser keeps it as
  /// part of the tap. Throws [McpNeedsClient] for a provider that registers
  /// no clients.
  Future<McpConnectOutcome> connect(BuildContext context,
      {required String botId,
      required String spaceId,
      String clientId = '',
      String clientSecret = '',
      bool reconnect = false,
      OAuthOpener? open,
      OAuthWindow? window}) async {
    if (open == null) {
      window ??= OAuthWindow.open();
      final w = window;
      open = (url, redirect, state) =>
          w.signIn(context, url, redirectUri: redirect, state: state);
    }
    try {
      final redirect = redirectUri;
      final start = await service.mcpConnectStart(
          botId: botId,
          spaceId: spaceId,
          redirectUri: redirect,
          clientId: clientId,
          clientSecret: clientSecret,
          reconnect: reconnect,
          freshClient: _failed.contains(botId));
      switch (start.status) {
        case 'ready':
        case 'connected':
          window?.close();
          return McpConnectOutcome(start.status);
        case 'needs_token':
          window?.close();
          return McpConnectOutcome('needs_token',
              credential: start.credential);
        case 'needs_client':
          throw McpNeedsClient(
              start.error.isEmpty
                  ? 'This provider needs an OAuth client you create.'
                  : start.error,
              start.redirectUri.isEmpty ? redirect : start.redirectUri);
        case 'authorize':
          break;
        default:
          throw StateError('That app did not offer a sign-in page.');
      }
      final returned =
          Uri.parse(await open(start.authorizationUrl, redirect, start.state));
      final params = {
        ...Uri.splitQueryString(returned.fragment),
        ...returned.queryParameters,
      };
      final error = params['error_description'] ?? params['error'];
      if (error != null && error.isNotEmpty) throw StateError(error);
      final code = params['code'] ?? '';
      if (code.isEmpty) {
        throw StateError('The provider did not return an authorization code.');
      }
      final back = params['state'] ?? '';
      if (back.isNotEmpty && back != start.state) {
        throw StateError('Sign-in came back for a different attempt.');
      }
      await service.mcpConnectFinish(start.state, code);
      _failed.remove(botId);
      return const McpConnectOutcome('connected');
    } catch (e) {
      window?.close();
      if (e is! McpNeedsClient) _failed.add(botId);
      rethrow;
    }
  }

  /// Connects [botId] with a key the person holds. The node checks it with
  /// the server before keeping it.
  Future<void> connectWithToken(String botId, String spaceId, String token,
          {String username = '', String header = ''}) =>
      service.mcpConnectToken(botId, spaceId, token.trim(),
          username: username.trim(), header: header.trim());
}

/// A sign-in failure in words a person can act on, with addresses reduced to
/// their host.
String mcpSignInMessage(Object error) {
  var text = '$error'
      .replaceFirst(RegExp(r'^(Bad state|Exception|StateError):\s*'), '')
      .replaceAllMapped(RegExp(r'https?://[^\s)]+'), (m) {
        final host = Uri.tryParse(m[0]!)?.host ?? '';
        return host.isEmpty ? 'the provider' : host;
      })
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (text.isEmpty) return 'Could not complete sign-in with that app.';
  if (text.length > 180) text = '${text.substring(0, 177)}…';
  return text;
}
