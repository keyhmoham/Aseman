import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/layout/breakpoints.dart';
import '../../core/settings/app_settings.dart';
import '../../core/theme/theme_chrome.dart';
import '../../core/theme/theme_roles.dart';
import '../../data/models/agent_humanoid.dart';
import '../../shared/widgets/avatar.dart';
import '../../shared/widgets/avatar_face.dart';
import '../../shared/widgets/overlay_panels.dart';

/// Persisted look of an AI agent avatar (Aseman or any other agent DM).
///
/// Platform default comes from the agent's profile ([platform]). A person's
/// customization is stored on this device under their account id and is shown
/// only to them.
class BrainAvatarPrefs {
  const BrainAvatarPrefs({
    this.skin = 2,
    this.hair = 1,
    this.accentArgb,
    this.agentId = '',
    this.userId = '',
  });

  static const skinKey = 'aseman.brain.avatar.skin';
  static const hairKey = 'aseman.brain.avatar.hair';
  static const accentKey = 'aseman.brain.avatar.accent';

  /// Bumped on every [save] so every mounted [AgentHumanoidAvatar] reloads.
  static final ValueNotifier<int> revision = ValueNotifier(0);

  /// In-memory snapshot after the latest save, keyed by agentId + userId.
  /// Lets open avatars update synchronously without waiting on prefs I/O.
  static final Map<String, BrainAvatarPrefs> _live = {};

  /// Signed-in account used when a widget omits [userId].
  /// Bound from [AuthGate] so personalization resolves app-wide.
  static String viewerId = '';

  /// Index into [skinTones].
  final int skin;

  /// Index into [hairStyles].
  final int hair;

  /// Optional override; null means use the app accent.
  final int? accentArgb;

  /// Empty for personal Aseman; otherwise the agent account/bot id.
  final String agentId;

  /// The person this personalization belongs to (empty = legacy device key).
  final String userId;

  static String _liveKey(String agentId, String userId) =>
      '$agentId\u001f$userId';

  /// Account to key personalization by: explicit [userId], else [viewerId].
  static String resolveUserId(String userId) =>
      userId.isNotEmpty ? userId : viewerId;

  /// Latest saved look for [agentId]/[userId], if any in this session.
  static BrainAvatarPrefs? liveFor(String agentId, String userId) =>
      _live[_liveKey(agentId, userId)];

  /// Clears in-memory snapshots (tests / logout).
  static void clearLive() {
    if (_live.isEmpty) return;
    _live.clear();
    revision.value++;
  }

  static String _skinKeyFor(String agentId, String userId) {
    if (agentId.isEmpty) {
      return userId.isEmpty
          ? skinKey
          : 'aseman.brain.by.$userId.avatar.skin';
    }
    return userId.isEmpty
        ? 'aseman.agent.$agentId.avatar.skin'
        : 'aseman.agent.$agentId.by.$userId.avatar.skin';
  }

  static String _hairKeyFor(String agentId, String userId) {
    if (agentId.isEmpty) {
      return userId.isEmpty
          ? hairKey
          : 'aseman.brain.by.$userId.avatar.hair';
    }
    return userId.isEmpty
        ? 'aseman.agent.$agentId.avatar.hair'
        : 'aseman.agent.$agentId.by.$userId.avatar.hair';
  }

  static String _accentKeyFor(String agentId, String userId) {
    if (agentId.isEmpty) {
      return userId.isEmpty
          ? accentKey
          : 'aseman.brain.by.$userId.avatar.accent';
    }
    return userId.isEmpty
        ? 'aseman.agent.$agentId.avatar.accent'
        : 'aseman.agent.$agentId.by.$userId.avatar.accent';
  }

  static const skinTones = <Color>[
    Color(0xFFF6D7C3),
    Color(0xFFE8B896),
    Color(0xFFD29B6E),
    Color(0xFFA56B3F),
    Color(0xFF6D4424),
    Color(0xFF3E2A1C),
  ];

  static const hairStyles = <_HairStyle>[
    _HairStyle('Crop', Color(0xFF1C1A17)),
    _HairStyle('Waves', Color(0xFF3B2F2A)),
    _HairStyle('Fluff', Color(0xFF6B4423)),
    _HairStyle('Sweep', Color(0xFF6E7278)),
    _HairStyle('Silver', Color(0xFFB8BDC6)),
  ];

  Color get skinColor =>
      skinTones[skin.clamp(0, skinTones.length - 1)];

  _HairStyle get hairStyle =>
      hairStyles[hair.clamp(0, hairStyles.length - 1)];

  Color accentOr(Color fallback) =>
      accentArgb == null ? fallback : Color(accentArgb!);

  BrainAvatarPrefs copyWith({
    int? skin,
    int? hair,
    int? accentArgb,
    String? agentId,
    String? userId,
    bool clearAccent = false,
  }) =>
      BrainAvatarPrefs(
        skin: skin ?? this.skin,
        hair: hair ?? this.hair,
        accentArgb: clearAccent ? null : (accentArgb ?? this.accentArgb),
        agentId: agentId ?? this.agentId,
        userId: userId ?? this.userId,
      );

  factory BrainAvatarPrefs.fromHumanoid(
    AgentHumanoid look, {
    String agentId = '',
    String userId = '',
  }) =>
      BrainAvatarPrefs(
        skin: look.skin.clamp(0, skinTones.length - 1),
        hair: look.hair.clamp(0, hairStyles.length - 1),
        accentArgb: look.accentArgb,
        agentId: agentId,
        userId: userId,
      );

  /// Resolve look: personal override → platform default → seed from agent id.
  static Future<BrainAvatarPrefs> load({
    String agentId = '',
    String userId = '',
    AgentHumanoid? platform,
  }) async {
    final uid = resolveUserId(userId);
    final live = liveFor(agentId, uid);
    if (live != null) return live;
    try {
      final prefs = await SharedPreferences.getInstance();
      final scopedSkin = _skinKeyFor(agentId, uid);
      final scopedHair = _hairKeyFor(agentId, uid);
      final legacySkin = _skinKeyFor(agentId, '');
      final legacyHair = _hairKeyFor(agentId, '');
      final hasScoped = prefs.containsKey(scopedSkin) ||
          prefs.containsKey(scopedHair) ||
          prefs.containsKey(_accentKeyFor(agentId, uid));
      final hasLegacy = uid.isNotEmpty &&
          (prefs.containsKey(legacySkin) ||
              prefs.containsKey(legacyHair) ||
              prefs.containsKey(_accentKeyFor(agentId, '')));
      if (hasScoped || hasLegacy) {
        final skinKey = hasScoped ? scopedSkin : legacySkin;
        final hairKey = hasScoped ? scopedHair : legacyHair;
        final accentKey =
            hasScoped ? _accentKeyFor(agentId, uid) : _accentKeyFor(agentId, '');
        final loaded = BrainAvatarPrefs(
          skin: prefs.getInt(skinKey) ??
              prefs.getInt(legacySkin) ??
              platform?.skin ??
              2,
          hair: prefs.getInt(hairKey) ??
              prefs.getInt(legacyHair) ??
              platform?.hair ??
              1,
          accentArgb: prefs.getInt(accentKey) ??
              (hasScoped ? null : prefs.getInt(_accentKeyFor(agentId, ''))),
          agentId: agentId,
          userId: uid,
        );
        // Migrate legacy device keys into the per-person namespace once.
        if (hasLegacy && !hasScoped && uid.isNotEmpty) {
          unawaited(loaded.save());
        }
        return loaded;
      }
      if (platform != null) {
        return BrainAvatarPrefs.fromHumanoid(
          platform,
          agentId: agentId,
          userId: uid,
        );
      }
      if (agentId.isNotEmpty) {
        return BrainAvatarPrefs.fromHumanoid(
          AgentHumanoid.seedFrom(agentId),
          agentId: agentId,
          userId: uid,
        );
      }
      return BrainAvatarPrefs(agentId: agentId, userId: uid);
    } catch (_) {
      if (platform != null) {
        return BrainAvatarPrefs.fromHumanoid(
          platform,
          agentId: agentId,
          userId: uid,
        );
      }
      if (agentId.isNotEmpty) {
        return BrainAvatarPrefs.fromHumanoid(
          AgentHumanoid.seedFrom(agentId),
          agentId: agentId,
          userId: uid,
        );
      }
      return BrainAvatarPrefs(agentId: agentId, userId: uid);
    }
  }

  Future<void> save() async {
    final uid = resolveUserId(userId);
    final snapshot = uid == userId
        ? this
        : copyWith(userId: uid);
    _live[_liveKey(agentId, uid)] = snapshot;
    revision.value++;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_skinKeyFor(agentId, uid), skin);
      await prefs.setInt(_hairKeyFor(agentId, uid), hair);
      final key = _accentKeyFor(agentId, uid);
      if (accentArgb == null) {
        await prefs.remove(key);
      } else {
        await prefs.setInt(key, accentArgb!);
      }
    } catch (_) {}
  }
}

class _HairStyle {
  const _HairStyle(this.label, this.color);
  final String label;
  final Color color;
}

/// Soft 3D companion avatar (Grok/Dots-like clay volume) for Aseman and agents.
class BrainAvatar extends StatefulWidget {
  const BrainAvatar({
    super.key,
    required this.prefs,
    required this.accent,
    this.size = 88,
    this.listening = false,
  });

  final BrainAvatarPrefs prefs;
  final Color accent;
  final double size;
  final bool listening;

  @override
  State<BrainAvatar> createState() => _BrainAvatarState();
}

class _BrainAvatarState extends State<BrainAvatar>
    with SingleTickerProviderStateMixin {
  AnimationController? _life;

  /// Motion only while listening — keeps lists/tests settleable and cheap.
  bool get _animate => widget.listening;

  @override
  void initState() {
    super.initState();
    _syncLife();
  }

  @override
  void didUpdateWidget(covariant BrainAvatar old) {
    super.didUpdateWidget(old);
    if (old.listening != widget.listening || old.size != widget.size) {
      _syncLife();
    }
  }

  void _syncLife() {
    if (_animate) {
      _life ??= AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 2600),
      )..repeat(reverse: true);
    } else {
      _life?.dispose();
      _life = null;
    }
  }

  @override
  void dispose() {
    _life?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ring = widget.prefs.accentOr(widget.accent);
    final size = widget.size;
    final corners = context.avatarBorderRadius(size);
    final shell = DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: corners,
        boxShadow: [
          BoxShadow(
            color: ring.withValues(alpha: widget.listening ? .42 : .2),
            blurRadius: widget.listening ? 26 : 16,
            offset: const Offset(0, 7),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: corners,
        child: _life == null
          ? CustomPaint(
              painter: _Soft3dAvatarPainter(
                skin: widget.prefs.skinColor,
                hair: widget.prefs.hairStyle.color,
                hairIndex: widget.prefs.hair,
                accent: ring,
                listening: widget.listening,
                phase: .5,
              ),
            )
          : AnimatedBuilder(
              animation: _life!,
              builder: (context, _) {
                final t = Curves.easeInOut.transform(_life!.value);
                final breathe =
                    1 + (widget.listening ? .028 : .014) * (t * 2 - 1);
                final bob = (widget.listening ? 1.4 : .7) * (t * 2 - 1);
                return Transform.translate(
                  offset: Offset(0, bob),
                  child: Transform.scale(
                    scale: breathe,
                    child: CustomPaint(
                      painter: _Soft3dAvatarPainter(
                        skin: widget.prefs.skinColor,
                        hair: widget.prefs.hairStyle.color,
                        hairIndex: widget.prefs.hair,
                        accent: ring,
                        listening: widget.listening,
                        phase: t,
                      ),
                    ),
                  ),
                );
              },
            ),
      ),
    );
    return SizedBox(width: size, height: size, child: shell);
  }
}

/// Humanoid for an agent: platform default (or seed), with optional personal
/// override for [userId], and an optional creator-set picture as a BR badge.
///
/// Listens to [BrainAvatarPrefs.revision] so a studio save refreshes every
/// mounted instance across the app immediately.
class AgentHumanoidAvatar extends StatefulWidget {
  const AgentHumanoidAvatar({
    super.key,
    required this.agentId,
    this.picture = '',
    this.userId = '',
    this.platform,
    this.prefs,
    this.radius = 24,
    this.listening = false,
  });

  /// Prefs key: bot record id when known, else the bot account id.
  final String agentId;

  /// Creator-set picture file id (or URL); empty when none.
  final String picture;

  /// Current account — personal customization is keyed to this person.
  /// Empty falls back to [BrainAvatarPrefs.viewerId].
  final String userId;

  /// Platform-default look from the agent's profile (null → seed from id).
  final AgentHumanoid? platform;

  /// Optional already-resolved look (e.g. from the studio opener). When set,
  /// paints immediately; still refreshes on [BrainAvatarPrefs.revision].
  final BrainAvatarPrefs? prefs;

  final double radius;
  final bool listening;

  @override
  State<AgentHumanoidAvatar> createState() => _AgentHumanoidAvatarState();
}

class _AgentHumanoidAvatarState extends State<AgentHumanoidAvatar> {
  BrainAvatarPrefs _prefs = const BrainAvatarPrefs();
  int _seenRevision = -1;

  String get _userId => BrainAvatarPrefs.resolveUserId(widget.userId);

  @override
  void initState() {
    super.initState();
    if (widget.prefs != null) {
      _prefs = widget.prefs!;
    } else {
      final live = BrainAvatarPrefs.liveFor(widget.agentId, _userId);
      if (live != null) _prefs = live;
    }
    _seenRevision = BrainAvatarPrefs.revision.value;
    BrainAvatarPrefs.revision.addListener(_onRevision);
    unawaited(_load());
  }

  @override
  void dispose() {
    BrainAvatarPrefs.revision.removeListener(_onRevision);
    super.dispose();
  }

  void _onRevision() {
    if (!mounted) return;
    if (_seenRevision == BrainAvatarPrefs.revision.value) return;
    _seenRevision = BrainAvatarPrefs.revision.value;
    unawaited(_load());
  }

  @override
  void didUpdateWidget(covariant AgentHumanoidAvatar old) {
    super.didUpdateWidget(old);
    if (old.agentId != widget.agentId ||
        old.userId != widget.userId ||
        old.platform?.skin != widget.platform?.skin ||
        old.platform?.hair != widget.platform?.hair ||
        old.platform?.accentArgb != widget.platform?.accentArgb ||
        old.prefs?.skin != widget.prefs?.skin ||
        old.prefs?.hair != widget.prefs?.hair ||
        old.prefs?.accentArgb != widget.prefs?.accentArgb) {
      if (widget.prefs != null) {
        setState(() => _prefs = widget.prefs!);
      }
      unawaited(_load());
    }
  }

  Future<void> _load() async {
    final id = widget.agentId;
    final uid = _userId;
    final live = BrainAvatarPrefs.liveFor(id, uid);
    if (live != null) {
      if (!mounted || id != widget.agentId) return;
      setState(() => _prefs = live);
      return;
    }
    final prefs = await BrainAvatarPrefs.load(
      agentId: id,
      userId: uid,
      platform: widget.platform,
    );
    if (!mounted || id != widget.agentId) return;
    // A save may have landed while we awaited; prefer the live snapshot.
    setState(() => _prefs = BrainAvatarPrefs.liveFor(id, uid) ?? prefs);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final size = widget.radius * 2;
    final accent =
        AppSettingsScope.maybeOf(context)?.accent ?? scheme.primary;
    final picture = Avatars.of(widget.picture);
    final badge = (widget.radius * .72).clamp(12.0, 22.0);
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          BrainAvatar(
            prefs: _prefs.copyWith(agentId: widget.agentId, userId: _userId),
            accent: accent,
            size: size,
            listening: widget.listening,
          ),
          if (picture != null)
            Positioned(
              right: -2,
              bottom: -2,
              child: Builder(builder: (context) {
                final corners = context.avatarBorderRadius(badge);
                return Container(
                  width: badge,
                  height: badge,
                  decoration: BoxDecoration(
                    borderRadius: corners,
                    color: scheme.surface,
                    border: Border.all(color: scheme.surface, width: 2),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: .18),
                        blurRadius: 4,
                        offset: const Offset(0, 1),
                      ),
                    ],
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: AvatarFace(
                    size: badge,
                    borderRadius: corners,
                    foregroundImage: picture,
                    onImageError: (_, __) {},
                    backgroundColor: ThemeRoles.wellFill(context),
                    child: Icon(Icons.smart_toy_rounded, size: badge * .4),
                  ),
                );
              }),
            ),
        ],
      ),
    );
  }
}

/// Studio-lit soft-clay companion: volumetric head, glossy capsule eyes,
/// plush hair tufts — in the spirit of Grok Bot / Dots / Mausbot mascots.
class _Soft3dAvatarPainter extends CustomPainter {
  _Soft3dAvatarPainter({
    required this.skin,
    required this.hair,
    required this.hairIndex,
    required this.accent,
    required this.listening,
    required this.phase,
  });

  final Color skin;
  final Color hair;
  final int hairIndex;
  final Color accent;
  final bool listening;
  final double phase;

  Color get _skinDeep => Color.lerp(skin, const Color(0xFF3A2418), .28)!;
  Color get _skinLit => Color.lerp(skin, Colors.white, .42)!;
  Color get _hairDeep => Color.lerp(hair, Colors.black, .35)!;
  Color get _hairLit => Color.lerp(hair, Colors.white, .28)!;

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    final r = size.shortestSide / 2;

    _paintAura(canvas, c, r);
    _paintContactShadow(canvas, c, r);

    final bodyC = Offset(c.dx, c.dy + r * .38);
    final bodyR = r * .36;
    final headC = Offset(c.dx, c.dy - r * .12);
    final headR = r * .46;

    _paintBody(canvas, bodyC, bodyR, headC, headR);
    _paintHairBack(canvas, headC, headR);
    _paintHead(canvas, headC, headR);
    _paintHairFront(canvas, headC, headR);
    // Re-assert the face bowl so hair tufts never sit across the mid-face.
    _paintFaceBowl(canvas, headC, headR);
    _paintFace(canvas, headC, headR);
    if (listening) _paintListeningGlow(canvas, c, r);
  }

  void _paintAura(Canvas canvas, Offset c, double r) {
    final aura = Paint()
      ..shader = RadialGradient(
        center: const Alignment(-.25, -.35),
        colors: [
          accent.withValues(alpha: listening ? .34 : .2),
          accent.withValues(alpha: .07),
          Colors.transparent,
        ],
        stops: const [0.0, .45, 1.0],
      ).createShader(Rect.fromCircle(center: c, radius: r));
    canvas.drawCircle(c, r, aura);
  }

  void _paintContactShadow(Canvas canvas, Offset c, double r) {
    final shadow = Paint()
      ..shader = RadialGradient(
        colors: [
          Colors.black.withValues(alpha: .22),
          Colors.black.withValues(alpha: .06),
          Colors.transparent,
        ],
        stops: const [0.0, .45, 1.0],
      ).createShader(Rect.fromCenter(
        center: Offset(c.dx, c.dy + r * .78),
        width: r * 1.15,
        height: r * .28,
      ));
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(c.dx, c.dy + r * .78),
        width: r * 1.15,
        height: r * .28,
      ),
      shadow,
    );
  }

  void _paintBody(
    Canvas canvas,
    Offset bodyC,
    double bodyR,
    Offset headC,
    double headR,
  ) {
    // Soft torso blob in accent “plush”.
    final torso = Rect.fromCenter(
      center: bodyC,
      width: bodyR * 2.15,
      height: bodyR * 1.7,
    );
    final deep = Color.lerp(accent, Colors.black, .22)!;
    final lit = Color.lerp(accent, Colors.white, .35)!;
    canvas.drawRRect(
      RRect.fromRectAndRadius(torso, Radius.circular(bodyR)),
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(-.35, -.55),
          radius: 1.15,
          colors: [lit, accent, deep],
          stops: const [0.0, .45, 1.0],
        ).createShader(torso),
    );
    // Specular kiss on the torso.
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(bodyC.dx - bodyR * .28, bodyC.dy - bodyR * .35),
        width: bodyR * .7,
        height: bodyR * .35,
      ),
      Paint()..color = Colors.white.withValues(alpha: .22),
    );
    // Soft neck join.
    final neck = Rect.fromCenter(
      center: Offset(headC.dx, headC.dy + headR * .78),
      width: headR * .55,
      height: headR * .42,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(neck, Radius.circular(headR * .28)),
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [_skinLit, skin, _skinDeep],
        ).createShader(neck),
    );
  }

  void _paintHead(Canvas canvas, Offset head, double headR) {
    final rect = Rect.fromCircle(center: head, radius: headR);
    // Main sphere volume.
    canvas.drawCircle(
      head,
      headR,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(-.38, -.48),
          radius: 1.05,
          colors: [
            _skinLit,
            skin,
            Color.lerp(skin, _skinDeep, .55)!,
            _skinDeep,
          ],
          stops: const [0.0, .38, .78, 1.0],
        ).createShader(rect),
    );
    // Rim light (back-right).
    canvas.drawArc(
      rect.deflate(headR * .02),
      -math.pi * .15,
      math.pi * .55,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = headR * .07
        ..color = Colors.white.withValues(alpha: .28)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, headR * .04),
    );
    // Soft cheek AO.
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(head.dx, head.dy + headR * .22),
        width: headR * 1.55,
        height: headR * .95,
      ),
      Paint()..color = Colors.black.withValues(alpha: .05),
    );
    // Primary specular.
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(head.dx - headR * .28, head.dy - headR * .32),
        width: headR * .55,
        height: headR * .32,
      ),
      Paint()..color = Colors.white.withValues(alpha: .38),
    );
    // Tiny secondary sparkle.
    canvas.drawCircle(
      Offset(head.dx + headR * .22, head.dy - headR * .38),
      headR * .045,
      Paint()..color = Colors.white.withValues(alpha: .45),
    );
  }

  void _sphere(
    Canvas canvas,
    Offset center,
    double radius,
    Color mid,
    Color lit,
    Color deep, {
    Alignment light = const Alignment(-.4, -.5),
  }) {
    final rect = Rect.fromCircle(center: center, radius: radius);
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..shader = RadialGradient(
          center: light,
          radius: 1.1,
          colors: [lit, mid, deep],
          stops: const [0.0, .5, 1.0],
        ).createShader(rect),
    );
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(
          center.dx + light.x * radius * .35,
          center.dy + light.y * radius * .35,
        ),
        width: radius * .55,
        height: radius * .32,
      ),
      Paint()..color = Colors.white.withValues(alpha: .28),
    );
  }

  void _paintHairBack(Canvas canvas, Offset head, double headR) {
    final idx = hairIndex.clamp(0, 4);
    if (idx == 0) return; // short crop — mostly front cap
    // Soft rear crown volume — sits on top of the skull, above the brow.
    _sphere(
      canvas,
      Offset(head.dx, head.dy - headR * .78),
      headR * (idx == 2 ? .55 : .48),
      hair,
      _hairLit,
      _hairDeep,
      light: const Alignment(-.3, -.6),
    );
  }

  void _paintHairFront(Canvas canvas, Offset head, double headR) {
    final idx = hairIndex.clamp(0, 4);
    switch (idx) {
      case 0: // Short crop — soft top cap
        _sphere(
          canvas,
          Offset(head.dx, head.dy - headR * .88),
          headR * .4,
          hair,
          _hairLit,
          _hairDeep,
          light: const Alignment(-.35, -.65),
        );
        break;
      case 1: // Soft wave — crown + high side tufts
        _sphere(
          canvas,
          Offset(head.dx, head.dy - headR * .92),
          headR * .38,
          hair,
          _hairLit,
          _hairDeep,
        );
        _sphere(
          canvas,
          Offset(head.dx - headR * .72, head.dy - headR * .55),
          headR * .22,
          hair,
          _hairLit,
          _hairDeep,
        );
        _sphere(
          canvas,
          Offset(head.dx + headR * .72, head.dy - headR * .55),
          headR * .22,
          hair,
          _hairLit,
          _hairDeep,
        );
        break;
      case 2: // Fuller fluff — taller crown + high side tufts
        _sphere(
          canvas,
          Offset(head.dx, head.dy - headR * .9),
          headR * .46,
          hair,
          _hairLit,
          _hairDeep,
        );
        _sphere(
          canvas,
          Offset(head.dx - headR * .78, head.dy - headR * .5),
          headR * .24,
          hair,
          _hairLit,
          _hairDeep,
        );
        _sphere(
          canvas,
          Offset(head.dx + headR * .78, head.dy - headR * .5),
          headR * .24,
          hair,
          _hairLit,
          _hairDeep,
        );
        break;
      case 3: // Side sweep — high crown spilling to one side
        _sphere(
          canvas,
          Offset(head.dx - headR * .12, head.dy - headR * .9),
          headR * .42,
          hair,
          _hairLit,
          _hairDeep,
        );
        _sphere(
          canvas,
          Offset(head.dx + headR * .58, head.dy - headR * .58),
          headR * .28,
          hair,
          _hairLit,
          _hairDeep,
          light: const Alignment(.2, -.5),
        );
        break;
      default: // Silver swept crown
        _sphere(
          canvas,
          Offset(head.dx + headR * .08, head.dy - headR * .9),
          headR * .4,
          hair,
          _hairLit,
          _hairDeep,
        );
        _sphere(
          canvas,
          Offset(head.dx - headR * .58, head.dy - headR * .55),
          headR * .24,
          hair,
          _hairLit,
          _hairDeep,
        );
        break;
    }
  }

  /// Lower face hemisphere so hair never covers eyes / cheeks / mouth.
  void _paintFaceBowl(Canvas canvas, Offset head, double headR) {
    // Clip from just above the eyes so crown hair never sits mid-face.
    final clip = Path()
      ..addRect(Rect.fromLTRB(
        head.dx - headR * 1.05,
        head.dy - headR * .22,
        head.dx + headR * 1.05,
        head.dy + headR * 1.05,
      ));
    canvas.save();
    canvas.clipPath(clip);
    final rect = Rect.fromCircle(center: head, radius: headR);
    canvas.drawCircle(
      head,
      headR,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(-.38, -.48),
          radius: 1.05,
          colors: [
            _skinLit,
            skin,
            Color.lerp(skin, _skinDeep, .55)!,
            _skinDeep,
          ],
          stops: const [0.0, .38, .78, 1.0],
        ).createShader(rect),
    );
    canvas.restore();
  }

  void _paintFace(Canvas canvas, Offset head, double headR) {
    final glance = listening ? .04 * math.sin(phase * math.pi) : 0.0;
    final eyeY = head.dy - headR * .02;
    final eyeDx = headR * .34;
    final eyeW = headR * .34;
    final eyeH = headR * (listening ? .26 : .30);

    for (final side in [-1.0, 1.0]) {
      final eye = Offset(head.dx + eyeDx * side + headR * glance, eyeY);
      // Soft eye socket AO.
      canvas.drawOval(
        Rect.fromCenter(
          center: eye.translate(0, headR * .02),
          width: eyeW * 1.15,
          height: eyeH * 1.25,
        ),
        Paint()..color = Colors.black.withValues(alpha: .08),
      );
      // Glossy white capsule (Grok-style).
      final eyeRect = Rect.fromCenter(center: eye, width: eyeW, height: eyeH);
      canvas.drawRRect(
        RRect.fromRectAndRadius(eyeRect, Radius.circular(eyeH)),
        Paint()
          ..shader = const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Color(0xFFFFFFFF),
              Color(0xFFF2F0EC),
              Color(0xFFE4E0DA),
            ],
          ).createShader(eyeRect),
      );
      // Iris / pupil cluster.
      final pupil = Offset(eye.dx + headR * .03 * side, eye.dy + headR * .01);
      canvas.drawCircle(
        pupil,
        headR * .09,
        Paint()
          ..shader = RadialGradient(
            colors: [
              Color.lerp(accent, const Color(0xFF1A2430), .55)!,
              const Color(0xFF121820),
            ],
          ).createShader(Rect.fromCircle(center: pupil, radius: headR * .09)),
      );
      // Catchlights.
      canvas.drawCircle(
        Offset(pupil.dx - headR * .03, pupil.dy - headR * .035),
        headR * .035,
        Paint()..color = Colors.white.withValues(alpha: .95),
      );
      canvas.drawCircle(
        Offset(pupil.dx + headR * .025, pupil.dy + headR * .02),
        headR * .015,
        Paint()..color = Colors.white.withValues(alpha: .55),
      );
    }

    // Soft blush orbs.
    for (final side in [-1.0, 1.0]) {
      canvas.drawOval(
        Rect.fromCenter(
          center: Offset(head.dx + headR * .48 * side, head.dy + headR * .28),
          width: headR * .32,
          height: headR * .18,
        ),
        Paint()
          ..color = Color.lerp(accent, const Color(0xFFE88A7A), .45)!
              .withValues(alpha: .28),
      );
    }

    // Tiny clay nose bump.
    _sphere(
      canvas,
      Offset(head.dx, head.dy + headR * .18),
      headR * .07,
      Color.lerp(skin, _skinDeep, .15)!,
      _skinLit,
      _skinDeep,
      light: const Alignment(-.3, -.6),
    );

    // Cute soft smile.
    final smile = Paint()
      ..color = const Color(0xFF7A4A42).withValues(alpha: .7)
      ..style = PaintingStyle.stroke
      ..strokeWidth = headR * .055
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(
      Rect.fromCenter(
        center: Offset(head.dx, head.dy + headR * .42),
        width: headR * .48,
        height: headR * .28,
      ),
      math.pi * .18,
      math.pi * .64,
      false,
      smile,
    );
  }

  void _paintListeningGlow(Canvas canvas, Offset c, double r) {
    final pulse = .35 + .25 * math.sin(phase * math.pi);
    canvas.drawCircle(
      c,
      r * (.88 + .04 * phase),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = r * .045
        ..color = accent.withValues(alpha: pulse)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, r * .03),
    );
  }

  @override
  bool shouldRepaint(covariant _Soft3dAvatarPainter old) =>
      old.skin != skin ||
      old.hair != hair ||
      old.hairIndex != hairIndex ||
      old.accent != accent ||
      old.listening != listening ||
      old.phase != phase;
}

/// Compact sheet to tweak skin, hair, and accent. On a desktop window it is a
/// full-height drawer from the right edge.
Future<BrainAvatarPrefs?> showBrainAvatarSettings(
  BuildContext context, {
  required BrainAvatarPrefs prefs,
  required Color appAccent,
}) {
  final sheet = _AvatarSettingsSheet(initial: prefs, appAccent: appAccent);
  if (MediaQuery.sizeOf(context).width < Breakpoints.expanded) {
    return showModalBottomSheet<BrainAvatarPrefs>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => sheet,
    );
  }
  return showDockedPanel<BrainAvatarPrefs>(
    context: context,
    width: 420,
    barrierLabel: 'Close avatar',
    builder: (_) => sheet,
  );
}

class _AvatarSettingsSheet extends StatefulWidget {
  const _AvatarSettingsSheet({
    required this.initial,
    required this.appAccent,
  });

  final BrainAvatarPrefs initial;
  final Color appAccent;

  @override
  State<_AvatarSettingsSheet> createState() => _AvatarSettingsSheetState();
}

class _AvatarSettingsSheetState extends State<_AvatarSettingsSheet> {
  late BrainAvatarPrefs prefs = widget.initial;

  static const _accentChoices = <Color?>[
    null, // app accent
    Color(0xFF2A78D6),
    Color(0xFF1BAF7A),
    Color(0xFFEB6834),
    Color(0xFF00838F),
    Color(0xFFB8860B),
  ];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final accent = prefs.accentOr(widget.appAccent);
    final docked = MediaQuery.sizeOf(context).width >= Breakpoints.expanded;
    final body = <Widget>[
      if (!docked)
        Center(
          child: Container(
            width: 36,
            height: 4,
            decoration: BoxDecoration(
              color: scheme.outlineVariant,
              borderRadius: BorderRadius.circular(99),
            ),
          ),
        ),
      if (!docked) const SizedBox(height: 16),
              Row(
                children: [
                  BrainAvatar(prefs: prefs, accent: accent, size: 64),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          prefs.agentId.isEmpty
                              ? '3D companion look'
                              : '3D agent look',
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                        Text(
                          prefs.agentId.isEmpty
                              ? 'Soft clay style — kept on this device.'
                              : 'Personal 3D look — only you see this.',
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              Text('Skin', style: Theme.of(context).textTheme.labelLarge),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  for (var i = 0; i < BrainAvatarPrefs.skinTones.length; i++)
                    _Swatch(
                      color: BrainAvatarPrefs.skinTones[i],
                      selected: prefs.skin == i,
                      onTap: () => setState(
                        () => prefs = prefs.copyWith(skin: i),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              Text('Hair', style: Theme.of(context).textTheme.labelLarge),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (var i = 0; i < BrainAvatarPrefs.hairStyles.length; i++)
                    ChoiceChip(
                      label: Text(BrainAvatarPrefs.hairStyles[i].label),
                      selected: prefs.hair == i,
                      onSelected: (_) => setState(
                        () => prefs = prefs.copyWith(hair: i),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              Text('Accent', style: Theme.of(context).textTheme.labelLarge),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  for (final color in _accentChoices)
                    _Swatch(
                      color: color ?? widget.appAccent,
                      selected: color == null
                          ? prefs.accentArgb == null
                          : prefs.accentArgb == color.toARGB32(),
                      label: color == null ? 'App' : null,
                      onTap: () => setState(() {
                        prefs = color == null
                            ? prefs.copyWith(clearAccent: true)
                            : prefs.copyWith(accentArgb: color.toARGB32());
                      }),
                    ),
                ],
              ),
              const SizedBox(height: 20),
              FilledButton(
                onPressed: () async {
                  await prefs.save();
                  if (context.mounted) Navigator.pop(context, prefs);
                },
                child: const Text('Save'),
              ),
    ];
    return Material(
      color: scheme.surface.withValues(alpha: .96),
      borderRadius: docked
          ? BorderRadius.zero
          : const BorderRadius.vertical(top: Radius.circular(24)),
      child: SafeArea(
        top: docked,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
          child: docked
              ? ListView(
                  padding: EdgeInsets.zero,
                  children: body,
                )
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: body,
                ),
        ),
      ),
    );
  }
}

class _Swatch extends StatelessWidget {
  const _Swatch({
    required this.color,
    required this.selected,
    required this.onTap,
    this.label,
  });

  final Color color;
  final bool selected;
  final VoidCallback onTap;
  final String? label;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        width: 36,
        height: 36,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(
            color: selected
                ? Theme.of(context).colorScheme.onSurface
                : Colors.black26,
            width: selected ? 2.5 : 1,
          ),
        ),
        child: label == null
            ? null
            : Text(
                label!,
                style: TextStyle(
                  fontSize: 9,
                  fontWeight: FontWeight.w700,
                  color: color.computeLuminance() > .45
                      ? Colors.black87
                      : Colors.white,
                ),
              ),
      ),
    );
  }
}
