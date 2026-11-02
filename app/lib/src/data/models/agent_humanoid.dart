/// Platform default humanoid look for an agent (skin / hair / optional accent).
/// Stored on the bot's public profile at create time; each person may override
/// it locally for themselves via [BrainAvatarPrefs].
class AgentHumanoid {
  const AgentHumanoid({
    this.skin = 2,
    this.hair = 1,
    this.accentArgb,
  });

  /// Index into the client skin palette (0..5).
  final int skin;

  /// Index into the client hair styles (0..4).
  final int hair;

  /// Optional ARGB accent; null means "use the app accent".
  final int? accentArgb;

  static const skinCount = 6;
  static const hairCount = 5;

  static AgentHumanoid? tryParse(dynamic raw) {
    if (raw is! Map) return null;
    final map = raw is Map<String, dynamic>
        ? raw
        : Map<String, dynamic>.from(raw);
    final skin = (map['skin'] as num?)?.toInt();
    final hair = (map['hair'] as num?)?.toInt();
    if (skin == null && hair == null && map['accent'] == null) return null;
    final accent = (map['accent'] as num?)?.toInt();
    return AgentHumanoid(
      skin: (skin ?? 2).clamp(0, skinCount - 1),
      hair: (hair ?? 1).clamp(0, hairCount - 1),
      accentArgb: accent,
    );
  }

  /// Stable "random" look derived from [agentId] for agents created before
  /// the platform stored a humanoid, or when the payload omits one.
  factory AgentHumanoid.seedFrom(String agentId) {
    var h = 0;
    for (final c in agentId.codeUnits) {
      h = 0x1fffffff & (h * 31 + c);
    }
    return AgentHumanoid(
      skin: h % skinCount,
      hair: (h ~/ skinCount) % hairCount,
    );
  }

  Map<String, dynamic> toJson() => {
        'skin': skin,
        'hair': hair,
        if (accentArgb != null) 'accent': accentArgb,
      };
}
