/// An LLM model offered by a provider, with its token prices in credits per
/// one million tokens.
class LlmModel {
  const LlmModel({
    required this.id,
    this.name = '',
    this.inputPrice = 0,
    this.outputPrice = 0,
    this.capabilities = const [],
    this.extra = const {},
  });

  final String id;
  final String name;
  final double inputPrice;
  final double outputPrice;
  final List<String> capabilities;

  /// Everything else the node stores with the model (unit prices, where it
  /// was imported from and at what markup, whether it is disabled, …). It is
  /// sent back unchanged, so saving a provider never drops it.
  final Map<String, dynamic> extra;

  String get label => name.isNotEmpty ? name : id;

  /// Whether the admin turned the model off for new agents.
  bool get disabled => extra['disabled'] == true;

  static const _fields = {
    'id',
    'name',
    'input_price',
    'output_price',
    'capabilities'
  };

  factory LlmModel.fromJson(Map<String, dynamic> j) => LlmModel(
        id: j['id'] as String? ?? '',
        name: j['name'] as String? ?? '',
        inputPrice: (j['input_price'] as num?)?.toDouble() ?? 0,
        outputPrice: (j['output_price'] as num?)?.toDouble() ?? 0,
        capabilities: [
          for (final value in (j['capabilities'] as List? ?? const []))
            '$value',
        ],
        extra: {
          for (final e in j.entries)
            if (!_fields.contains(e.key)) e.key: e.value,
        },
      );

  Map<String, dynamic> toJson() => {
        ...extra,
        'id': id,
        if (name.isNotEmpty) 'name': name,
        'input_price': inputPrice,
        'output_price': outputPrice,
        if (capabilities.isNotEmpty) 'capabilities': capabilities,
      };
}

/// An LLM provider configured by the node admin. In the agent catalog the
/// credentials fields are absent; in the admin panel the key is masked.
class LlmProvider {
  const LlmProvider({
    required this.id,
    required this.name,
    required this.kind,
    this.baseUrl = '',
    this.enabled = true,
    this.isDefault = false,
    this.models = const [],
    this.imageModel = '',
    this.imagePrice = 0,
    this.hasKey = false,
    this.keyPreview = '',
    this.hasImages = false,
  });

  final String id;
  final String name;
  final String kind;
  final String baseUrl;
  final bool enabled;
  final bool isDefault;
  final List<LlmModel> models;
  final String imageModel;
  final double imagePrice;
  final bool hasKey;
  final String keyPreview;
  final bool hasImages;

  factory LlmProvider.fromJson(Map<String, dynamic> j) => LlmProvider(
        id: j['id'] as String? ?? '',
        name: j['name'] as String? ?? '',
        kind: j['kind'] as String? ?? '',
        baseUrl: j['base_url'] as String? ?? '',
        enabled: j['enabled'] as bool? ?? true,
        isDefault: j['is_default'] as bool? ?? false,
        models: [
          for (final m in (j['models'] as List? ?? const []))
            if (m is Map) LlmModel.fromJson(m.cast<String, dynamic>()),
        ],
        imageModel: j['image_model'] as String? ?? '',
        imagePrice: (j['image_price'] as num?)?.toDouble() ?? 0,
        hasKey: j['has_key'] as bool? ?? false,
        keyPreview: j['key_preview'] as String? ?? '',
        hasImages: j['has_images'] as bool? ??
            ((j['image_model'] as String? ?? '').isNotEmpty),
      );
}

/// A supported provider kind and its default OpenAI-compatible endpoint.
class LlmKind {
  const LlmKind({required this.kind, required this.name, this.baseUrl = ''});
  final String kind;
  final String name;
  final String baseUrl;

  factory LlmKind.fromJson(Map<String, dynamic> j) => LlmKind(
        kind: j['kind'] as String? ?? '',
        name: j['name'] as String? ?? '',
        baseUrl: j['base_url'] as String? ?? '',
      );
}

/// Formats a credit price compactly (e.g. 1000, 2.5).
String formatCredits(double v) => (v / 10000) == (v / 10000).roundToDouble()
    ? (v / 10000).toStringAsFixed(0)
    : (v / 10000).toStringAsFixed(4).replaceFirst(RegExp(r'0+$'), '');
