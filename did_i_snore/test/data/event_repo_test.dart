/// Repository tests for `EventRepo`.
///
/// Spec: `docs/IMPLEMENTATION.md` §6 lines 717–818. The repo owns the row
/// half of the `pending` → `ready` state machine; these tests pin the
/// contract details called out in `lib/data/event_repo.dart`'s doc-comments
/// (relative-path enforcement, `markReady` no-match semantics, soft-delete
/// idempotency, the timeline stream's `state='ready' AND deletedAt IS NULL`
/// filter, and the `startedAt ASC` ordering).
///
/// Every test runs against a fresh in-memory `NativeDatabase.memory()` —
/// production `AppDb()` is never invoked, so `path_provider` plugin shims
/// aren't needed.
library;

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:did_i_snore/data/db.dart';
import 'package:did_i_snore/data/event_repo.dart';

void main() {
  late AppDb db;
  late EventRepo repo;

  setUp(() {
    db = AppDb.forTesting(NativeDatabase.memory());
    repo = EventRepo(db);
  });

  tearDown(() async {
    await db.close();
  });

  group('EventRepo.insertPending', () {
    test('returns id; row is visible via getById in state="pending"',
        () async {
      const startedAt = 1714900000000;
      const endedAt = 1714900003000;
      const durationMs = 3000;
      const audioPath = 'events/2026-05-07/1714900000000.opus';

      final id = await repo.insertPending(
        startedAt: startedAt,
        endedAt: endedAt,
        durationMs: durationMs,
        audioPath: audioPath,
      );
      expect(id, greaterThan(0),
          reason: 'autoIncrement id should be assigned by the DB');

      final row = await repo.getById(id);
      expect(row, isNotNull, reason: 'getById should round-trip the insert');
      expect(row!.state, 'pending',
          reason: 'state defaults to pending on fresh insert');
      expect(row.audioPath, audioPath,
          reason: 'audioPath should be stored verbatim — no normalisation');
      expect(row.startedAt, startedAt);
      expect(row.endedAt, endedAt);
      expect(row.durationMs, durationMs);
      expect(row.topLabel, isNull,
          reason: 'pending rows have no topLabel until markReady');
      expect(row.labelsJson, isNull);
      expect(row.peaksPath, isNull);
      expect(row.starred, isFalse,
          reason: 'starred defaults to false on fresh insert');
      expect(row.userLabel, isNull);
      expect(row.deletedAt, isNull);
      expect(row.schemaVersion, 1,
          reason: 'v1 schema is the only version in this build');
    });

    test('rejects absolute audioPath with ArgumentError', () async {
      // POSIX-style absolute path. The host runs Linux/macOS, so this is
      // the only shape we need to defend; spec §6.3's iOS-sandbox-UUID
      // rationale applies on iOS specifically, but the guard runs
      // everywhere.
      expect(
        () => repo.insertPending(
          startedAt: 1,
          endedAt: 2,
          durationMs: 1,
          audioPath: '/abs/path/foo.opus',
        ),
        throwsA(isA<ArgumentError>()),
        reason: 'absolute paths break across iOS TestFlight reinstalls — '
            'the guard must reject them at insert time',
      );
    });
  });

  group('EventRepo.markReady', () {
    test(
        'returns true on a pending row; flips state, populates topLabel + '
        'labelsJson + peaksPath', () async {
      final id = await repo.insertPending(
        startedAt: 1,
        endedAt: 2,
        durationMs: 1,
        audioPath: 'events/2026-05-07/1.opus',
      );

      final labels = {'Snoring': 0.71, 'Other': 0.12};
      final ok = await repo.markReady(
        id: id,
        topLabel: 'Snoring',
        labelsJson: EventRepo.encodeLabels(labels),
        peaksPath: 'events/2026-05-07/1.peaks',
      );
      expect(ok, isTrue,
          reason: 'markReady should report success on a pending row');

      final row = await repo.getById(id);
      expect(row!.state, 'ready');
      expect(row.topLabel, 'Snoring');
      expect(EventRepo.decodeLabels(row.labelsJson), labels);
      expect(row.peaksPath, 'events/2026-05-07/1.peaks');
    });

    test('second markReady on the same row returns false (state is no '
        'longer "pending")', () async {
      final id = await repo.insertPending(
        startedAt: 1,
        endedAt: 2,
        durationMs: 1,
        audioPath: 'events/2026-05-07/1.opus',
      );
      final first = await repo.markReady(
        id: id,
        topLabel: 'Snoring',
        labelsJson: '{}',
        peaksPath: null,
      );
      final second = await repo.markReady(
        id: id,
        topLabel: 'Other',
        labelsJson: '{}',
        peaksPath: null,
      );

      expect(first, isTrue);
      expect(second, isFalse,
          reason: 'WHERE clause requires state="pending" — once flipped, '
              'subsequent markReady calls must be no-ops');

      final row = await repo.getById(id);
      expect(row!.topLabel, 'Snoring',
          reason: 'first markReady should have stuck — second must not '
              'overwrite it');
    });

    test('rejects absolute peaksPath with ArgumentError', () async {
      final id = await repo.insertPending(
        startedAt: 1,
        endedAt: 2,
        durationMs: 1,
        audioPath: 'events/2026-05-07/1.opus',
      );
      expect(
        () => repo.markReady(
          id: id,
          topLabel: 'Snoring',
          labelsJson: '{}',
          peaksPath: '/abs/peaks.bin',
        ),
        throwsA(isA<ArgumentError>()),
        reason: 'peaksPath has the same iOS-sandbox-UUID rationale as '
            'audioPath; both must be relative',
      );
    });

    test('returns false when no row matches the id', () async {
      final ok = await repo.markReady(
        id: 999999,
        topLabel: 'Snoring',
        labelsJson: '{}',
        peaksPath: null,
      );
      expect(ok, isFalse,
          reason: 'no row → updated count is zero → false');
    });
  });

  group('EventRepo.softDelete', () {
    test('first call sets deletedAt; second call is a no-op (timestamp '
        'unchanged)', () async {
      final id = await repo.insertPending(
        startedAt: 1,
        endedAt: 2,
        durationMs: 1,
        audioPath: 'events/2026-05-07/1.opus',
      );

      await repo.softDelete(id);
      final after1 = await repo.getById(id);
      expect(after1!.deletedAt, isNotNull,
          reason: 'first softDelete sets the tombstone');
      final firstTimestamp = after1.deletedAt;

      // Sleep just enough that DateTime.now() returns a strictly later
      // value if a buggy second call were to overwrite the field.
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await repo.softDelete(id);

      final after2 = await repo.getById(id);
      expect(after2!.deletedAt, firstTimestamp,
          reason: 'idempotent: the WHERE clause includes deletedAt IS NULL, '
              'so the second call updates zero rows');
    });
  });

  group('EventRepo.setStarred / setUserLabel', () {
    test('setStarred round-trips true and false', () async {
      final id = await repo.insertPending(
        startedAt: 1,
        endedAt: 2,
        durationMs: 1,
        audioPath: 'events/2026-05-07/1.opus',
      );

      await repo.setStarred(id, true);
      expect((await repo.getById(id))!.starred, isTrue);

      await repo.setStarred(id, false);
      expect((await repo.getById(id))!.starred, isFalse);
    });

    test('setUserLabel sets and clears the override', () async {
      final id = await repo.insertPending(
        startedAt: 1,
        endedAt: 2,
        durationMs: 1,
        audioPath: 'events/2026-05-07/1.opus',
      );

      await repo.setUserLabel(id, 'My snore');
      expect((await repo.getById(id))!.userLabel, 'My snore');

      await repo.setUserLabel(id, null);
      expect((await repo.getById(id))!.userLabel, isNull,
          reason: 'passing null clears the user override');
    });
  });

  group('EventRepo.eventsForNightStream', () {
    /// Inserts a ready event at the given wall-clock start. We can't go
    /// through `markReady` for some of these tests (we need rows in
    /// states the repo's API doesn't expose, e.g. ready+deleted), so we
    /// drop down to a direct `into()` insert here.
    Future<int> insertReady({
      required int startedAt,
      String topLabel = 'Snoring',
      bool deleted = false,
    }) async {
      final companion = EventsCompanion.insert(
        startedAt: startedAt,
        endedAt: startedAt + 1000,
        durationMs: 1000,
        createdAt: startedAt,
        audioPath: 'events/x/$startedAt.opus',
        state: const Value('ready'),
        topLabel: Value(topLabel),
        labelsJson: const Value('{}'),
        deletedAt: deleted ? Value(startedAt + 5000) : const Value.absent(),
      );
      return db.into(db.events).insert(companion);
    }

    test('emits exactly the in-window events, ordered startedAt ASC '
        'regardless of insert order', () async {
      // Pin to local-day so `eventsForNightStream` derives the same
      // window we're inserting against.
      final night = DateTime(2026, 5, 7);
      final dayStart = DateTime(2026, 5, 7).millisecondsSinceEpoch;
      final dayEnd =
          DateTime(2026, 5, 7).add(const Duration(days: 1))
              .millisecondsSinceEpoch;

      // Insert in non-monotonic order so the ASC sort is exercised.
      final lateInWindow = dayStart + 20 * 60 * 60 * 1000; // 20:00
      final earlyInWindow = dayStart + 1 * 60 * 60 * 1000; // 01:00
      await insertReady(startedAt: lateInWindow);
      await insertReady(startedAt: earlyInWindow);

      // Out-of-window — must NOT be emitted.
      await insertReady(startedAt: dayStart - 1);
      await insertReady(startedAt: dayEnd);

      final first = await repo.eventsForNightStream(night).first;
      expect(first.map((e) => e.startedAt).toList(),
          [earlyInWindow, lateInWindow],
          reason: 'window filter excludes the out-of-window rows AND the '
              'stream must be ordered startedAt ASC even though we inserted '
              'the late row first');
    });

    test('excludes pending rows and soft-deleted rows', () async {
      final night = DateTime(2026, 5, 7);
      final dayStart = DateTime(2026, 5, 7).millisecondsSinceEpoch;

      // Pending row in-window — excluded.
      await repo.insertPending(
        startedAt: dayStart + 60_000,
        endedAt: dayStart + 61_000,
        durationMs: 1000,
        audioPath: 'events/2026-05-07/pending.opus',
      );

      // Ready+soft-deleted in-window — excluded.
      await insertReady(startedAt: dayStart + 120_000, deleted: true);

      // Ready, not deleted, in-window — included.
      final keepMs = dayStart + 180_000;
      await insertReady(startedAt: keepMs);

      final first = await repo.eventsForNightStream(night).first;
      expect(first.map((e) => e.startedAt).toList(), [keepMs],
          reason: 'state="ready" AND deletedAt IS NULL filter must drop '
              'pending and soft-deleted rows');
    });
  });

  group('EventRepo.insertGap', () {
    test('inserts a recording_gaps row readable back via the table', () async {
      const startedAt = 1714900000000;
      const endedAt = 1714900015000;

      await repo.insertGap(
        startedAt: startedAt,
        endedAt: endedAt,
        reason: 'interruption',
      );

      final rows = await db.select(db.recordingGaps).get();
      expect(rows, hasLength(1),
          reason: 'insertGap must write exactly one row');
      final row = rows.single;
      expect(row.startedAt, startedAt);
      expect(row.endedAt, endedAt);
      expect(row.reason, 'interruption');
    });

    test('preserves the reason string verbatim (plain-string contract)',
        () async {
      await repo.insertGap(
        startedAt: 100,
        endedAt: 200,
        reason: 'route_change',
      );
      final row = (await db.select(db.recordingGaps).get()).single;
      expect(row.reason, 'route_change',
          reason: 'reason is persisted as-is, no enum mapping');
    });
  });

  group('EventRepo.gapsForNightStream', () {
    test('emits only gaps whose startedAt falls in the night window, '
        'ordered ascending', () async {
      final night = DateTime(2026, 6, 9);
      final dayStart = DateTime(2026, 6, 9).millisecondsSinceEpoch;
      // Two in-window gaps (out of order on insert) + one the day before
      // and one the day after, which must be excluded.
      await repo.insertGap(
          startedAt: dayStart + 5 * 3600000,
          endedAt: dayStart + 5 * 3600000 + 11000,
          reason: 'interruption');
      await repo.insertGap(
          startedAt: dayStart + 1 * 3600000,
          endedAt: dayStart + 1 * 3600000 + 6000,
          reason: 'crash');
      await repo.insertGap(
          startedAt: dayStart - 1000, endedAt: dayStart, reason: 'interruption');
      await repo.insertGap(
          startedAt: dayStart + 24 * 3600000,
          endedAt: dayStart + 24 * 3600000 + 1000,
          reason: 'interruption');

      final gaps = await repo.gapsForNightStream(night).first;
      expect(gaps.map((g) => g.reason), ['crash', 'interruption'],
          reason: 'only the two in-window gaps, ordered by startedAt ASC');
    });
  });

  group('EventRepo.encodeLabels / decodeLabels', () {
    test('round-trips a typical label map', () {
      final input = {'Snoring': 0.71, 'Other': 0.12};
      final json = EventRepo.encodeLabels(input);
      final out = EventRepo.decodeLabels(json);
      expect(out, input,
          reason: 'JSON round-trip must preserve keys and double values');
    });

    test('decodeLabels(null) and decodeLabels("") return an empty map', () {
      expect(EventRepo.decodeLabels(null), isEmpty,
          reason: 'doc says timeline never NPEs on a row with no labels');
      expect(EventRepo.decodeLabels(''), isEmpty,
          reason: 'empty string is treated like null');
    });
  });
}
