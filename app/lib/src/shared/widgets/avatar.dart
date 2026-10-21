import 'package:flutter/material.dart';

/// Turns an avatar reference (a stored picture's id, its content path or a
/// web address) into the picture to show. The app points [resolve] at its
/// service once it has one, so any avatar can show its picture.
abstract final class Avatars {
  static ImageProvider? Function(String ref) resolve = (_) => null;

  /// The picture of [ref]; null when there is none.
  static ImageProvider? of(Object? ref) {
    final s = ref is String ? ref.trim() : '';
    return s.isEmpty ? null : resolve(s);
  }
}

class AppAvatar extends StatelessWidget {
  const AppAvatar(this.text,
      {super.key,
      required this.color,
      this.radius = 19,
      this.image,
      this.avatar});
  final String text;
  final Color color;
  final double radius;

  /// A picture shown over the initials; they stay while it loads or when it
  /// cannot be shown.
  final ImageProvider? image;

  /// An avatar reference whose picture is shown when [image] is not given.
  final String? avatar;

  @override
  Widget build(BuildContext context) {
    final picture = image ?? Avatars.of(avatar);
    return CircleAvatar(
        radius: radius,
        backgroundColor: color.withValues(alpha: .18),
        foregroundImage: picture,
        onForegroundImageError: picture == null ? null : (_, __) {},
        child: Text(text,
            style: TextStyle(
                color: color, fontWeight: FontWeight.w800, fontSize: 12)),
      );
  }
}

/// [fallback] (initials or an icon of [size]) with the picture of [avatar]
/// laid over it once it has loaded; the fallback stays when there is no
/// picture or it cannot be shown. [radius] rounds the picture's corners; a
/// circle when not given.
class AvatarPicture extends StatelessWidget {
  const AvatarPicture({
    super.key,
    required this.avatar,
    required this.size,
    required this.fallback,
    this.radius,
  });

  final String? avatar;
  final double size;
  final Widget fallback;
  final double? radius;

  @override
  Widget build(BuildContext context) {
    final image = Avatars.of(avatar);
    if (image == null) return fallback;
    final picture = Image(
      image: image,
      width: size,
      height: size,
      fit: BoxFit.cover,
      gaplessPlayback: true,
      errorBuilder: (_, __, ___) => const SizedBox.shrink(),
    );
    return SizedBox(
      width: size,
      height: size,
      child: Stack(fit: StackFit.expand, children: [
        fallback,
        radius == null
            ? ClipOval(child: picture)
            : ClipRRect(
                borderRadius: BorderRadius.circular(radius!), child: picture),
      ]),
    );
  }
}
