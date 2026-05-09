/// Display-label rule. Spec: `docs/IMPLEMENTATION.md` §8 lines 893–900.
///
/// Priority: explicit user override → pre-computed top label → `'Other'`.
/// The `top_label` column on the row is populated at `markReady` time
/// (see `lib/data/event_repo.dart::markReady`); widgets must NEVER
/// re-parse `labels_json` on every render.
///
/// Why it matters: a noisy night can hold hundreds of events, and the
/// timeline scroll path runs this function once per visible tile per
/// frame. JSON parsing 521-class confidence maps at 60 Hz on a Nothing
/// Phone 3a is a measurable battery cost. spec-reviewer fails on
/// `jsonDecode` / `EventRepo.decodeLabels` calls in widget code.
///
/// **Pure function, no Flutter, no Riverpod.** Trivially testable and
/// safe to call from any layer (in practice only the UI calls it, but
/// keeping it dep-free means future code never has a reason to
/// duplicate it).
library;

import '../../data/db.dart' show Event;

/// The label the UI should show for this event.
///
/// Single source of truth — every event-rendering widget (event tile,
/// player title, gap-row neighbour-aware copy) calls into here. There
/// is no other place to compute "what does this event call itself."
String displayLabel(Event e) {
  final user = e.userLabel;
  if (user != null) return user;
  return e.topLabel ?? 'Other';
}
