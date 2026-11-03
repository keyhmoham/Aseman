import 'package:flutter/material.dart';

import '../../core/theme/theme_chrome.dart';

/// Pack-shaped avatar face (fill + optional photo + label/icon).
///
/// Always clips to [borderRadius] / [BuildContext.avatarBorderRadius] so faces
/// match their halo rings — never a hard-coded [CircleAvatar].
class AvatarFace extends StatelessWidget {
  const AvatarFace({
    super.key,
    required this.size,
    required this.backgroundColor,
    this.foregroundImage,
    this.child,
    this.borderRadius,
    this.onImageError,
  });

  final double size;
  final Color backgroundColor;
  final ImageProvider? foregroundImage;
  final Widget? child;
  final BorderRadius? borderRadius;
  final ImageErrorListener? onImageError;

  @override
  Widget build(BuildContext context) {
    final corners = borderRadius ?? context.avatarBorderRadius(size);
    return ClipRRect(
      borderRadius: corners,
      child: ColoredBox(
        color: backgroundColor,
        child: SizedBox(
          width: size,
          height: size,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (child != null) Center(child: child),
              if (foregroundImage != null)
                Image(
                  image: foregroundImage!,
                  fit: BoxFit.cover,
                  gaplessPlayback: true,
                  errorBuilder: (context, error, stack) {
                    onImageError?.call(error, stack);
                    return const SizedBox.shrink();
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }
}
