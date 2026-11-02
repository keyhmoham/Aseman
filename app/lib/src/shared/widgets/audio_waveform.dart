import 'dart:math' as math;

import 'package:flutter/material.dart';

/// An audio clip's waveform as bars that fill up as it plays. The bars are
/// drawn from [seed] (the clip's id or URL), so a clip always looks the
/// same. Tapping or dragging across it seeks: [onSeek] gets the fraction.
class AudioWaveform extends StatelessWidget {
  const AudioWaveform({
    super.key,
    required this.seed,
    required this.progress,
    this.onSeek,
    this.activeColor,
    this.inactiveColor,
    this.height = 30,
    this.bars,
  });

  final String seed;

  /// How much has played, 0 to 1.
  final double progress;
  final ValueChanged<double>? onSeek;
  final Color? activeColor;
  final Color? inactiveColor;
  final double height;

  /// Real loudness bars 0–100 from the upload; when set, preferred over [seed].
  final List<int>? bars;

  /// [count] bar heights between .18 and 1, smoothed so they read as speech
  /// or music rather than noise.
  static List<double> levels(String seed, int count) {
    var h = 17;
    for (final c in seed.codeUnits) {
      h = (h * 31 + c) & 0x7fffffff;
    }
    final random = math.Random(h);
    final raw = [for (var i = 0; i < count; i++) random.nextDouble()];
    return [
      for (var i = 0; i < count; i++)
        (.18 +
                .82 *
                    (raw[i] * .5 +
                        raw[math.max(0, i - 1)] * .25 +
                        raw[math.min(count - 1, i + 1)] * .25) *
                    (.55 + .45 * math.sin(math.pi * (i + .5) / count)))
            .clamp(.18, 1.0),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final active = activeColor ?? scheme.primary;
    final inactive = inactiveColor ?? active.withValues(alpha: .3);
    return LayoutBuilder(builder: (context, box) {
      final width = box.maxWidth.isFinite ? box.maxWidth : 180.0;
      final count = (width / 4.5).floor().clamp(12, 72);
      final real = bars;
      final List<double> wave;
      if (real != null && real.isNotEmpty) {
        wave = [
          for (var i = 0; i < count; i++)
            (.18 + .82 * (real[(i * real.length) ~/ count].clamp(0, 100) / 100))
                .clamp(.18, 1.0),
        ];
      } else {
        wave = levels(seed, count);
      }
      void seek(Offset at) =>
          onSeek?.call((at.dx / width).clamp(0.0, 1.0).toDouble());
      return Semantics(
        slider: true,
        value: '${(progress.clamp(0.0, 1.0) * 100).round()}%',
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: onSeek == null ? null : (d) => seek(d.localPosition),
          onHorizontalDragUpdate:
              onSeek == null ? null : (d) => seek(d.localPosition),
          child: CustomPaint(
            size: Size(width, height),
            painter: _WavePainter(
                levels: wave,
                progress: progress.clamp(0.0, 1.0).toDouble(),
                active: active,
                inactive: inactive),
          ),
        ),
      );
    });
  }
}

class _WavePainter extends CustomPainter {
  _WavePainter(
      {required this.levels,
      required this.progress,
      required this.active,
      required this.inactive});
  final List<double> levels;
  final double progress;
  final Color active;
  final Color inactive;

  @override
  void paint(Canvas canvas, Size size) {
    final slot = size.width / levels.length;
    final bar = math.max(1.5, slot * .58);
    final paint = Paint();
    for (var i = 0; i < levels.length; i++) {
      final h = math.max(bar, size.height * levels[i]);
      final x = i * slot + (slot - bar) / 2;
      paint.color = (i + .5) / levels.length <= progress ? active : inactive;
      canvas.drawRRect(
          RRect.fromRectAndRadius(
              Rect.fromLTWH(x, (size.height - h) / 2, bar, h),
              Radius.circular(bar / 2)),
          paint);
    }
  }

  @override
  bool shouldRepaint(_WavePainter old) =>
      old.progress != progress ||
      old.levels.length != levels.length ||
      old.active != active ||
      old.inactive != inactive;
}
