/// Recovery-sweep tests for the Phase 6 state machine.
///
/// Spec: `docs/IMPLEMENTATION.md` §6.2 lines 797–803. The sweeps under test
/// (`sweepPending`, `sweepOrphans`, `sweepMissingFiles`, `runAll`) are pure
/// functions over an `AppDb` and a docs `Directory`; we feed them an
/// in-memory DB plus a `Directory.systemTemp` scratch so each test owns a
/// fresh state.
///
/// Wall-clock waits use real `Future.delayed` against a small `olderThan`
/// override on `sweepPending`. Avoids the FakeAsync ceremony for what is a
/// simple `now - createdAt` check.
library;

import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:did_i_snore/data/db.dart';
import 'package:did_i_snore/data/event_repo.dart';
import 'package:did_i_snore/janitor/janitor.dart';

void main() {
  late AppDb db;
  late EventRepo repo;
  late Directory tempDir;

  setUp(() async {
    db = AppDb.forTesting(NativeDatabase.memory());
    repo = EventRepo(db);
    tempDir = await Directory.systemTemp.createTemp('snore_janitor_test_');
  });

  tearDown(() async {
    await db.close();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  /// Writes a file under `tempDir/<rel>`, creating parent directories.
  Future<File> writeFile(String rel, [List<int> bytes = const [0]]) async {
    final f = File(p.join(tempDir.path, rel));
    await f.parent.create(recursive: true);
    await f.writeAsBytes(bytes);
    return f;
  }

  /// Tiny grace used by sweepPending tests that want the row to qualify
  /// as "stale enough". 50 ms is far below the 60 s production default but
  /// matches what we wait below.
  const tinyGrace = Duration(milliseconds: 50);

  group('sweepPending', () {
    test('older-than-grace pending row + final file: row deleted, file '
        'deleted, count=1', () async {
      const rel = 'events/2026-05-07/123.opus';
      final id = await repo.insertPending(
        startedAt: 1,
        endedAt: 2,
        durationMs: 1,
        audioPath: rel,
      );
      final f = await writeFile(rel);

      // Wait just past the tiny grace so the row qualifies.
      await Future<void>.delayed(const Duration(milliseconds: 60));

      final count = await sweepPending(db, tempDir, olderThan: tinyGrace);
      expect(count, 1, reason: 'one row matched and was deleted');
      expect(await repo.getById(id), isNull,
          reason: 'the row must be hard-deleted (not soft-deleted) per the '
              'docstring on sweepPending');
      expect(await f.exists(), isFalse,
          reason: 'the final-file unlink covers the rename-succeeded-but-'
              'UPDATE-died case');
    });

    test('older-than-grace pending row + .tmp file: both files unlinked',
        () async {
      const rel = 'events/2026-05-07/123.opus';
      await repo.insertPending(
        startedAt: 1,
        endedAt: 2,
        durationMs: 1,
        audioPath: rel,
      );
      // Encoder crashed before rename → only the `.tmp` exists.
      final tmp = await writeFile('$rel.tmp');

      await Future<void>.delayed(const Duration(milliseconds: 60));

      final count = await sweepPending(db, tempDir, olderThan: tinyGrace);
      expect(count, 1);
      expect(await tmp.exists(), isFalse,
          reason: 'sweepPending must unlink the .tmp sibling too');
      // And the final-path unlink should be a no-op rather than throwing.
      expect(await File(p.join(tempDir.path, rel)).exists(), isFalse);
    });

    test(
        'older-than-grace pending row + .peaks + .peaks.tmp: peaks '
        'sidecars are also unlinked', () async {
      // The peaks writer can crash mid-flight just like the opus
      // encoder. A pending row that times out may leave any
      // combination of `.opus`, `.opus.tmp`, `.peaks`, `.peaks.tmp` on
      // disk — sweepPending must clean up all four.
      const rel = 'events/2026-05-07/peaks-cleanup.opus';
      const peaksRel = 'events/2026-05-07/peaks-cleanup.peaks';
      await repo.insertPending(
        startedAt: 1,
        endedAt: 2,
        durationMs: 1,
        audioPath: rel,
      );
      final opus = await writeFile(rel);
      final opusTmp = await writeFile('$rel.tmp');
      final peaks = await writeFile(peaksRel);
      final peaksTmp = await writeFile('$peaksRel.tmp');

      await Future<void>.delayed(const Duration(milliseconds: 60));

      final count = await sweepPending(db, tempDir, olderThan: tinyGrace);
      expect(count, 1);
      expect(await opus.exists(), isFalse);
      expect(await opusTmp.exists(), isFalse);
      expect(await peaks.exists(), isFalse,
          reason: 'sweepPending must derive the peaks path from audioPath '
              'and unlink the .peaks sidecar');
      expect(await peaksTmp.exists(), isFalse,
          reason: 'sweepPending must also unlink the .peaks.tmp scratch');
    });

    test('younger-than-grace pending row survives', () async {
      const rel = 'events/2026-05-07/123.opus';
      final id = await repo.insertPending(
        startedAt: 1,
        endedAt: 2,
        durationMs: 1,
        audioPath: rel,
      );
      final f = await writeFile(rel);

      // Run with the production-default 60 s grace so the freshly inserted
      // row is YOUNGER than the cutoff and survives.
      final count = await sweepPending(db, tempDir);
      expect(count, 0,
          reason: 'row is younger than the 60 s default grace');
      expect(await repo.getById(id), isNotNull,
          reason: 'row must survive a sweep that runs inside the grace');
      expect(await f.exists(), isTrue, reason: 'file must survive too');
    });

    test('pending row with no file is still deleted (idempotent on '
        'missing file)', () async {
      const rel = 'events/2026-05-07/no-file.opus';
      final id = await repo.insertPending(
        startedAt: 1,
        endedAt: 2,
        durationMs: 1,
        audioPath: rel,
      );
      // Deliberately do NOT write the file.

      await Future<void>.delayed(const Duration(milliseconds: 60));

      final count = await sweepPending(db, tempDir, olderThan: tinyGrace);
      expect(count, 1, reason: 'row still deletes even when file is absent');
      expect(await repo.getById(id), isNull);
    });

    test('idempotent: a second run after a successful sweep returns 0',
        () async {
      const rel = 'events/2026-05-07/123.opus';
      await repo.insertPending(
        startedAt: 1,
        endedAt: 2,
        durationMs: 1,
        audioPath: rel,
      );
      final f = await writeFile(rel);

      await Future<void>.delayed(const Duration(milliseconds: 60));

      final first = await sweepPending(db, tempDir, olderThan: tinyGrace);
      expect(first, 1);

      final second = await sweepPending(db, tempDir, olderThan: tinyGrace);
      expect(second, 0,
          reason: 'no rows match → no-op; sweepPending must be idempotent');
      expect(await f.exists(), isFalse);
    });
  });

  group('sweepOrphans', () {
    test('file with no row is unlinked', () async {
      const rel = 'events/2026-05-07/orphan.opus';
      final f = await writeFile(rel);

      final count = await sweepOrphans(db, tempDir);
      expect(count, 1, reason: 'one orphan file under events/ was unlinked');
      expect(await f.exists(), isFalse);
    });

    test('file matched by an existing row is preserved', () async {
      const rel = 'events/2026-05-07/keep.opus';
      await repo.insertPending(
        startedAt: 1,
        endedAt: 2,
        durationMs: 1,
        audioPath: rel,
      );
      final f = await writeFile(rel);

      final count = await sweepOrphans(db, tempDir);
      expect(count, 0);
      expect(await f.exists(), isTrue,
          reason: 'a file matched by a row in any state must NOT be '
              'deleted by the orphan sweep');
    });

    test("a pending row's .tmp file is preserved (the 'ANY state' rule)",
        () async {
      const rel = 'events/2026-05-07/foo.opus';
      // Pending row but the encoder is mid-write → only the `.tmp` exists.
      await repo.insertPending(
        startedAt: 1,
        endedAt: 2,
        durationMs: 1,
        audioPath: rel,
      );
      final tmp = await writeFile('$rel.tmp');

      final count = await sweepOrphans(db, tempDir);
      expect(count, 0,
          reason: "the keep-set includes audioPath + '.tmp', so a younger-"
              "than-grace pending row's tmp must survive");
      expect(await tmp.exists(), isTrue);
    });

    test('unknown-extension files in events/ are left alone', () async {
      // Files with extensions outside the sweep's owned set (`.opus`,
      // `.peaks`, `.tmp`) must not be touched. A user-dropped artifact
      // or a future sidecar this sweep doesn't know about is the
      // canonical case.
      const rel = 'events/2026-05-07/notes.bin';
      final f = await writeFile(rel);

      final count = await sweepOrphans(db, tempDir);
      expect(count, 0);
      expect(await f.exists(), isTrue,
          reason: 'extension filter must spare files outside the .opus / '
              '.peaks / .tmp set');
    });

    test('peaks file matched to a row is preserved', () async {
      // A row's audioPath implies a derived peaksPath via
      // p.setExtension(audioPath, '.peaks'). The keep-set must include
      // both, otherwise every orphan-sweep cycle would nuke every
      // valid peaks sidecar.
      const audioRel = 'events/2026-05-07/keep.opus';
      const peaksRel = 'events/2026-05-07/keep.peaks';
      await repo.insertPending(
        startedAt: 1,
        endedAt: 2,
        durationMs: 1,
        audioPath: audioRel,
      );
      final opus = await writeFile(audioRel);
      final peaks = await writeFile(peaksRel);

      final count = await sweepOrphans(db, tempDir);
      expect(count, 0,
          reason: 'a peaks file paired with a row in any state must NOT '
              'be deleted by the orphan sweep');
      expect(await opus.exists(), isTrue);
      expect(await peaks.exists(), isTrue);
    });

    test('orphan peaks file with no matching row is unlinked', () async {
      // The mirror case: a stray `.peaks` whose row has been gone
      // (orphan after a pending sweep beat the orphan sweep, or
      // anything that left a sidecar dangling) must be unlinked.
      const peaksRel = 'events/2026-05-07/orphan.peaks';
      final f = await writeFile(peaksRel);

      final count = await sweepOrphans(db, tempDir);
      expect(count, 1,
          reason: 'a .peaks file with no matching row in the DB is an '
              'orphan and must be unlinked');
      expect(await f.exists(), isFalse);
    });

    test('orphan peaks .tmp scratch is unlinked', () async {
      // A peaks-writer crash before the rename leaves a `.peaks.tmp`.
      // With no matching row (the pending sweep already tore it down),
      // it's an orphan.
      const peaksTmpRel = 'events/2026-05-07/orphan.peaks.tmp';
      final f = await writeFile(peaksTmpRel);

      final count = await sweepOrphans(db, tempDir);
      expect(count, 1,
          reason: 'a stray .peaks.tmp with no row is an orphan');
      expect(await f.exists(), isFalse);
    });

    test('returns 0 when the events/ directory does not exist', () async {
      // Empty tempDir — no `events/` subdir.
      final count = await sweepOrphans(db, tempDir);
      expect(count, 0,
          reason: 'a fresh install or post-clear-data run has no events '
              'dir; the sweep must short-circuit cleanly');
    });

    test('idempotent: a second run after the orphan was unlinked returns 0',
        () async {
      const rel = 'events/2026-05-07/orphan.opus';
      await writeFile(rel);

      expect(await sweepOrphans(db, tempDir), 1);
      expect(await sweepOrphans(db, tempDir), 0,
          reason: 'no orphans remain → no-op on the second pass');
    });
  });

  group('sweepMissingFiles', () {
    /// Insert a `state='ready'` row by going through the full
    /// pending → markReady path so the test stays close to the production
    /// sequence.
    Future<int> insertReady(String rel) async {
      final id = await repo.insertPending(
        startedAt: 1,
        endedAt: 2,
        durationMs: 1,
        audioPath: rel,
      );
      final ok = await repo.markReady(
        id: id,
        topLabel: 'Snoring',
        labelsJson: '{}',
        peaksPath: null,
      );
      expect(ok, isTrue);
      return id;
    }

    test('ready row whose file is gone is soft-deleted (deletedAt set)',
        () async {
      const rel = 'events/2026-05-07/missing.opus';
      final id = await insertReady(rel);
      // Deliberately do NOT write the file.

      final count = await sweepMissingFiles(db, tempDir);
      expect(count, 1);

      final row = await repo.getById(id);
      expect(row!.deletedAt, isNotNull,
          reason: 'soft-delete preserves the audit trail per docstring');
      expect(row.state, 'ready',
          reason: 'state stays "ready" — the row is just tombstoned');
    });

    test('ready row whose file exists survives', () async {
      const rel = 'events/2026-05-07/present.opus';
      final id = await insertReady(rel);
      await writeFile(rel);

      final count = await sweepMissingFiles(db, tempDir);
      expect(count, 0);
      expect((await repo.getById(id))!.deletedAt, isNull);
    });

    test('pending row is NOT touched (only state="ready" is in scope)',
        () async {
      // A pending row with no file is the pending sweep's problem, not
      // missing-file's. Make sure we don't double-process.
      const rel = 'events/2026-05-07/pending.opus';
      final id = await repo.insertPending(
        startedAt: 1,
        endedAt: 2,
        durationMs: 1,
        audioPath: rel,
      );

      final count = await sweepMissingFiles(db, tempDir);
      expect(count, 0,
          reason: 'pending is out of scope for missing-file sweep');
      expect((await repo.getById(id))!.deletedAt, isNull);
    });

    test('already-soft-deleted row is NOT re-touched (deletedAt unchanged)',
        () async {
      const rel = 'events/2026-05-07/already-deleted.opus';
      final id = await insertReady(rel);
      await repo.softDelete(id);
      final originalDeletedAt = (await repo.getById(id))!.deletedAt;
      expect(originalDeletedAt, isNotNull);

      // Sleep so a buggy re-touch would shift the timestamp forward.
      await Future<void>.delayed(const Duration(milliseconds: 5));

      final count = await sweepMissingFiles(db, tempDir);
      expect(count, 0,
          reason: 'WHERE clause requires deletedAt IS NULL — already-'
              'deleted rows are invisible to this sweep');
      expect((await repo.getById(id))!.deletedAt, originalDeletedAt,
          reason: 'tombstone timestamp must not move on subsequent runs');
    });

    test('idempotent: a second run after the soft-delete returns 0',
        () async {
      const rel = 'events/2026-05-07/missing.opus';
      await insertReady(rel);
      // No file.

      expect(await sweepMissingFiles(db, tempDir), 1);
      expect(await sweepMissingFiles(db, tempDir), 0,
          reason: 'first run set deletedAt; the WHERE clause now skips '
              'this row → no-op');
    });
  });

  group('runAll', () {
    test('exercises all three sweeps in one call; second call is (0,0,0)',
        () async {
      // (a) Pending sweep target: pending row + final file, then age the
      // row past the default grace by rewriting createdAt directly. (We
      // can't pass an `olderThan` override through `runAll`, so we age
      // the row instead — this also documents that runAll uses the
      // production grace.)
      const pendingRel = 'events/2026-05-07/pending.opus';
      final pendingId = await repo.insertPending(
        startedAt: 1,
        endedAt: 2,
        durationMs: 1,
        audioPath: pendingRel,
      );
      await writeFile(pendingRel);
      final agedCreatedAt =
          DateTime.now().millisecondsSinceEpoch - 65 * 1000;
      await (db.update(db.events)
            ..where((e) => e.id.equals(pendingId)))
          .write(EventsCompanion(createdAt: Value(agedCreatedAt)));

      // (b) Orphan target: file with no row.
      const orphanRel = 'events/2026-05-07/orphan.opus';
      final orphanFile = await writeFile(orphanRel);

      // (c) Missing-file target: ready row, no file.
      const missingRel = 'events/2026-05-07/missing.opus';
      final missingId = await repo.insertPending(
        startedAt: 10,
        endedAt: 20,
        durationMs: 10,
        audioPath: missingRel,
      );
      await repo.markReady(
        id: missingId,
        topLabel: 'Snoring',
        labelsJson: '{}',
        peaksPath: null,
      );

      final result = await runAll(db, tempDir);
      expect(result.pending, 1, reason: 'aged pending row + file → 1');
      expect(result.orphan, 1, reason: 'unmatched file → 1');
      expect(result.missing, 1, reason: 'ready row with no file → 1');

      // Side effects materialised:
      expect(await repo.getById(pendingId), isNull,
          reason: 'pending sweep hard-deleted the row');
      expect(await orphanFile.exists(), isFalse,
          reason: 'orphan sweep unlinked the unmatched file');
      expect((await repo.getById(missingId))!.deletedAt, isNotNull,
          reason: 'missing-file sweep tombstoned the ready row');

      // Second runAll — every sweep must be a no-op.
      final second = await runAll(db, tempDir);
      expect(second.pending, 0);
      expect(second.orphan, 0);
      expect(second.missing, 0);
    });

    test('returns (0, 0, 0) on a fresh empty docs dir + empty DB',
        () async {
      final result = await runAll(db, tempDir);
      expect(result.pending, 0);
      expect(result.orphan, 0);
      expect(result.missing, 0);
    });
  });
}
