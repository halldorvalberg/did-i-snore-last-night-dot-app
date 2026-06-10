/// Per-night aggregation used by the Manage Storage screen.
///
/// Spec: `docs/IMPLEMENTATION.md` §9 lines 929–934. The screen lists
/// "Total used + breakdown by date" with a per-section "Delete all
/// unstarred" action; that breakdown is one [NightSummary] per night.
///
/// **Pure data, no Flutter, no Riverpod, no `dart:io`.** The summary is
/// produced from a snapshot of `Event` rows + a `bytesFor(Event)`
/// callback so tests can drive it deterministically. The screen wires
/// the callback to a `path_provider`-backed file-size lookup; the
/// helper itself never touches the filesystem.
///
/// **Day-boundary policy: `nightOf(Event)` is the single source.** Spec
/// line 904 calls it out explicitly. Inline `DateTime(year, month,
/// day)` constructions on `startedAt` are forbidden — spec-reviewer
/// fails on duplicate day-boundary logic. This helper threads the row
/// through `nightOf`; v2's nap-vs-overnight separation lands in
/// `night_of.dart`, not here.
library;

import '../../data/db.dart' show Event;
import '../timeline/night_of.dart';

/// One night's roll-up. The screen renders one card per summary, sorted
/// newest-first by [night].
class NightSummary {
  /// Local-day midnight-floor (`nightOf` output). Used as the key for
  /// the section header and the sort.
  final DateTime night;

  /// Every ready, non-deleted event that fell into this night by
  /// `nightOf`. Ordered by `startedAt DESC` matching
  /// [EventRepo.allReadyEvents].
  final List<Event> events;

  /// Cumulative on-disk bytes for [events] (audio + peaks files
  /// summed). Reported by the screen as "X MB" via the standard format
  /// helpers — never re-derived per render.
  final int totalBytes;

  /// Convenience: count of `event.starred == true` in [events]. The
  /// screen surfaces "X starred / Y unstarred" so the user can predict
  /// what "Delete all unstarred" will free before tapping it.
  final int starredCount;

  /// Convenience: `events.length - starredCount`. Pre-computed so the
  /// screen doesn't re-walk the list on every rebuild.
  final int unstarredCount;

  const NightSummary({
    required this.night,
    required this.events,
    required this.totalBytes,
    required this.starredCount,
    required this.unstarredCount,
  });
}

/// Buckets [events] by `nightOf(Event)` and rolls each bucket up into a
/// [NightSummary]. Returned list is sorted newest-night-first to match
/// the Manage Storage screen's render order.
///
/// `bytesFor` is the per-event on-disk size lookup. The screen's
/// production wiring sums the `.opus` plus the optional `.peaks`
/// sidecar; tests pass a deterministic stub. A null/missing return
/// from `bytesFor` is treated as zero so a missing file doesn't crash
/// the breakdown — the missing-file sweep in
/// `lib/janitor/janitor.dart` will eventually soft-delete the row.
///
/// **Pure function, no async IO.** Callers awaited the file sizes
/// before invoking this so the helper itself stays synchronous +
/// trivially unit-testable.
List<NightSummary> groupByNight(
  List<Event> events,
  int Function(Event) bytesFor,
) {
  final byNight = <DateTime, List<Event>>{};
  for (final e in events) {
    final n = nightOf(e);
    byNight.putIfAbsent(n, () => <Event>[]).add(e);
  }
  final summaries = <NightSummary>[];
  byNight.forEach((night, evs) {
    var total = 0;
    var starred = 0;
    for (final e in evs) {
      total += bytesFor(e);
      if (e.starred) starred++;
    }
    summaries.add(
      NightSummary(
        night: night,
        events: evs,
        totalBytes: total,
        starredCount: starred,
        unstarredCount: evs.length - starred,
      ),
    );
  });
  summaries.sort((a, b) => b.night.compareTo(a.night));
  return summaries;
}
