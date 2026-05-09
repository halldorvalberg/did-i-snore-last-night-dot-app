/// Visible marker for a recording gap interleaved into the timeline.
///
/// Spec: `docs/IMPLEMENTATION.md` §8 line 888 ("`GapTile` between event
/// tiles for interruptions") and §10.2. Renders a muted strip showing
/// the gap's reason, duration, and start–end time range. Pure widget,
/// no state — the timeline screen filters the gaps stream and inserts
/// these between adjacent events at build time.
///
/// **No row interaction.** Tap is a no-op for v1; gaps are diagnostic
/// surface only. If a future feature needs to act on a gap (e.g.
/// "see what was happening then"), promote to an `InkWell` then.
library;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../data/db.dart' show RecordingGap;

class GapTile extends StatelessWidget {
  const GapTile({super.key, required this.gap});

  final RecordingGap gap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final start = DateTime.fromMillisecondsSinceEpoch(gap.startedAt);
    final end = DateTime.fromMillisecondsSinceEpoch(gap.endedAt);
    final formatter = DateFormat.Hm();
    final reasonText = _reasonLabel(gap.reason);
    final durationText = _formatDuration(gap.endedAt - gap.startedAt);

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Row(
        children: [
          Icon(
            Icons.pause_circle_outline,
            size: 18,
            color: scheme.onSurfaceVariant,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Recording paused — $reasonText ($durationText)',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '${formatter.format(start)} – ${formatter.format(end)}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// User-facing copy for each persisted reason. Hardcoded English per
  /// spec line 908.
  static String _reasonLabel(String reason) {
    switch (reason) {
      case 'interruption':
        return 'interruption';
      case 'route_change':
        return 'audio route change';
      case 'crash':
        return 'crash recovered';
      default:
        return reason; // forward-compat: unknown reasons rendered raw.
    }
  }

  static String _formatDuration(int ms) {
    if (ms < 1000) return '$ms ms';
    final seconds = ms ~/ 1000;
    if (seconds < 60) return '${seconds}s';
    final minutes = seconds ~/ 60;
    final remSeconds = seconds % 60;
    if (remSeconds == 0) return '${minutes}m';
    return '${minutes}m ${remSeconds}s';
  }
}
