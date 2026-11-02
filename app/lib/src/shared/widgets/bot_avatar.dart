import 'package:flutter/material.dart';

import '../../core/theme/halo_ring_cache.dart';
import '../../data/models/bot.dart';
import '../../features/brain/brain_avatar.dart';
import 'avatar.dart';
import 'sky_ui.dart';

/// Unified bot mark used across the app.
///
/// Agents: soft 3D [AgentHumanoidAvatar] with the creator picture as a
/// bottom-right badge when present. Apps/tools: [AvatarPicture] of their
/// uploaded avatar, with a rounded icon fallback.
class BotAvatar extends StatelessWidget {
  const BotAvatar({
    super.key,
    required this.bot,
    this.radius = 20,
    this.userId = '',
    this.listening = false,
  });

  final Bot bot;
  final double radius;
  final String userId;
  final bool listening;

  /// Convenience when only ids / avatar / kind are known (search hits, etc.).
  factory BotAvatar.fromFields({
    Key? key,
    required String id,
    String accountId = '',
    required String name,
    String kind = 'agent',
    String avatar = '',
    String userId = '',
    double radius = 20,
  }) =>
      BotAvatar(
        key: key,
        bot: Bot(
          id: id,
          ownerId: '',
          accountId: accountId,
          name: name,
          kind: kind,
          vmType: '',
          status: '',
          avatar: avatar,
        ),
        userId: userId,
        radius: radius,
      );

  @override
  Widget build(BuildContext context) {
    final size = radius * 2;
    final scheme = Theme.of(context).colorScheme;
    final Widget mark;
    if (bot.isAgent) {
      mark = AgentHumanoidAvatar(
        agentId: bot.id.isNotEmpty ? bot.id : bot.accountId,
        picture: bot.avatar,
        userId: BrainAvatarPrefs.resolveUserId(userId),
        platform: bot.humanoid,
        radius: radius,
        listening: listening,
      );
    } else {
      final corner = radius * .55;
      final picture = Avatars.of(bot.avatar);
      mark = Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: scheme.primary.withValues(alpha: .14),
          borderRadius: BorderRadius.circular(corner),
          image: picture == null
              ? null
              : DecorationImage(
                  image: picture,
                  fit: BoxFit.cover,
                  onError: (_, __) {},
                ),
        ),
        child: picture != null
            ? null
            : Icon(
                Icons.extension_rounded,
                size: radius * .95,
                color: scheme.primary,
              ),
      );
    }
    final id = bot.id.isNotEmpty ? bot.id : bot.accountId;
    return HaloRing(
      identity: HaloRingCache.agent(id),
      accent: bot.isAgent ? scheme.tertiary : scheme.primary,
      child: mark,
    );
  }
}
