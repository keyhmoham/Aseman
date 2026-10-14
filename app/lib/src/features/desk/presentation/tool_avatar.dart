import 'package:flutter/material.dart';

/// A tool's mark: an icon that fits its name, on a tonal container whose hue
/// is the tool's own (the same everywhere: window, dock, pinned desk).
class ToolAvatar extends StatelessWidget {
  const ToolAvatar({
    super.key,
    required this.tool,
    required this.name,
    this.size = 36,
    this.selected = false,
  });

  final String tool;
  final String name;
  final double size;

  /// Filled with the tool's strong color, the shape squarer (M3 expressive
  /// selection: color and shape change together).
  final bool selected;

  static const List<Color> _seeds = [
    Color(0xFF2A78D6), Color(0xFFEB6834), Color(0xFF1BAF7A), //
    Color(0xFFB8860B), Color(0xFFD55181), Color(0xFF2E7D32),
    Color(0xFF6250D6), Color(0xFFE34948), Color(0xFF00838F),
  ];

  static final Map<(int, Brightness), ColorScheme> _schemes = {};

  /// The tool's tonal palette.
  static ColorScheme schemeFor(String tool, Brightness brightness) {
    final seed =
        tool.codeUnits.fold<int>(7, (a, b) => (a * 31 + b) & 0x7fffffff) %
            _seeds.length;
    return _schemes.putIfAbsent(
        (seed, brightness),
        () => ColorScheme.fromSeed(
            seedColor: _seeds[seed], brightness: brightness));
  }

  static IconData iconFor(String name) {
    final n = name.toLowerCase();
    bool has(List<String> words) => words.any(n.contains);
    // Agents' composed widgets share one dock entry.
    if (n == 'widgets') return Icons.dashboard_customize_rounded;
    if (has(['weather', 'forecast', 'climate'])) return Icons.wb_sunny_rounded;
    if (has(
        ['market', 'stock', 'price', 'crypto', 'trade', 'ticker', 'quote'])) {
      return Icons.candlestick_chart_rounded;
    }
    if (has(['portfolio', 'wallet', 'bank', 'finance'])) {
      return Icons.account_balance_wallet_rounded;
    }
    if (has(['chart', 'analytic', 'stats', 'metric', 'dashboard'])) {
      return Icons.insights_rounded;
    }
    if (has(['news', 'feed', 'rss'])) return Icons.newspaper_rounded;
    if (has(['map', 'geo', 'place', 'location'])) return Icons.map_rounded;
    if (has(['calendar', 'event', 'schedule'])) return Icons.event_rounded;
    if (has(['mail', 'email', 'inbox'])) return Icons.mail_rounded;
    if (has(['git', 'code', 'repo', 'wiki', 'dev'])) return Icons.code_rounded;
    if (has(['search', 'find'])) return Icons.travel_explore_rounded;
    if (has(['note', 'doc', 'file', 'drive'])) return Icons.description_rounded;
    if (has(['music', 'audio', 'sound'])) return Icons.music_note_rounded;
    if (has(['image', 'photo', 'video'])) return Icons.photo_library_rounded;
    if (has(['chat', 'message', 'slack'])) return Icons.forum_rounded;
    if (has(['sandbox', 'terminal', 'shell'])) return Icons.terminal_rounded;
    if (has(['translate', 'language'])) return Icons.translate_rounded;
    return Icons.widgets_rounded;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = schemeFor(tool, Theme.of(context).brightness);
    return AnimatedContainer(
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutBack,
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: selected ? scheme.primary : scheme.primaryContainer,
        borderRadius: BorderRadius.circular(selected ? size * .32 : size / 2),
      ),
      child: Icon(iconFor(name),
          size: size * .54,
          color: selected ? scheme.onPrimary : scheme.onPrimaryContainer),
    );
  }
}
