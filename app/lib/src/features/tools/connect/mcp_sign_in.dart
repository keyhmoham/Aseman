import 'package:flutter/widgets.dart';

import '../../../data/services/aseman_service.dart';
import 'oauth_window.dart';

/// Overrides where providers send people back after signing in
/// (`--dart-define=OAUTH_REDIRECT_URI=https://app.example.com/oauth.html`),
/// e.g. to match the one redirect an OAuth client was created with.
const String kOAuthRedirectUri = String.fromEnvironment('OAUTH_REDIRECT_URI');

/// The provider wants an OAuth client someone creates (it will not register
/// Aseman by itself): the person supplies its id, or a token.
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

/// Signing a person in to an MCP tool that each person connects with their
/// own account, and storing the connection for a project. Discovery, client
/// registration and the token exchange run on the node (a page cannot reach
/// most servers' sign-in documents); the app only shows the provider's page
/// and brings the code back. The connection is made from the sign-in itself,
/// so the node can renew it without the person.
class McpSignIn {
  McpSignIn(this.service);
  final AsemanService service;

  String get redirectUri => kOAuthRedirectUri.isNotEmpty
      ? kOAuthRedirectUri
      : oauthRedirectUri(service.client.baseUrl);

  /// Signs in to the tool [botId] and connects it in [spaceId]. With
  /// [clientId], that OAuth client is used instead of the one saved for the
  /// tool or registered on the fly. [open] shows the provider's page; by
  /// default it is the platform's sign-in window, opened right away so a
  /// browser keeps it as part of the tap.
  Future<void> connect(BuildContext context,
      {required String botId,
      required String spaceId,
      String clientId = '',
      String clientSecret = '',
      OAuthOpener? open}) async {
    OAuthWindow? window;
    if (open == null) {
      window = OAuthWindow.open();
      open = (url, redirect, state) =>
          window!.signIn(context, url, redirectUri: redirect, state: state);
    }
    try {
      final redirect = redirectUri;
      final prepared = await service.mcpOAuthPrepare(
          bot: botId,
          redirectUri: redirect,
          clientId: clientId,
          clientSecret: clientSecret);
      if (prepared['needs_client'] == true) {
        throw McpNeedsClient(
            '${prepared['error'] ?? 'This provider needs an OAuth client you create.'}',
            '${prepared['redirect_uri'] ?? redirect}');
      }
      final url = '${prepared['authorization_url'] ?? ''}';
      final state = '${prepared['state'] ?? ''}';
      if (url.isEmpty || state.isEmpty) {
        throw StateError('That app did not offer a sign-in page.');
      }
      final returned = Uri.parse(await open(url, redirect, state));
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
      if (back.isNotEmpty && back != state) {
        throw StateError('Sign-in came back for a different attempt.');
      }
      final tokens = await service.mcpOAuthExchange(state, code);
      if ('${tokens['access_token'] ?? ''}'.isEmpty) {
        throw StateError('The provider did not return an access token.');
      }
      await service.setToolConnection(botId, spaceId, grant: state);
    } catch (_) {
      window?.close();
      rethrow;
    }
  }

  /// Connects [botId] in [spaceId] with a token the person pasted (it cannot
  /// renew itself).
  Future<void> connectWithToken(
          String botId, String spaceId, String token) =>
      service.setToolConnection(botId, spaceId, token: token.trim());
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
