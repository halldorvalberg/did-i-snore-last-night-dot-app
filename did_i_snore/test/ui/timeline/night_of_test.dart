/// Tests for the day-boundary policy helper.
///
/// Spec: `docs/IMPLEMENTATION.md` §8 line 904. A session belongs to its
/// start-time's local-day date. Crossing midnight does NOT re-bucket
/// the events.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:did_i_snore/ui/timeline/night_of.dart';

void main() {
  group('nightOfMs', () {
    test('floors a timestamp to local-day midnight', () {
      // 2026-05-07 23:55 local time
      final dt = DateTime(2026, 5, 7, 23, 55);
      final night = nightOfMs(dt.millisecondsSinceEpoch);
      expect(night, DateTime(2026, 5, 7));
    });

    test('a 00:30 timestamp belongs to its own (post-midnight) day', () {
      // The cross-midnight policy lives on `nightOf(Event)` — it uses
      // the event's `startedAt`, which is the gate-open time. A row
      // whose own startedAt is 00:30 was a fresh gate-open after
      // midnight; it correctly belongs to the new day. The helper does
      // NOT inspect "did a previous session start yesterday".
      final dt = DateTime(2026, 5, 8, 0, 30);
      final night = nightOfMs(dt.millisecondsSinceEpoch);
      expect(night, DateTime(2026, 5, 8));
    });

    test('returns a value with zeroed time-of-day fields', () {
      final dt = DateTime(2026, 1, 1, 12, 34, 56, 789);
      final night = nightOfMs(dt.millisecondsSinceEpoch);
      expect(night.hour, 0);
      expect(night.minute, 0);
      expect(night.second, 0);
      expect(night.millisecond, 0);
    });
  });
}
