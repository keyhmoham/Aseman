import 'package:flutter/material.dart';

import '../../core/theme/app_shape.dart';

/// Shimmering placeholders shown in place of content that is still loading.
///
/// [Skeleton] runs one shimmer for everything beneath it; the shapes
/// ([SkeletonBox], [SkeletonLine], [SkeletonCircle]) are plain blocks it
/// sweeps a highlight across. The composites ([SkeletonListTile],
/// [SkeletonList], [SkeletonPage], …) wrap themselves, and a [Skeleton]
/// inside another reuses the outer shimmer, so they nest freely.
class Skeleton extends StatefulWidget {
  const Skeleton({
    super.key,
    required this.child,
    this.baseColor,
    this.highlightColor,
  });

  final Widget child;

  /// The blocks' color; defaults to the theme's highest container surface.
  final Color? baseColor;

  /// The sweep's color; defaults to [baseColor] lightened.
  final Color? highlightColor;

  @override
  State<Skeleton> createState() => _SkeletonState();
}

class _SkeletonState extends State<Skeleton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 1500));

  /// Off when the platform asks for reduced motion.
  bool get _animate => !(MediaQuery.maybeDisableAnimationsOf(context) ?? false);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_animate) {
      if (!_controller.isAnimating) _controller.repeat();
    } else {
      _controller.stop();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Already under a shimmer: share it rather than stacking another.
    if (_SkeletonScope.maybeOf(context) != null) return widget.child;
    final scheme = Theme.of(context).colorScheme;
    final base = widget.baseColor ?? scheme.surfaceContainerHighest;
    final highlight = widget.highlightColor ??
        Color.lerp(base, Colors.white,
            scheme.brightness == Brightness.dark ? .1 : .6)!;
    final scoped = _SkeletonScope(base: base, child: widget.child);
    if (!_animate) return Semantics(label: 'Loading', child: scoped);
    return Semantics(
      label: 'Loading',
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, child) => ShaderMask(
          blendMode: BlendMode.srcATop,
          shaderCallback: (bounds) => LinearGradient(
            begin: Alignment.centerLeft,
            end: Alignment.centerRight,
            colors: [base, highlight, base],
            stops: const [.35, .5, .65],
            transform: _Sweep(_controller.value),
          ).createShader(bounds),
          child: child,
        ),
        child: scoped,
      ),
    );
  }
}

/// Slides the shimmer gradient from off the left edge to off the right.
class _Sweep extends GradientTransform {
  const _Sweep(this.t);
  final double t;

  @override
  Matrix4 transform(Rect bounds, {TextDirection? textDirection}) =>
      Matrix4.translationValues(bounds.width * (t * 2 - 1), 0, 0);
}

class _SkeletonScope extends InheritedWidget {
  const _SkeletonScope({required this.base, required super.child});
  final Color base;

  static _SkeletonScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_SkeletonScope>();

  @override
  bool updateShouldNotify(_SkeletonScope old) => base != old.base;
}

Color _blockColor(BuildContext context) =>
    _SkeletonScope.maybeOf(context)?.base ??
    Theme.of(context).colorScheme.surfaceContainerHighest;

/// A rounded placeholder block, e.g. for an image, a button or a field.
class SkeletonBox extends StatelessWidget {
  const SkeletonBox({super.key, this.width, this.height, this.radius = 12});

  /// Fills the space it is given (none, where that space is unbounded).
  const SkeletonBox.expand({super.key, this.radius = 0})
      : width = null,
        height = null;

  final double? width;
  final double? height;
  final double radius;

  @override
  Widget build(BuildContext context) => Skeleton(
        child: Container(
          width: width,
          height: height,
          decoration: BoxDecoration(
            color: _blockColor(context),
            borderRadius: BorderRadius.circular(radius),
          ),
        ),
      );
}

/// A placeholder for a form field or a full-width button.
class SkeletonField extends StatelessWidget {
  const SkeletonField({super.key, this.height = 56});
  final double height;

  @override
  Widget build(BuildContext context) => SkeletonBox(
      width: double.infinity, height: height, radius: AppShape.control);
}

/// A placeholder for one line of text.
class SkeletonLine extends StatelessWidget {
  const SkeletonLine({
    super.key,
    this.widthFactor = 1,
    this.width,
    this.height = 12,
  });

  /// Its share of the available width, when [width] is not set.
  final double widthFactor;
  final double? width;
  final double height;

  @override
  Widget build(BuildContext context) {
    final line = SkeletonBox(width: width, height: height, radius: height / 2);
    if (width != null) {
      return Align(alignment: AlignmentDirectional.centerStart, child: line);
    }
    return FractionallySizedBox(
        alignment: AlignmentDirectional.centerStart,
        widthFactor: widthFactor,
        child: line);
  }
}

/// A round placeholder, e.g. for an avatar.
class SkeletonCircle extends StatelessWidget {
  const SkeletonCircle({super.key, this.size = 40});
  final double size;

  @override
  Widget build(BuildContext context) => Skeleton(
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
              color: _blockColor(context), shape: BoxShape.circle),
        ),
      );
}

/// A few lines of text, the last one shorter.
class SkeletonParagraph extends StatelessWidget {
  const SkeletonParagraph({super.key, this.lines = 3, this.lineHeight = 12});
  final int lines;
  final double lineHeight;

  @override
  Widget build(BuildContext context) => Skeleton(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < lines; i++) ...[
              if (i > 0) SizedBox(height: lineHeight * .75),
              SkeletonLine(
                  height: lineHeight,
                  widthFactor: i == lines - 1 && lines > 1 ? .6 : 1),
            ],
          ],
        ),
      );
}

/// A list row: an optional leading avatar and a title over [lines] - 1
/// shorter lines.
class SkeletonListTile extends StatelessWidget {
  const SkeletonListTile({
    super.key,
    this.leading = true,
    this.leadingSize = 40,
    this.lines = 2,
    this.padding = const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
  });

  final bool leading;
  final double leadingSize;
  final int lines;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) => Skeleton(
        child: Padding(
          padding: padding,
          child: Row(children: [
            if (leading) ...[
              SkeletonCircle(size: leadingSize),
              SizedBox(width: leadingSize * .35),
            ],
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SkeletonLine(widthFactor: .55, height: 13),
                  for (var i = 1; i < lines; i++) ...[
                    const SizedBox(height: 8),
                    SkeletonLine(widthFactor: i.isOdd ? .85 : .4, height: 10),
                  ],
                ],
              ),
            ),
          ]),
        ),
      );
}

/// A card: a media block over a title and a couple of lines.
class SkeletonCard extends StatelessWidget {
  const SkeletonCard({super.key, this.mediaHeight = 96, this.height});

  /// The height of the media block; 0 for none.
  final double mediaHeight;
  final double? height;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Skeleton(
      child: Container(
        height: height,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AppShape.inner),
          border: Border.all(color: scheme.outlineVariant.withValues(alpha: .4)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (mediaHeight > 0) ...[
              SkeletonBox(height: mediaHeight, width: double.infinity),
              const SizedBox(height: 14),
            ],
            const SkeletonLine(widthFactor: .6, height: 14),
            const SizedBox(height: 10),
            const SkeletonParagraph(lines: 2, lineHeight: 10),
          ],
        ),
      ),
    );
  }
}

/// A feed post: author row, a paragraph and a media block.
class SkeletonPost extends StatelessWidget {
  const SkeletonPost({super.key, this.media = true});
  final bool media;

  @override
  Widget build(BuildContext context) => Skeleton(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SkeletonListTile(padding: EdgeInsets.zero),
              const SizedBox(height: 14),
              const SkeletonParagraph(lines: 3),
              if (media) ...[
                const SizedBox(height: 14),
                const SkeletonBox(
                    height: 160, width: double.infinity, radius: AppShape.inner),
              ],
            ],
          ),
        ),
      );
}

/// [itemCount] copies of [item], stacked: the stand-in for a list that is
/// loading. Fits bounded and unbounded heights alike, clipping what does
/// not fit.
class SkeletonList extends StatelessWidget {
  const SkeletonList({
    super.key,
    this.itemCount = 6,
    this.item = const SkeletonListTile(),
    this.spacing = 4,
    this.padding = const EdgeInsets.symmetric(vertical: 8),
  });

  final int itemCount;
  final Widget item;
  final double spacing;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) => Skeleton(
        child: SingleChildScrollView(
          physics: const NeverScrollableScrollPhysics(),
          padding: padding,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < itemCount; i++) ...[
                if (i > 0) SizedBox(height: spacing),
                item,
              ],
            ],
          ),
        ),
      );
}

/// A grid of rounded tiles.
class SkeletonGrid extends StatelessWidget {
  const SkeletonGrid({
    super.key,
    this.itemCount = 6,
    this.maxCrossAxisExtent = 240,
    this.childAspectRatio = 1.1,
    this.mainAxisExtent,
    this.spacing = 12,
    this.padding = EdgeInsets.zero,
  });

  final int itemCount;
  final double maxCrossAxisExtent;
  final double childAspectRatio;

  /// A fixed tile height, overriding [childAspectRatio].
  final double? mainAxisExtent;
  final double spacing;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) => Skeleton(
        child: GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          padding: padding,
          gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: maxCrossAxisExtent,
              childAspectRatio: childAspectRatio,
              mainAxisExtent: mainAxisExtent,
              mainAxisSpacing: spacing,
              crossAxisSpacing: spacing),
          itemCount: itemCount,
          itemBuilder: (_, __) => const SkeletonBox(radius: AppShape.inner),
        ),
      );
}

/// A whole page or panel that is loading: a heading, a row of stat
/// blocks and a list.
class SkeletonPage extends StatelessWidget {
  const SkeletonPage({
    super.key,
    this.padding = const EdgeInsets.all(20),
    this.stats = true,
    this.rows = 5,
  });

  final EdgeInsetsGeometry padding;
  final bool stats;
  final int rows;

  @override
  Widget build(BuildContext context) => Skeleton(
        child: SingleChildScrollView(
          physics: const NeverScrollableScrollPhysics(),
          padding: padding,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SkeletonLine(width: 180, height: 18),
              const SizedBox(height: 10),
              const SkeletonLine(widthFactor: .7, height: 11),
              if (stats) ...[
                const SizedBox(height: 22),
                const Row(children: [
                  Expanded(child: SkeletonBox(height: 78, radius: AppShape.inner)),
                  SizedBox(width: 12),
                  Expanded(child: SkeletonBox(height: 78, radius: AppShape.inner)),
                  SizedBox(width: 12),
                  Expanded(child: SkeletonBox(height: 78, radius: AppShape.inner)),
                ]),
              ],
              const SizedBox(height: 22),
              for (var i = 0; i < rows; i++) ...[
                if (i > 0) const SizedBox(height: 4),
                const SkeletonListTile(padding: EdgeInsets.symmetric(vertical: 10)),
              ],
            ],
          ),
        ),
      );
}
