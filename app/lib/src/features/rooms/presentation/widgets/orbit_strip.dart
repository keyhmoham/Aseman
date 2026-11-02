import 'package:flutter/material.dart';

import '../../../../core/theme/halo_ring_cache.dart';
import '../../../../data/models/bot.dart';
import '../../../../shared/widgets/avatar.dart';
import '../../../../shared/widgets/bot_avatar.dart';
import '../../../../shared/widgets/sky_ui.dart';

/// Compact Orbit-style row of agents, people and tools already loaded for a
/// workspace — avatars in a short overlapping strip.
class OrbitStrip extends StatelessWidget {
  const OrbitStrip({
    super.key,
    this.agents = const [],
    this.people = const [],
    this.tools = const [],
    this.userId = '',
    this.maxVisible = 8,
    this.size = 28,
  });

  final List<Bot> agents;
  final List<({String id, String name, String avatar})> people;
  final List<Bot> tools;
  final String userId;
  final int maxVisible;
  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final items = <_OrbitItem>[
      for (final a in agents)
        _OrbitItem.bot(a, kind: _Kind.agent),
      for (final p in people)
        _OrbitItem(
          keyId: 'p:${p.id}',
          label: p.name,
          avatar: p.avatar,
          kind: _Kind.person,
        ),
      for (final t in tools)
        _OrbitItem.bot(t, kind: _Kind.tool),
    ];
    if (items.isEmpty) return const SizedBox.shrink();
    final shown = items.take(maxVisible).toList();
    final extra = items.length - shown.length;
    return SizedBox(
      height: size + 4,
      child: Row(
        children: [
          for (var i = 0; i < shown.length; i++)
            Transform.translate(
              offset: Offset(i == 0 ? 0 : -size * .28 * i, 0),
              child: Tooltip(
                message: shown[i].label,
                child: _OrbitAvatar(
                  item: shown[i],
                  size: size,
                  scheme: scheme,
                  userId: userId,
                ),
              ),
            ),
          if (extra > 0)
            Padding(
              padding: EdgeInsets.only(left: shown.isEmpty ? 0 : 4),
              child: Text('+$extra',
                  style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: scheme.onSurfaceVariant)),
            ),
        ],
      ),
    );
  }
}

enum _Kind { agent, person, tool }

class _OrbitItem {
  const _OrbitItem({
    required this.keyId,
    required this.label,
    required this.avatar,
    required this.kind,
    this.bot,
  });

  factory _OrbitItem.bot(Bot bot, {required _Kind kind}) => _OrbitItem(
        keyId: '${kind.name}:${bot.id}',
        label: bot.name,
        avatar: bot.avatar,
        kind: kind,
        bot: bot,
      );

  final String keyId;
  final String label;
  final String avatar;
  final _Kind kind;
  final Bot? bot;
}

class _OrbitAvatar extends StatelessWidget {
  const _OrbitAvatar({
    required this.item,
    required this.size,
    required this.scheme,
    this.userId = '',
  });
  final _OrbitItem item;
  final double size;
  final ColorScheme scheme;
  final String userId;

  @override
  Widget build(BuildContext context) => _mark();

  Widget _mark() {
    final bot = item.bot;
    // Face diameter stays [size]; HaloRing (inside BotAvatar / here) sits outside.
    final face = size / 2;
    if (bot != null) {
      return BotAvatar(bot: bot, radius: face, userId: userId);
    }
    final picture = Avatars.of(item.avatar);
    final initial = item.label.trim().isEmpty
        ? '?'
        : item.label.trim().characters.first.toUpperCase();
    final personId =
        item.keyId.startsWith('p:') ? item.keyId.substring(2) : item.keyId;
    return HaloRing(
      identity: HaloRingCache.person(personId),
      accent: scheme.secondary,
      child: CircleAvatar(
        radius: face,
        foregroundImage: picture,
        onForegroundImageError: picture == null ? null : (_, __) {},
        backgroundColor: scheme.secondaryContainer,
        foregroundColor: scheme.onSecondaryContainer,
        child: picture != null
            ? null
            : Text(initial,
                style: TextStyle(
                    fontSize: size * .4, fontWeight: FontWeight.w800)),
      ),
    );
  }
}
