/// Day-boundary policy. Spec: `docs/IMPLEMENTATION.md` §8 line 904.
///
/// A recording session belongs to exactly one "night" — the local-day
/// date its `startedAt` falls under. A session that started at 23:55
/// and ran past midnight is filed under 23:55's date; the events from
/// the post-midnight tail are too. The 06:00-nap edge case is called
/// out in spec line 906 and accepted: naps and the previous overnight
/// session co-mingle under one date. Fine for v1.
///
/// **This is the SINGLE source of truth.** Every screen that groups by
/// night must call into here. Inline `DateTime(dt.year, dt.month, dt.day)`
/// constructions in widgets are forbidden — spec-reviewer fails on
/// duplicate implementations of this policy. If you need a variant
/// (e.g. nap-vs-overnight separation in v2), extend this file rather
/// than fork the helper.
///
/// **Pure functions, no Flutter, no Riverpod.** Easy to unit-test, and
/// usable from non-UI code (the janitor's per-night sweep can join the
/// same partition string the timeline does without a UI dep).
library;

import '../../data/db.dart' show Event;

/// Returns the local-time date `DateTime(year, month, day)` for the
/// night this event belongs to. The returned value has hour, minute,
/// second, and millisecond zeroed; it's safe to use as a `family` key
/// for `eventsForNightProvider` (Riverpod's identity-based memoisation
/// matches on equality).
DateTime nightOf(Event e) => nightOfMs(e.startedAt);

/// Variant for a raw epoch-ms timestamp. The home screen's "view last
/// night" tile uses this when there's no `Event` row to pass — `now =
/// DateTime.now()` becomes "today's date" via the same midnight-floor
/// policy.
DateTime nightOfMs(int startedAtMs) {
  final dt = DateTime.fromMillisecondsSinceEpoch(startedAtMs);
  return DateTime(dt.year, dt.month, dt.day);
}
