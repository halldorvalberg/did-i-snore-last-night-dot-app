/// Recovery sweeps + retention passes.
///
/// Spec: `docs/IMPLEMENTATION.md` §6.2 lines 797–803 (state-machine
/// recovery) and §9 lines 910–917 (retention passes). Phase 6 shipped
/// the three state-machine sweeps; Phase 9 adds the two retention
/// passes (hard-delete, auto-prune) and the runner that orchestrates
/// all five.
///
/// The DB row and the audio file are written separately. Without the
/// state machine + ordered sweeps we get **orphans** (file, no row) and
/// **dead rows** (row, no file). The five sweeps below cover every
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
/// | Soft-deleted row tombstone older than          | hard-delete    |
/// |   `RetentionCfg.hardDeleteAfterDays` survives  | sweep          |
/// |   long after its file is reclaim-eligible      |                |
/// | Unstarred ready row older than                 | auto-prune     |
/// |   `RetentionCfg.defaultDays` is past the       | sweep          |
/// |   user's review horizon                        |                |
///
/// **Order matters:** hard-delete → auto-prune → pending → orphan →
/// missing-file. The runner in [runAll] enforces this. Reasons:
///
/// 1. **Hard-delete first.** Tombstones older than
///    `RetentionCfg.hardDeleteAfterDays` exit the system entirely (row
///    + audio file + peaks file). Running this first means the
///    subsequent sweeps see fewer rows and the orphan sweep's keep-set
///    is tighter. It also matters that hard-delete runs *before*
///    auto-prune: hard-delete only targets rows the auto-prune of a
///    previous cycle already tombstoned, so swapping the order would
///    delay reclaim by exactly one cycle without any safety benefit.
/// 2. **Auto-prune second.** Newly-tombstoned rows from this pass
///    won't be hard-deleted until the *next* runAll (their `deletedAt`
///    is now and the cutoff is `now - hardDeleteAfterDays`). The
///    `starred=false` guard is enforced *here* — even quota pressure
///    only takes the auto-prune path's "soft-delete oldest unstarred"
///    behaviour. Starred rows are the user's "this matters" signal and
///    survive every automatic path.
/// 3. **Pending third.** If a pending row's file made it to disk
///    (rename succeeded but UPDATE died), the pending sweep deletes
///    BOTH the row AND the file in one atomic action. Running orphan
///    first would catch the file (it has no `state='ready'` row) and
///    delete it — and then the pending sweep would still try to
///    `unlink` it. Idempotent (we guard with `if exists`), but
///    wasteful, and the state-machine-as-truth ordering is clearer.
/// 4. **Orphan fourth.** With pending rows + their files gone, every
///    file under `events/YYYY-MM-DD/` should now correspond to a
///    `state='ready'` row. Orphan walks the filesystem and removes
///    files with no matching row.
/// 5. **Missing-file last.** The DB → FS direction. If a `state=
///    'ready'` row's file is gone, we soft-delete the row. Last in the
///    order so we don't trip on a row whose file the pending sweep was
///    about to delete (would never happen because pending sweep targets
///    `state='pending'`, but we order conservatively in case the
///    state-machine invariant breaks).
///
/// **Idempotency.** Every sweep is safe to run twice. Pending uses
/// `if (await file.exists())` guards before unlink; orphan does the
/// same; missing-file uses the `deletedAt IS NULL` guard inherited from
/// `EventRepo.softDelete`; hard-delete uses the same guard before
/// unlinking and a single DELETE-by-id batch for the rows; auto-prune
/// uses `deletedAt IS NULL` so a second pass within the same retention
/// cutoff sees no candidates. Calling [runAll] twice in a row is
/// equivalent to calling it once.
///
/// **Phase 9 wiring (this file ships the pure functions):**
/// - `lib/janitor/scheduler.dart` registers the WorkManager periodic
///   on Android and exposes the app-launch + recorder-stop hook for
///   iOS. Both call [runAll].
/// - `lib/janitor/quota.dart` is the quota-under-pressure orchestrator
///   that runs *before* recording starts; it uses the same auto-prune
///   semantics (oldest unstarred first, starred protected) but unlinks
///   the audio file synchronously rather than waiting for the next
///   hard-delete cycle, because we need disk free *now* or recording
///   refuses.
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

/// Default hard-delete window. Tombstones older than this become
/// candidates for [sweepHardDelete]. Lives next to the seconds-form
/// constant in [RetentionCfg] so the unit conversion is in one place.
const Duration kHardDeleteAfter =
    Duration(days: RetentionCfg.hardDeleteAfterDays);

/// Default auto-prune retention window. Unstarred ready rows older than
/// this become candidates for [sweepAutoPrune].
const Duration kAutoPruneRetention =
    Duration(days: RetentionCfg.defaultDays);

/// Pending sweep — DELETE rows where `state='pending' AND createdAt <
/// now - olderThan`. For each deleted row, also `unlink`:
///
/// - `<docsDir>/<audioPath>` (final `.opus`)
/// - `<docsDir>/<audioPath>.tmp` (in-flight encode scratch)
/// - `<docsDir>/<peaksPath>` (peaks sidecar, derived from `audioPath`
///   via `p.setExtension(audioPath, PeaksCfg.peaksExtension)`)
/// - `<docsDir>/<peaksPath>.tmp` (in-flight peaks scratch)
///
/// We derive the peaks path from `audioPath` rather than reading the
/// `peaks_path` column because a pending row never reached `markReady`,
/// so the column is null. The encoder + peaks writer use the canonical
/// `audioRel`-with-swapped-extension shape, so the derivation is
/// guaranteed to match what was on disk.
///
/// Returns the number of rows deleted (NOT files unlinked — files are a
/// side effect, the row count is the canonical signal).
///
/// **Idempotent.** If a file is already gone (e.g. a previous run
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
    final peaksRel =
        p.setExtension(audioRel, PeaksCfg.peaksExtension);
    final candidates = <File>[
      File(p.join(docsDir.path, audioRel)),
      File(p.join(docsDir.path, '$audioRel${PathsCfg.tmpSuffix}')),
      File(p.join(docsDir.path, peaksRel)),
      File(p.join(docsDir.path, '$peaksRel${PathsCfg.tmpSuffix}')),
    ];
    for (final f in candidates) {
      if (await f.exists()) {
        await f.delete();
      }
    }
  }

  // One DELETE for the whole batch — cheaper than per-row.
  final ids = stale.map((r) => r.id).toList();
  await (db.delete(db.events)..where((e) => e.id.isIn(ids))).go();
  return ids.length;
}

/// Orphan sweep — walk `<docsDir>/events/YYYY-MM-DD/` and delete any
/// `.opus`, `.peaks`, or `.tmp` file whose relative path is not paired
/// with a current row.
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
///
/// Keep-set, derived per row from `audioPath` (the canonical anchor;
/// peaks live next to opus with the extension swapped):
///
/// - `<audioPath>`              — final `.opus`
/// - `<audioPath>.tmp`          — encode scratch
/// - `<peaksPath>`              — final `.peaks` (derived via
///   `p.setExtension(audioPath, PeaksCfg.peaksExtension)`)
/// - `<peaksPath>.tmp`          — peaks scratch
///
/// Deriving peaks from `audioPath` rather than reading the
/// `peaks_path` column keeps the keep-set complete even for rows
/// where peaks generation failed (`peaks_path IS NULL`) — we still
/// don't want to nuke a stale `.peaks` file the orphan sweep can't
/// distinguish from a real one.
Future<int> sweepOrphans(AppDb db, Directory docsDir) async {
  final eventsRoot = Directory(p.join(docsDir.path, PathsCfg.eventsDir));
  if (!await eventsRoot.exists()) return 0;

  // Collect every `audioPath` (and its `.tmp` sibling) plus the
  // derived peaks paths from the DB. `state` not constrained — see
  // method doc.
  final paths = await db.select(db.events).map((e) => e.audioPath).get();
  final keep = <String>{};
  for (final rel in paths) {
    keep.add(rel);
    keep.add('$rel${PathsCfg.tmpSuffix}');
    final peaksRel = p.setExtension(rel, PeaksCfg.peaksExtension);
    keep.add(peaksRel);
    keep.add('$peaksRel${PathsCfg.tmpSuffix}');
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
      // Only consider files this sweep owns: `.opus`, `.peaks`, and
      // `.tmp` siblings. Anything else (future sidecars we don't
      // know about, user-dropped files) is left alone.
      final ext = p.extension(rel);
      if (ext != PathsCfg.audioExtension &&
          ext != PeaksCfg.peaksExtension &&
          ext != PathsCfg.tmpSuffix) {
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

/// Hard-delete sweep — removes rows whose `deletedAt` tombstone is
/// older than `olderThan`, along with their on-disk audio + peaks
/// files. Spec §9 line 914.
///
/// Targets `deletedAt IS NOT NULL AND deletedAt < now - olderThan`. For
/// each row, unlinks (defensively, with `if exists` guards):
///
/// - `<docsDir>/<audioPath>` — final `.opus`
/// - `<docsDir>/<audioPath>.tmp` — encode scratch (defensive: the
///   pending sweep should already have cleaned these, but a soft-
///   deleted row whose file later went missing could in principle
///   leave one behind)
/// - `<docsDir>/<peaksPath>` — peaks sidecar. Derived from `audioPath`
///   when `peaksPath` is null (which is normal for tombstoned rows
///   that came from a failed peaks-write — see Phase 7's `peaks_failed`
///   path).
/// - `<docsDir>/<peaksPath>.tmp` — peaks scratch (defensive)
///
/// Returns the number of rows deleted.
///
/// **Idempotent.** The WHERE clause matches nothing on the second pass
/// because the rows are gone; `if exists` guards make the file unlinks
/// safe to re-run.
///
/// **Why deriving peaks from audioPath here, even though the row has a
/// `peaksPath` column:** the stored column may be null for two reasons
/// — (a) the encoder ran in pre-Phase-7 builds that didn't write peaks,
/// or (b) the Phase 7 peaks writer failed and the row was marked ready
/// with `peaksPath=null`. In case (b) there could still be a partial
/// `.peaks` or `.peaks.tmp` on disk. Deriving the path from `audioPath`
/// makes the unlink side total over both cases. When the column IS
/// non-null, the derived path matches it exactly (peaks are written
/// next to the audio with the extension swapped) so we don't need both.
Future<int> sweepHardDelete(
  AppDb db,
  Directory docsDir, {
  Duration olderThan = kHardDeleteAfter,
}) async {
  final cutoff = DateTime.now().millisecondsSinceEpoch -
      olderThan.inMilliseconds;
  final stale = await (db.select(db.events)
        ..where((e) =>
            e.deletedAt.isNotNull() &
            e.deletedAt.isSmallerThanValue(cutoff)))
      .get();
  if (stale.isEmpty) return 0;

  for (final row in stale) {
    final audioRel = row.audioPath;
    final peaksRel =
        p.setExtension(audioRel, PeaksCfg.peaksExtension);
    final candidates = <File>[
      File(p.join(docsDir.path, audioRel)),
      File(p.join(docsDir.path, '$audioRel${PathsCfg.tmpSuffix}')),
      File(p.join(docsDir.path, peaksRel)),
      File(p.join(docsDir.path, '$peaksRel${PathsCfg.tmpSuffix}')),
    ];
    for (final f in candidates) {
      if (await f.exists()) {
        await f.delete();
      }
    }
  }

  final ids = stale.map((r) => r.id).toList();
  await (db.delete(db.events)..where((e) => e.id.isIn(ids))).go();
  return ids.length;
}

/// Auto-prune sweep — soft-deletes unstarred `state='ready'` rows whose
/// `startedAt` is older than `retention`. Spec §9 line 915.
///
/// Sets `deletedAt = now`; the file stays on disk until the next
/// hard-delete pass clears it. The two-step (auto-prune → hard-delete
/// on a later cycle) gives the user a one-cycle grace to recover via
/// "undelete" if they spot the loss; once the tombstone is past
/// `RetentionCfg.hardDeleteAfterDays`, the file is reclaimed.
///
/// Returns the number of rows soft-deleted.
///
/// **Idempotent.** Already-tombstoned rows are skipped via the
/// `deletedAt IS NULL` guard. A second pass within the same retention
/// cutoff has nothing left to match.
///
/// **Starred protection — non-negotiable.** The WHERE clause is
/// `starred = false`. Starred events are the user's "this matters"
/// signal and survive every automatic path, including the quota-under-
/// pressure orchestrator (which calls into this same protection — see
/// `lib/janitor/quota.dart`). The `(starred, started_at)` composite
/// index in `db.dart` was created for this query; its leading `starred`
/// column lets SQLite skip the starred half of the table entirely.
Future<int> sweepAutoPrune(
  AppDb db, {
  Duration retention = kAutoPruneRetention,
}) async {
  final cutoff = DateTime.now().millisecondsSinceEpoch -
      retention.inMilliseconds;
  final now = DateTime.now().millisecondsSinceEpoch;
  // Starred protection lives in the WHERE clause — see method doc.
  final updated = await (db.update(db.events)
        ..where((e) =>
            e.state.equals('ready') &
            e.starred.equals(false) &
            e.deletedAt.isNull() &
            e.startedAt.isSmallerThanValue(cutoff)))
      .write(EventsCompanion(deletedAt: Value(now)));
  return updated;
}

/// Result of a [runAll] cycle — counts per sweep, in spec order.
typedef JanitorRunResult = ({
  int hardDeleted,
  int autoPruned,
  int pending,
  int orphan,
  int missing,
});

/// Runs the five sweeps in spec order: hard-delete → auto-prune →
/// pending → orphan → missing-file. Spec §9 lines 912–917.
///
/// Returns a record of per-sweep counts. The runner is itself
/// idempotent (each sweep is). `lib/janitor/scheduler.dart` wires this
/// onto WorkManager (Android) and the app-launch + recorder-stop hook
/// (iOS).
Future<JanitorRunResult> runAll(
  AppDb db,
  Directory docsDir,
) async {
  final hardDeleted = await sweepHardDelete(db, docsDir);
  final autoPruned = await sweepAutoPrune(db);
  final pending = await sweepPending(db, docsDir);
  final orphan = await sweepOrphans(db, docsDir);
  final missing = await sweepMissingFiles(db, docsDir);
  return (
    hardDeleted: hardDeleted,
    autoPruned: autoPruned,
    pending: pending,
    orphan: orphan,
    missing: missing,
  );
}
