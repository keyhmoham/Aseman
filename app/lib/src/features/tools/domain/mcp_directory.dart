/// Finding MCP servers in the Glama directory and adding them to a space: the
/// parts of that which are decisions, not drawing. Pure, so they are tested.
///
/// The node reads the directory with its own key; people never need a Glama
/// account and nothing they sign in with goes through Glama. Glama's licence
/// asks for a visible credit on every screen that shows its data and a link to
/// each server's listing ([glamaCredit], [GlamaConnector.glamaUrl]).
library;

/// The credit Glama's licence asks every screen showing its data to carry.
const glamaCredit = (text: 'MCP data from Glama', url: 'https://glama.ai');

String _text(Object? v) => v == null ? '' : '$v'.trim();

/// What a server expects of the person: nothing, a key, a login, or a
/// sign-in at its own provider.
String authLabel(String auth) => switch (auth) {
      'oauth2' => 'Sign in',
      'api_key' => 'API key',
      'basic' => 'Login',
      'none' => 'Open',
      _ => '',
    };

/// The same, as a sentence for a server's detail.
String authSentence(String auth) => switch (auth) {
      'oauth2' => 'You sign in with your own account at the app’s own website.',
      'api_key' => 'It needs an API key from the app. You paste it once.',
      'basic' =>
        'It needs a username and password from the app. You enter them once.',
      'none' => 'No sign-in: it works as soon as it is added.',
      _ => '',
    };

/// A server of the directory.
class GlamaConnector {
  const GlamaConnector({
    required this.key,
    required this.name,
    required this.glamaUrl,
    required this.auth,
    required this.toolCount,
    this.description = '',
    this.thumbnail = '',
    this.mcpUrl = '',
    this.quality,
    this.healthy,
    this.boosted = false,
    this.repository = '',
    this.docs = '',
    this.tools = const [],
  });

  /// namespace/slug: what adding it names.
  final String key;
  final String name;
  final String description;

  /// Its page on Glama, linked wherever it is shown.
  final String glamaUrl;
  final String thumbnail;

  /// none, api_key, basic or oauth2.
  final String auth;
  final String mcpUrl;
  final int toolCount;

  /// Glama's 0–5 estimate of how well its tools are described.
  final double? quality;

  /// Its last health check; null when it was never tested.
  final bool? healthy;

  /// A promoted listing: say so.
  final bool boosted;
  final String repository;
  final String docs;

  /// On a server's own page only.
  final List<GlamaTool> tools;

  factory GlamaConnector.fromJson(Map<String, dynamic> j) => GlamaConnector(
        key: _text(j['key']),
        name: _text(j['name']).isEmpty ? _text(j['key']) : _text(j['name']),
        description: _text(j['description']),
        glamaUrl: _text(j['glama_url']),
        thumbnail: _text(j['thumbnail']),
        auth: _text(j['auth']),
        mcpUrl: _text(j['mcp_url']),
        toolCount: (j['tool_count'] as num?)?.toInt() ?? 0,
        quality: (j['quality'] as num?)?.toDouble(),
        healthy: j['healthy'] is bool ? j['healthy'] as bool : null,
        boosted: j['boosted'] == true,
        repository: _text(j['repository']),
        docs: _text(j['docs']),
        tools: [
          for (final t in (j['tools'] as List?) ?? const <dynamic>[])
            if (t is Map) GlamaTool.fromJson(t.cast<String, dynamic>()),
        ],
      );

  /// A row's small print: how many tools, and what it asks.
  String get summary {
    final parts = <String>[
      if (toolCount > 0) '$toolCount tool${toolCount == 1 ? '' : 's'}',
      if (authLabel(auth).isNotEmpty) authLabel(auth),
      if (healthy == false) 'Not answering lately',
    ];
    return parts.join(' · ');
  }

  /// Quality as the directory scores it (0–5), to one decimal; empty when unscored.
  String get qualityLabel {
    final q = quality;
    if (q == null || !q.isFinite || q <= 0) return '';
    return '${q.toStringAsFixed(1)} / 5';
  }
}

class GlamaTool {
  const GlamaTool({required this.name, this.title = '', this.description = ''});
  final String name;
  final String title;
  final String description;

  factory GlamaTool.fromJson(Map<String, dynamic> j) => GlamaTool(
      name: _text(j['name']),
      title: _text(j['title']),
      description: _text(j['description']));

  String get label => title.isNotEmpty ? title : name;
}

/// One page of a directory search.
class GlamaPage {
  const GlamaPage(
      {required this.connectors, this.next = '', this.hasMore = false});
  final List<GlamaConnector> connectors;
  final String next;
  final bool hasMore;

  factory GlamaPage.fromJson(Map<String, dynamic> j) => GlamaPage(
        connectors: [
          for (final c in (j['connectors'] as List?) ?? const <dynamic>[])
            if (c is Map) GlamaConnector.fromJson(c.cast<String, dynamic>()),
        ],
        next: _text(j['next']),
        hasMore: j['has_more'] == true && _text(j['next']).isNotEmpty,
      );
}

/// A way the directory can be narrowed.
class GlamaFilter {
  const GlamaFilter({required this.key, required this.name});
  final String key;
  final String name;
}

/// The filters to offer: "All", then each way the directory sorts servers by
/// sign-in (read from it, never assumed).
List<({String id, String label, List<String> attributes})> authFilters(
    List<GlamaFilter> attributes) {
  String short(GlamaFilter a) {
    final key = a.key.substring('auth:'.length);
    return switch (key) {
      'none' => 'No sign-in',
      'oauth2' => 'Sign in',
      'api_key' => 'API key',
      'basic' => 'Login',
      _ => a.name.isEmpty ? key : a.name,
    };
  }

  return [
    (id: 'all', label: 'All', attributes: const <String>[]),
    for (final a in attributes)
      if (a.key.startsWith('auth:'))
        (id: a.key, label: short(a), attributes: [a.key]),
  ];
}

/// Pages of a search, joined: a server the directory repeats shows once.
List<GlamaConnector> mergePages(Iterable<GlamaPage> pages) {
  final seen = <String>{};
  return [
    for (final p in pages)
      for (final c in p.connectors)
        if (seen.add(c.key)) c,
  ];
}

/// The first few tools of a server, and how many more there are.
({List<GlamaTool> shown, int more}) toolPreview(List<GlamaTool> tools,
    {int limit = 8}) {
  final shown = tools.take(limit).toList();
  return (shown: shown, more: tools.length > limit ? tools.length - limit : 0);
}

/// A search word as sent: trimmed, runs of space made one.
String searchTerm(String raw) => raw.trim().replaceAll(RegExp(r'\s+'), ' ');

/// What adding a server to a space came to.
class McpInstalled {
  const McpInstalled({
    required this.botId,
    required this.name,
    required this.status,
    this.method = '',
    this.credential = '',
    this.auth = '',
    this.tools = 0,
    this.glamaUrl = '',
  });
  final String botId;
  final String name;

  /// ready: nothing to do; connected: already signed in; needs_auth: they must.
  final String status;

  /// needs_auth: at the provider's own page (oauth) or with a key (token).
  final String method;

  /// What the server's key is called (api_key, basic).
  final String credential;
  final String auth;
  final int tools;
  final String glamaUrl;

  factory McpInstalled.fromJson(Map<String, dynamic> j) => McpInstalled(
        botId: _text(j['bot_id']),
        name: _text(j['name']),
        status: _text(j['status']),
        method: _text(j['method']),
        credential: _text(j['credential']),
        auth: _text(j['auth']),
        tools: (j['tools'] as num?)?.toInt() ?? 0,
        glamaUrl: _text(j['glama_url']),
      );

  /// What is left to do for the person.
  McpNextStep get next {
    if (status != 'needs_auth') return const McpNextStep.done();
    if (method == 'oauth') return const McpNextStep.oauth();
    return McpNextStep.token(credential);
  }
}

/// What to do next with a server just added.
class McpNextStep {
  const McpNextStep.done()
      : kind = 'done',
        credential = '';
  const McpNextStep.oauth()
      : kind = 'oauth',
        credential = '';
  const McpNextStep.token(this.credential) : kind = 'token';
  final String kind;
  final String credential;
}

/// What the field for a key is called, for what the directory says the
/// server's key is.
({String title, String label, String hint, bool username, bool header})
    credentialFields(String credential) => switch (credential) {
          'basic' => (
              title: 'Log in',
              label: 'Password',
              hint: 'Its password',
              username: true,
              header: false
            ),
          'api_key' => (
              title: 'Paste its API key',
              label: 'API key',
              hint: 'From the app’s settings',
              username: false,
              header: true
            ),
          _ => (
              title: 'Paste a token',
              label: 'Token',
              hint: 'A token from the app',
              username: false,
              header: false
            ),
        };

/// What the node answered to "connect this person to the server".
class ConnectStart {
  const ConnectStart(this.status,
      {this.authorizationUrl = '',
      this.state = '',
      this.redirectUri = '',
      this.error = '',
      this.credential = ''});

  /// ready, connected, authorize, needs_client or needs_token.
  final String status;
  final String authorizationUrl;
  final String state;
  final String redirectUri;
  final String error;
  final String credential;

  factory ConnectStart.fromJson(Map<String, dynamic> j) => ConnectStart(
        _text(j['status']),
        authorizationUrl: _text(j['authorization_url']),
        state: _text(j['state']),
        redirectUri: _text(j['redirect_uri']),
        error: _text(j['error']),
        credential: _text(j['credential']),
      );
}

// ── the login card ──────────────────────────────────────────────────────────

/// What a login card shows: the card asks the node whether the person is
/// signed in and says so, whenever and wherever it is read.
enum LoginCardState { loading, needs, connected, open, unknown }

LoginCardState loginCardState(
    {required bool loading,
    required bool failed,
    String? auth,
    bool? connected}) {
  if (loading) return LoginCardState.loading;
  // The node could not say (the app is gone, or the call failed): the person
  // may still try to sign in.
  if (failed || auth == null) return LoginCardState.unknown;
  if (auth != 'user') return LoginCardState.open;
  return connected == true ? LoginCardState.connected : LoginCardState.needs;
}

/// The props of a Connect surface or a connect card, read defensively: a card
/// is data from the node. Null when it lacks an app or a place to sign in from.
class LoginCard {
  const LoginCard({
    required this.bot,
    required this.space,
    required this.name,
    this.reason = '',
    this.glamaUrl = '',
    this.credential = '',
  });
  final String bot;
  final String space;
  final String name;
  final String reason;
  final String glamaUrl;
  final String credential;

  static LoginCard? fromProps(Map<String, dynamic> raw) {
    final bot = _text(raw['bot'] ?? raw['id']);
    final space = _text(raw['space']);
    if (bot.isEmpty || space.isEmpty) return null;
    final link = _text(raw['glama_url'] ?? raw['link']);
    final name = _text(raw['name'] ?? raw['title']);
    return LoginCard(
      bot: bot,
      space: space,
      name: name.isEmpty ? 'this app' : name,
      reason: _text(raw['reason'] ?? raw['subtitle']),
      // Only Glama's own addresses are linked.
      glamaUrl: link.startsWith('https://glama.ai/') ? link : '',
      credential: _text(raw['credential']),
    );
  }
}

/// The login cards among the cards under a personal-chat answer (`connect`
/// cards of the node's `proposal.cards`): an app the person needs to sign in
/// to. Anything else, or a card that cannot work, is left out.
List<LoginCard> loginCardsOf(Object? cards) {
  if (cards is! List) return const [];
  final out = <LoginCard>[];
  for (final c in cards) {
    if (c is! Map || c['type'] != 'connect') continue;
    final card = LoginCard.fromProps(c.cast<String, dynamic>());
    if (card != null) out.add(card);
  }
  return out;
}
