import 'package:flutter/material.dart';

class AppAvatar extends StatelessWidget {
  const AppAvatar(this.text,
      {super.key, required this.color, this.radius = 19, this.image});
  final String text;
  final Color color;
  final double radius;

  /// A picture shown over the initials; they stay while it loads or when it
  /// cannot be shown.
  final ImageProvider? image;

  @override
  Widget build(BuildContext context) => CircleAvatar(
        radius: radius,
        backgroundColor: color.withValues(alpha: .18),
        foregroundImage: image,
        onForegroundImageError: image == null ? null : (_, __) {},
        child: Text(text,
            style: TextStyle(
                color: color, fontWeight: FontWeight.w800, fontSize: 12)),
      );
}
