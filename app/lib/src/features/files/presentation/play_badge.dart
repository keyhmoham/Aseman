import 'package:flutter/material.dart';

/// The round translucent play button drawn over a video.
class PlayBadge extends StatelessWidget {
  const PlayBadge({super.key, this.size = 56});
  final double size;

  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: .5),
          shape: BoxShape.circle,
          border:
              Border.all(color: Colors.white.withValues(alpha: .85), width: 2),
        ),
        child: Icon(
          Icons.play_arrow_rounded,
          color: Colors.white,
          size: size * .62,
        ),
      );
}
