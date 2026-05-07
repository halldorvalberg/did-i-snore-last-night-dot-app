/// Recovery sweeps for the Phase 6 state machine.
///
/// Spec: `docs/IMPLEMENTATION.md` §6.2 lines 797–803.
///
/// The DB row and the audio file are written separately. Without the
/// state machine + ordered sweeps we get **orphans** (file, no row) and
/// **dead rows** (row, no file). The three sweeps below cover every
/// surviving failure mode:
///
/// | Failure mode                                   | Caught by      |
/// |------------------------------------------------|----------------|
/// | Encoder crashed before writing `.tmp`          | pending sweep  |
/// | Encoder crashed after `.tmp`, before rename    | pending sweep  |
/// | Renamed to final but `markReady` died          | pending sweep  |
/// | File written, row never inserted (impossible   | orphan sweep   |
/// |   under current API but defended anyway)       |                |
/// | Row in `ready`, file deleted out from under us | missing-file   |
/// |   (user clears app data, OS evicts, etc.)     | sweep          |
///
/// **Order matters:** pending → orphan → missing-file. The runner in
/// [runAll] enforces this. Reasons:
///
/// 1. **Pending first.** If a pending row's file made it to disk
///    (rename succeeded but UPDATE died), the pending sweep deletes
///    BOTH the row AND the file in one atomic action. Running orphan
///    first would catch the file (it has no `state='ready'` row) and
///    delete it — and then the pending sweep would still try to
///    `unlink` it. Idempotent (we guard with `if exists`), but
///    wasteful, and the state-machine-as-truth ordering is clearer.
/// 2. **Orphan second.** With pending rows + their files gone, every
///    file under `events/YYYY-MM-DD/` should now correspond to a
///    `state='ready'` row. Orphan walks the filesystem and removes
///    files with no matching row.
/// 3. **Missing-file last.** The DB → FS direction. If a `state=
///    'ready'` row's file is gone, we soft-delete the row. Last in the
///    order so we don't trip on a row whose file the pending sweep was
///    about to delete (would never happen because pending sweep targets
///    `state='pending'`, but we order conservatively in case the
///    state-machine invariant breaks).
///
/// **Idempotency.** Every sweep is safe to run twice. Pending uses
/// `if (await file.exists())` guards before unlink; orphan does the
/// same; missing-file uses the `deletedAt IS NULL` guard inherited from
/// `EventRepo.softDelete`. Calling [runAll] twice in a row is
/// equivalent to calling it once.
///
/// **Out of scope here (Phase 9):**
/// - Auto-prune unstarred events older than `RetentionCfg.defaultDays`.
/// - Hard-delete tombstoned rows older than `hardDeleteAfterDays`.
/// - Quota-under-pressure (free-disk gate before recording).
/// - Scheduling — WorkManager (Android) / `BGTaskScheduler` (iOS) /
///   app-launch trigger. Phase 6 ships the pure functions; Phase 9
///   wires them.
library;

import 'dart:io';

import 'package:drift/drift.dart';
import 'package:path/path.dart' as p;

import '../config/constants.dart';
import '../data/db.dart';

/// Default pending grace window. Spec §6.2 line 799 — rows still in
/// `pending` past the grace mean the encoder crashed mid-flight; under
/// normal load, encoding finishes well before this. Canonical seconds
/// value lives in [RetentionCfg.pendingGraceSeconds]; this `Duration`
/// form is exposed as a parameter on [sweepPending] so tests can drive
/// the sweep with a shorter window.
const Duration kPendingGrace =
    Duration(seconds: RetentionCfg.pendingGraceSeconds);

/// Pending sweep — DELETE rows where `state='pending' AND createdAt <
/// now - olderThan`. For each deleted row, also `unlink` the file at
/// `<docsDir>/<audioPath>` and `<docsDir>/<audioPath>.tmp` if either
/// exists.
///
/// Returns the number of rows deleted (NOT files unlinked — files are a
/// side effect, the row count is the canonical signal).
///
/// **Idempotent.** If the file is already gone (e.g. a previous run
/// deleted it), the `if exists` guard skips the unlink. If the row is
/// already gone (sweep ran in another isolate), the WHERE clause
/// matches nothing.
///
/// Why hard-delete (not soft) here: a pending row points at a file
/// that may or may not exist; the user has not seen this event yet
/// (it never reached `state='ready'` and the timeline filters
/// pending). Soft-deleting would leave a dangling row the missing-file
/// sweep would then process — needless churn.
Future<int> sweepPending(
  AppDb db,
  Directory docsDir, {
  Duration olderThan = kPendingGrace,
}) async {
  final cutoff = DateTime.now().millisecondsSinceEpoch -
      olderThan.inMilliseconds;
  // Read first, then delete: we need `audioPath` to drive the unlink.
  final stale = await (db.select(db.events)
        ..where((e) =>
            e.state.equals('pending') &
            e.createdAt.isSmallerThanValue(cutoff)))
      .get();
  if (stale.isEmpty) return 0;

  for (final row in stale) {
    final audioRel = row.audioPath;
    final finalFile = File(p.join(docsDir.path, audioRel));
    final tmpFile = File(p.join(docsDir.path, '$audioRel${PathsCfg.tmpSuffix}'));
    if (await finalFile.exists()) {
      await finalFile.delete();
    }
    if (await tmpFile.exists()) {
      await tmpFile.delete();
    }
  }

  // One DELETE for the whole batch — cheaper than per-row.
  final ids = stale.map((r) => r.id).toList();
  await (db.delete(db.events)..where((e) => e.id.isIn(ids))).go();
  return ids.length;
}

/// Orphan sweep — walk `<docsDir>/events/YYYY-MM-DD/` and delete any
/// `.opus` or `.tmp` file whose relative path is not the `audioPath`
/// (or `audioPath + .tmp`) of a current row.
///
/// Returns the number of files unlinked.
///
/// **Idempotent.** A second run sees no orphan files and unlinks
/// nothing.
///
/// "Current row" = any row in `events`, regardless of state. Pending
/// rows are paired with files the pending sweep is responsible for; we
/// must not delete those out from under it. The pending sweep runs
/// before orphan in [runAll], but a pending row that is *younger* than
/// `kPendingGrace` survives the pending sweep, and its `.tmp` file
/// would otherwise be classified as an orphan here. The "ANY row"
/// inclusion guards against that.
Future<int> sweepOrphans(AppDb db, Directory docsDir) async {
  final eventsRoot = Directory(p.join(docsDir.path, PathsCfg.eventsDir));
  if (!await eventsRoot.exists()) return 0;

  // Collect every `audioPath` (and its `.tmp` sibling) from the DB.
  // `state` not constrained — see method doc.
  final paths = await db.select(db.events).map((e) => e.audioPath).get();
  final keep = <String>{};
  for (final rel in paths) {
    keep.add(rel);
    keep.add('$rel${PathsCfg.tmpSuffix}');
  }

  var unlinked = 0;
  // List the day partitions; ignore non-directory entries.
  await for (final dayEntry in eventsRoot.list(followLinks: false)) {
    if (dayEntry is! Directory) continue;
    await for (final f
        in dayEntry.list(followLinks: false, recursive: false)) {
      if (f is! File) continue;
      // Compute the relative path (events/YYYY-MM-DD/<file>) the same
      // shape as `audioPath`. `p.relative` handles trailing-slash
      // edge cases.
      final rel = p.relative(f.path, from: docsDir.path);
      // Only consider `.opus` files and `.tmp` siblings — we don't
      // want to nuke peaks files or future sidecars that happen to
      // land in the same partition. Peaks files use a `.peaks`
      // extension and are tracked by the (separate) `peaksPath`
      // column in `markReady`; once Phase 7 lands they'll need their
      // own keep-set in this sweep.
      final ext = p.extension(rel);
      if (ext != PathsCfg.audioExtension && ext != PathsCfg.tmpSuffix) {
        continue;
      }
      if (keep.contains(rel)) continue;
      await f.delete();
      unlinked++;
    }
  }
  return unlinked;
}

/// Missing-file sweep — for rows where `state='ready' AND deletedAt IS
/// NULL` but the file at `audioPath` is gone, set `deletedAt = now`.
///
/// Returns the number of rows soft-deleted.
///
/// **Idempotent.** A second run sees rows that are now `deletedAt !=
/// NULL` and skips them via the WHERE clause.
///
/// Why soft-delete (not hard): the user may have seen the event in the
/// timeline; preserving the row keeps the audit trail intact and lets
/// the UI explain "this event's audio is gone" rather than silently
/// disappearing. The Phase 9 hard-delete pass eventually clears
/// tombstones older than `hardDeleteAfterDays`.
Future<int> sweepMissingFiles(AppDb db, Directory docsDir) async {
  final ready = await (db.select(db.events)
        ..where((e) =>
            e.state.equals('ready') & e.deletedAt.isNull()))
      .get();
  if (ready.isEmpty) return 0;

  final missingIds = <int>[];
  for (final row in ready) {
    final f = File(p.join(docsDir.path, row.audioPath));
    if (!await f.exists()) {
      missingIds.add(row.id);
    }
  }
  if (missingIds.isEmpty) return 0;

  final now = DateTime.now().millisecondsSinceEpoch;
  await (db.update(db.events)
        ..where(
            (e) => e.id.isIn(missingIds) & e.deletedAt.isNull()))
      .write(EventsCompanion(deletedAt: Value(now)));
  return missingIds.length;
}

/// Runs the three sweeps in spec order: pending → orphan → missing-file.
///
/// Returns a record of per-sweep counts. The runner is itself
/// idempotent (each sweep is). Phase 9 wires this onto
/// `WorkManager`/`BGTaskScheduler` and the app-launch hook.
Future<({int pending, int orphan, int missing})> runAll(
  AppDb db,
  Directory docsDir,
) async {
  final pending = await sweepPending(db, docsDir);
  final orphan = await sweepOrphans(db, docsDir);
  final missing = await sweepMissingFiles(db, docsDir);
  return (pending: pending, orphan: orphan, missing: missing);
}
