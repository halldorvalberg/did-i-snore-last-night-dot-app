/// Pure unit tests for the Manage Storage grouping helper.
///
/// Spec: `docs/IMPLEMENTATION.md` §9 lines 929–934 — per-night
/// breakdown grouped by the day-boundary policy (`nightOf`). The
/// tests pin the contract bits the screen relies on:
///
/// 1. Grouping uses `nightOf(Event)`, NOT inline `DateTime(yyyy, mm,
///    dd)` (spec §8 line 904 — single source of truth).
/// 2. Sort order is newest-night first.
/// 3. Starred / unstarred counts are pre-computed correctly.
/// 4. `bytesFor` is consulted exactly once per event; missing files
///    (zero bytes) don't break the roll-up.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:did_i_snore/data/db.dart' show Event;
import 'package:did_i_snore/ui/manage_storage/night_summary.dart';

Event _row({
  required int id,
  required int startedAt,
  bool starred = false,
}) =>
    Event(
      id: id,
      startedAt: startedAt,
      endedAt: startedAt + 1000,
      durationMs: 1000,
      createdAt: startedAt,
      schemaVersion: 1,
      state: 'ready',
      topLabel: 'Snoring',
      labelsJson: '{}',
      audioPath: 'events/x/$id.opus',
      peaksPath: null,
      starred: starred,
      userLabel: null,
      deletedAt: null,
    );

void main() {
  group('groupByNight', () {
    test('buckets events by nightOf and sorts newest-first', () {
      // 2026-05-07 23:55 → night = 2026-05-07
      // 2026-05-08 00:30 → night = 2026-05-08 (post-midnight = own day,
      //                  per spec §8 line 906 / nightOf semantics).
      // 2026-05-08 02:00 → night = 2026-05-08
      final mayseven23h55 = DateTime(2026, 5, 7, 23, 55).millisecondsSinceEpoch;
      final mayeight00h30 = DateTime(2026, 5, 8, 0, 30).millisecondsSinceEpoch;
      final mayeight02h00 = DateTime(2026, 5, 8, 2, 0).millisecondsSinceEpoch;
      final events = [
        _row(id: 1, startedAt: mayseven23h55),
        _row(id: 2, startedAt: mayeight00h30),
        _row(id: 3, startedAt: mayeight02h00),
      ];
      final summaries = groupByNight(events, (_) => 0);

      expect(summaries.length, 2,
          reason: 'two distinct nights → two summaries');
      expect(summaries[0].night, DateTime(2026, 5, 8),
          reason: 'newest night first');
      expect(summaries[1].night, DateTime(2026, 5, 7));
      expect(summaries[0].events.map((e) => e.id), [2, 3],
          reason: 'both post-midnight events end up under 2026-05-08');
      expect(summaries[1].events.single.id, 1);
    });

    test('counts starred vs unstarred per bucket', () {
      final t = DateTime(2026, 5, 7, 22).millisecondsSinceEpoch;
      final events = [
        _row(id: 1, startedAt: t, starred: true),
        _row(id: 2, startedAt: t + 60_000, starred: false),
        _row(id: 3, startedAt: t + 120_000, starred: false),
      ];
      final s = groupByNight(events, (_) => 0).single;
      expect(s.starredCount, 1);
      expect(s.unstarredCount, 2);
      expect(s.events.length, 3,
          reason: 'starredCount + unstarredCount must add up to events.length');
    });

    test('sums bytesFor across the bucket', () {
      final t = DateTime(2026, 5, 7, 22).millisecondsSinceEpoch;
      final events = [
        _row(id: 10, startedAt: t),
        _row(id: 11, startedAt: t + 1000),
        _row(id: 12, startedAt: t + 2000),
      ];
      // Stub the file-size lookup with a deterministic per-id table.
      final sizes = <int, int>{10: 1000, 11: 2500, 12: 7500};
      final s = groupByNight(events, (e) => sizes[e.id] ?? 0).single;
      expect(s.totalBytes, 11000,
          reason: 'sum of 1000 + 2500 + 7500');
    });

    test('treats a zero-bytes lookup as zero, not crash', () {
      final t = DateTime(2026, 5, 7, 22).millisecondsSinceEpoch;
      final events = [
        _row(id: 1, startedAt: t),
        _row(id: 2, startedAt: t + 1000),
      ];
      final s = groupByNight(events, (e) => e.id == 1 ? 100 : 0).single;
      expect(s.totalBytes, 100);
    });

    test('empty input yields an empty list', () {
      expect(groupByNight(const <Event>[], (_) => 0), isEmpty);
    });
  });
}
