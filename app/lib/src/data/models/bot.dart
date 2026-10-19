/// A bot VM (an agent, or an app) as returned by the bots namespace.
class Bot {
  const Bot({
    required this.id,
    required this.ownerId,
    required this.accountId,
    required this.name,
    this.kind = 'agent',
    required this.vmType,
    required this.status,
    this.imageRef = '',
    this.hasFrontend = false,
  });

  final String id;
  final String ownerId;
  final String accountId;
  final String name;
  final String kind; // agent | tool (an app)
  final String vmType; // langchain | wasm | docker | container | modal
  final String status; // pending | running | stopped | paused | failed
  final String imageRef;
  final bool hasFrontend;

  bool get isAgent => kind == 'agent';
  bool get isTool => kind == 'tool';

  /// A tool whose backend serves microtools over MCP — an external server, a
  /// backend this node runs (Elpian VM, QuickJS or docker) or one installed
  /// into each space's sandbox. It is used through its frontend
  /// (features/tools).
  bool get isUnifiedTool =>
      isTool &&
      !name.startsWith('sbx-') &&
      const {'mcp', 'elpian', 'quickjs', 'installed', 'docker'}
          .contains(vmType);

  /// Where a tool's backend runs, for display: External, Managed (with its
  /// runtime) or Installed.
  String get toolModeLabel => switch (vmType) {
        'mcp' => 'External',
        'installed' => 'Installed',
        'elpian' => 'Managed · Elpian VM',
        'quickjs' => 'Managed · QuickJS',
        'docker' => 'Managed · Docker',
        _ => 'App',
      };

  /// What it is, for display: an agent or an app.
  String get kindLabel => isAgent ? 'Agent' : 'App';

  factory Bot.fromJson(Map<String, dynamic> json) => Bot(
        id: json['id'] as String? ?? '',
        ownerId: json['owner_id'] as String? ?? '',
        accountId: json['account_id'] as String? ?? '',
        name: json['name'] as String? ?? '',
        kind: json['kind'] as String? ?? 'agent',
        vmType: json['vm_type'] as String? ?? 'docker',
        status: json['status'] as String? ?? 'pending',
        imageRef: json['image_ref'] as String? ?? '',
        hasFrontend: json['has_frontend'] as bool? ?? false,
      );
}

/// A marketplace listing, optionally joined with its bot.
class MarketListing {
  const MarketListing({
    required this.id,
    required this.publisherId,
    required this.botId,
    required this.type,
    required this.name,
    this.description = '',
    this.price = 0,
    this.category = '',
    this.installs = 0,
    this.status = 'active',
    this.bot,
  });

  final String id;
  final String publisherId;
  final String botId;
  final String type; // agent | tool (an app)
  final String name;
  final String description;
  final int price;
  final String category;
  final int installs;
  final String status;
  final Bot? bot;

  bool get isApp => type == 'tool';

  /// What it lists, for display: an agent or an app.
  String get kindLabel => isAgent ? 'Agent' : 'App';
  bool get isAgent => type == 'agent';

  factory MarketListing.fromJson(Map<String, dynamic> json) {
    final botJson = json['bot'];
    return MarketListing(
      id: json['id'] as String? ?? '',
      publisherId: json['publisher_id'] as String? ?? '',
      botId: json['bot_id'] as String? ?? '',
      type: json['type'] as String? ?? 'agent',
      name: json['name'] as String? ?? '',
      description: json['description'] as String? ?? '',
      price: (json['price'] as num?)?.toInt() ?? 0,
      category: json['category'] as String? ?? '',
      installs: (json['installs'] as num?)?.toInt() ?? 0,
      status: json['status'] as String? ?? 'active',
      bot: botJson is Map<String, dynamic> ? Bot.fromJson(botJson) : null,
    );
  }
}

/// A wallet as returned by the finance namespace.
class Wallet {
  const Wallet({required this.balance, required this.locked});

  final int balance;
  final int locked;

  int get available => balance - locked;

  factory Wallet.fromJson(Map<String, dynamic> json) => Wallet(
        balance: (json['balance'] as num?)?.toInt() ?? 0,
        locked: (json['locked'] as num?)?.toInt() ?? 0,
      );
}

/// A user account summary.
class AccountSummary {
  const AccountSummary({
    required this.id,
    required this.handle,
    this.kind = 'user',
    this.status = 'active',
  });

  final String id;
  final String handle;
  final String kind;
  final String status;

  factory AccountSummary.fromJson(Map<String, dynamic> json) => AccountSummary(
        id: json['id'] as String? ?? '',
        handle: json['handle'] as String? ?? '',
        kind: json['kind'] as String? ?? 'user',
        status: json['status'] as String? ?? 'active',
      );
}
