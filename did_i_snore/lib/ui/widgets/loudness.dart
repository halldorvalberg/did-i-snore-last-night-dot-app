/// Loudness visualizations — the mirrored waveform and the heat strip.
///
/// Ported from the mockup's `components.jsx` (`MirroredWaveform`,
/// `HeatStrip`). Both take a list of RMS peaks in 0..1 (the precomputed
/// `.peaks` sidecar the player/timeline read) and render at any size.
///
/// - [MirroredWaveform]: symmetric audio-editor bars, mirrored around the
///   vertical center. Used in event tiles and the full-screen player.
/// - [HeatStrip]: 1px cells whose alpha encodes loudness — the
///   "night at a glance" ribbon and the compact sparkline option.
///
/// [progress] (0..1) splits played vs unplayed: played bars use the full
/// color, unplayed bars dim. Null = no progress styling (timeline tiles).
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

class MirroredWaveform extends StatelessWidget {
  const MirroredWaveform({
    super.key,
    required this.peaks,
    this.height = 34,
    this.color = AppColors.accent,
    Color? dim,
    this.progress,
    this.gap = 0.42,
    this.minFraction = 0.06,
  }) : dim = dim ?? const Color(0x38A99BF5); // rgba(169,155,245,0.22)

  final List<double> peaks;
  final double height;
  final Color color;
  final Color dim;
  final double? progress;

  /// Inter-bar gap as a fraction of bar width (matches the mockup's
  /// `gap = 0.42` in viewBox units).
  final double gap;

  /// Floor so silent bars still show a sliver (`min = 0.06`).
  final double minFraction;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      width: double.infinity,
      child: CustomPaint(
        painter: _WaveformPainter(
          peaks: peaks,
          color: color,
          dim: dim,
          progress: progress,
          gap: gap,
          minFraction: minFraction,
        ),
      ),
    );
  }
}

class _WaveformPainter extends CustomPainter {
  _WaveformPainter({
    required this.peaks,
    required this.color,
    required this.dim,
    required this.progress,
    required this.gap,
    required this.minFraction,
  });

  final List<double> peaks;
  final Color color;
  final Color dim;
  final double? progress;
  final double gap;
  final double minFraction;

  @override
  void paint(Canvas canvas, Size size) {
    final n = peaks.length;
    if (n == 0) return;
    // Each bar is `1` unit wide + `gap` units of space; scale so the whole
    // run fills the available width (preserveAspectRatio: none).
    final step = size.width / (n + (n - 1) * gap);
    final barW = step;
    final advance = step * (1 + gap);
    final mid = size.height / 2;
    final paint = Paint()..style = PaintingStyle.fill;

    for (var i = 0; i < n; i++) {
      final h = math.max(minFraction, peaks[i]) * (size.height - 2);
      final x = i * advance;
      final played = progress == null || (i / n) <= progress!;
      paint.color = played ? color : dim;
      final r = barW / 2;
      final rect = RRect.fromRectAndRadius(
        Rect.fromLTWH(x, mid - h / 2, barW, h),
        Radius.circular(r),
      );
      canvas.drawRRect(rect, paint);
    }
  }

  @override
  bool shouldRepaint(_WaveformPainter old) =>
      old.progress != progress ||
      old.color != color ||
      !identical(old.peaks, peaks);
}

/// Dot/heat intensity strip — each cell's alpha encodes loudness.
class HeatStrip extends StatelessWidget {
  const HeatStrip({
    super.key,
    required this.peaks,
    this.height = 30,
    this.rgb = const Color(0xFFA99BF5),
    this.progress,
    this.gap = 1.4,
  });

  final List<double> peaks;
  final double height;

  /// Base color whose alpha is modulated per cell.
  final Color rgb;
  final double? progress;
  final double gap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      width: double.infinity,
      child: CustomPaint(
        painter: _HeatPainter(peaks: peaks, rgb: rgb, progress: progress, gap: gap),
      ),
    );
  }
}

class _HeatPainter extends CustomPainter {
  _HeatPainter({
    required this.peaks,
    required this.rgb,
    required this.progress,
    required this.gap,
  });

  final List<double> peaks;
  final Color rgb;
  final double? progress;
  final double gap;

  @override
  void paint(Canvas canvas, Size size) {
    final n = peaks.length;
    if (n == 0) return;
    final step = size.width / (n + (n - 1) * gap / 1);
    final cellW = step;
    final advance = step * (1 + gap);
    final paint = Paint()..style = PaintingStyle.fill;

    for (var i = 0; i < n; i++) {
      final a = 0.12 + 0.88 * peaks[i].clamp(0.0, 1.0);
      final played = progress == null || (i / n) <= progress!;
      final alpha = played ? a : a * 0.3;
      paint.color = rgb.withValues(alpha: alpha.clamp(0.0, 1.0));
      final rect = RRect.fromRectAndRadius(
        Rect.fromLTWH(i * advance, 0, cellW, size.height),
        const Radius.circular(0.4),
      );
      canvas.drawRRect(rect, paint);
    }
  }

  @override
  bool shouldRepaint(_HeatPainter old) =>
      old.progress != progress || !identical(old.peaks, peaks);
}
