/// One row in the timeline list.
///
/// Spec: `docs/IMPLEMENTATION.md` §8 line 888 — time, top label,
/// duration, mini RMS sparkline, play button. Tap navigates to the
/// player; long-press surfaces a star/delete menu shortcut.
///
/// **Display label.** Reads `displayLabel(event)` — never decodes
/// `labelsJson`. The `topLabel` column is pre-computed at `markReady`
/// (spec line 902) precisely so this tile doesn't burn CPU on a noisy
/// night with hundreds of rows.
///
/// **Sparkline strategy (v1).** The peaks file is 200 × float32 = 800
/// bytes per event. Loading 800 bytes per visible tile is cheap, but
/// doing it synchronously on first build would block the scroll frame
/// while the OS reads the file. We use a `FutureBuilder` keyed on
/// `peaksPath` so the bar renders flat-grey while the file is in flight,
/// then repaints once peaks are loaded. The peaks aren't cached across
/// tiles — list view recycles widgets, and re-reading 800 bytes on
/// scroll-back is cheaper than maintaining a per-event LRU. If profiling
/// later shows the IO matters, add a small `Map<int, List<double>>`
/// cache keyed by event id at the screen level.
///
/// **No JSON parsing in build paths.** spec-reviewer fails on
/// `jsonDecode` calls in widget files.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../config/constants.dart';
import '../../data/db.dart' show Event;
import 'display_label.dart';

class EventTile extends StatelessWidget {
  const EventTile({
    super.key,
    required this.event,
    required this.docsDir,
    required this.onTap,
    this.onStarToggle,
    this.onDelete,
  });

  final Event event;

  /// Documents directory root. The event's `peaksPath` is stored
  /// relative; the tile joins it here at read time. Passed in by the
  /// timeline screen so it doesn't have to re-resolve once per row.
  final Directory docsDir;

  final VoidCallback onTap;
  final VoidCallback? onStarToggle;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final start = DateTime.fromMillisecondsSinceEpoch(event.startedAt);
    final timeText = DateFormat.Hm().format(start);
    final durationText = _formatDuration(event.durationMs);
    final label = displayLabel(event);

    return InkWell(
      onTap: onTap,
      onLongPress: onStarToggle == null && onDelete == null
          ? null
          : () => _showActions(context),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // Leading: time of event.
            SizedBox(
              width: 56,
              child: Text(
                timeText,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            const SizedBox(width: 12),
            // Main: label + duration + sparkline.
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: theme.textTheme.bodyLarge,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Text(
                        durationText,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: SizedBox(
                          height: 18,
                          child: _Sparkline(
                            peaksAbsPath: event.peaksPath == null
                                ? null
                                : '${docsDir.path}/${event.peaksPath}',
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            if (event.starred)
              Icon(
                Icons.star,
                size: 18,
                color: theme.colorScheme.primary,
              ),
            IconButton(
              icon: const Icon(Icons.play_arrow),
              tooltip: 'Play',
              onPressed: onTap,
            ),
          ],
        ),
      ),
    );
  }

  void _showActions(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (onStarToggle != null)
              ListTile(
                leading: Icon(event.starred ? Icons.star : Icons.star_border),
                title: Text(event.starred ? 'Unstar' : 'Star'),
                onTap: () {
                  Navigator.of(sheet).pop();
                  onStarToggle!();
                },
              ),
            if (onDelete != null)
              ListTile(
                leading: const Icon(Icons.delete_outline),
                title: const Text('Delete'),
                onTap: () {
                  Navigator.of(sheet).pop();
                  onDelete!();
                },
              ),
          ],
        ),
      ),
    );
  }

  static String _formatDuration(int ms) {
    if (ms < 1000) return '$ms ms';
    final seconds = ms / 1000.0;
    if (seconds < 10) return '${seconds.toStringAsFixed(1)} s';
    if (seconds < 60) return '${seconds.toStringAsFixed(0)} s';
    final minutes = seconds ~/ 60;
    final remSeconds = (seconds % 60).round();
    return '${minutes}m ${remSeconds}s';
  }
}

/// Inline sparkline. Loads `peakCount × float32 LE` from disk lazily;
/// renders a flat grey strip while the file is in flight or when no
/// peaks file exists (older events from before Phase 7 retrofit).
class _Sparkline extends StatelessWidget {
  const _Sparkline({required this.peaksAbsPath});

  final String? peaksAbsPath;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary.withValues(alpha: 0.6);
    final base = Theme.of(context).colorScheme.outlineVariant;
    if (peaksAbsPath == null) {
      return CustomPaint(painter: _SparklinePainter(null, color, base));
    }
    return FutureBuilder<List<double>?>(
      future: _readPeaks(peaksAbsPath!),
      builder: (ctx, snap) {
        return CustomPaint(
          painter: _SparklinePainter(snap.data, color, base),
        );
      },
    );
  }

  /// Returns null on any IO error or if the file is unexpectedly short.
  /// The tile stays flat in that case — never an exception bubbling out
  /// to the scroll path.
  static Future<List<double>?> _readPeaks(String absPath) async {
    try {
      final f = File(absPath);
      if (!await f.exists()) return null;
      final bytes = await f.readAsBytes();
      // Spec: peakCount × float32 LE, no header.
      final expectedLen = PeaksCfg.peakCount * 4;
      if (bytes.lengthInBytes < expectedLen) return null;
      final floats = Float32List.view(
        bytes.buffer,
        bytes.offsetInBytes,
        PeaksCfg.peakCount,
      );
      return List<double>.from(floats);
    } catch (_) {
      return null;
    }
  }
}

class _SparklinePainter extends CustomPainter {
  _SparklinePainter(this.peaks, this.color, this.baseColor);

  final List<double>? peaks;
  final Color color;
  final Color baseColor;

  @override
  void paint(Canvas canvas, Size size) {
    if (peaks == null) {
      // Flat baseline.
      final paint = Paint()
        ..color = baseColor
        ..strokeWidth = 1.0;
      final y = size.height / 2;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
      return;
    }
    // Coarse downsample to ~24 visible bars regardless of peakCount.
    const visibleBars = 24;
    final step = (peaks!.length / visibleBars).ceil();
    final paint = Paint()
      ..color = color
      ..strokeWidth = (size.width / visibleBars) * 0.6
      ..strokeCap = StrokeCap.round;
    final centreY = size.height / 2;
    for (var i = 0; i < visibleBars; i++) {
      // Max within this bucket — a sum or mean would smear short
      // transients out of view.
      var maxV = 0.0;
      final start = i * step;
      final end = (start + step).clamp(0, peaks!.length);
      for (var j = start; j < end; j++) {
        if (peaks![j] > maxV) maxV = peaks![j];
      }
      final h = (maxV * size.height).clamp(2.0, size.height);
      final x = (i + 0.5) * (size.width / visibleBars);
      canvas.drawLine(
        Offset(x, centreY - h / 2),
        Offset(x, centreY + h / 2),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _SparklinePainter old) =>
      old.peaks != peaks || old.color != color || old.baseColor != baseColor;
}
