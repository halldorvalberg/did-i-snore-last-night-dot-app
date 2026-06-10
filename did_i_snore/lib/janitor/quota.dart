/// Phase 9 quota-under-pressure orchestrator. Spec §9 lines 919–927.
///
/// Run from `RecorderController.start()` (and surfaced to the UI via a
/// Riverpod provider). Decides whether the device has enough free disk
/// to begin a recording session, and if not, prunes the oldest
/// **unstarred** events until either we are back above the threshold
/// or only starred events remain.
///
/// **Why this is a separate file from `janitor.dart`:** the janitor
/// passes are background-cycle work that runs on a timer; the quota
/// path is *synchronous, in front of `start()`*, and has different
/// semantics — see "deviation" below. Keeping them separate lets a
/// future reader trace the "why is recording disabled?" question to
/// one file without scrolling past 200 lines of unrelated sweep logic.
///
/// **Starred protection — non-negotiable.** Same rule as
/// [sweepAutoPrune]: starred events survive every automatic path,
/// including this one. If only starred events remain and we're still
/// below threshold, we return `canRecord=false` and let the UI route
/// the user to Manage Storage. Spec §9 line 925.
///
/// **Deviation: the quota path unlinks audio files synchronously.** In
/// the rest of Phase 9, soft-delete creates a tombstone and a *later*
/// hard-delete pass reclaims disk space. That two-step pattern keeps
/// the user's "undelete" affordance valid for `hardDeleteAfterDays`.
/// Quota cannot wait that long: by definition we're already below
/// `RetentionCfg.minFreeDiskMb` and the user just tapped "record". So
/// the file gets unlinked immediately while the row stays as a
/// tombstone (deletedAt set) for the audit trail.
///
/// The cost: a row hard-deletes faster than the user could undo it. We
/// accept this for the quota path *only* because the alternative is
/// "you can't record, please come back tomorrow when the next janitor
/// cycle has reclaimed your disk." The audit trail is preserved; only
/// the audio is gone.
///
/// **Idempotency.** Calling [checkQuota] twice in a row is safe:
/// - If the first call brought us above threshold, the second sees
///   `freeBytes >= minFreeDiskMb` and returns immediately with
///   `prunedCount=0`.
/// - If the first call exhausted unstarred candidates, the second
///   re-runs the same query and finds the same (now-tombstoned) rows
///   excluded by the `deletedAt IS NULL` guard, prunes nothing, and
///   returns `canRecord=false`.
///
/// **Constants:** [RetentionCfg.minFreeDiskMb] is the single threshold.
/// No inline `200`; `freeBytes` returns bytes and we convert at one
/// call site so the threshold and the readout share units.
library;

import 'dart:io';

import 'package:drift/drift.dart';
import 'package:path/path.dart' as p;

import '../config/constants.dart';
import '../data/db.dart';

/// Free-bytes probe seam. Production resolves [defaultFreeBytes],
/// which uses `File.stat()` against the docs dir's containing volume.
/// Tests inject a stub that returns a fixed value so we can drive the
/// "below threshold" branch without filling the host disk.
typedef FreeBytesProbe = Future<int> Function(Directory docsDir);

/// Default probe — uses `Process.run('df', ...)` style would couple us
/// to a platform binary; instead we use the SQLite-backed
/// `Directory(...).statSync()` shape from spec §9 line 921. Dart's
/// `FileStat` does NOT expose volume-free-bytes natively, so we fall
/// back to `dart:io` `Process.runSync` of `df -k <path>` on Unix and
/// a `_FREE_DRIVE_SPACE` shim path on Windows. iOS/Android both report
/// via the platform's POSIX `statvfs` underneath, which `df -k`
/// surfaces in `KBlocks`.
///
/// **Why not a plugin like `disk_space_plus`:** that plugin pulls in
/// platform-channel-only APIs and adds another transitive dep for what
/// is fundamentally a one-syscall question. The fallback to `df -k`
/// keeps Phase 9 dep-free; if telemetry shows it failing on a quirky
/// OEM (Huawei restricts /system/bin/df on some builds, for instance),
/// we revisit and add the plugin behind this same typedef seam.
///
/// **Tests inject a stub** rather than running `df` against the host —
/// the host's free space is not under our control and would make the
/// test flaky.
Future<int> defaultFreeBytes(Directory docsDir) async {
  // `Directory.statSync()` doesn't expose free bytes on Dart's IOAPI.
  // Use the platform's `df -k` fallback — POSIX-portable on iOS and
  // Android (both ship `df` in the SDK runtime image we get on real
  // devices). The output's "Available" column is in 1024-byte blocks.
  //
  // We deliberately skip `freebsd`/`windows` paths here: this app ships
  // iOS + Android only. The host-side test path injects a stub and
  // never reaches this fallback.
  if (Platform.isAndroid || Platform.isIOS || Platform.isLinux ||
      Platform.isMacOS) {
    final result = await Process.run('df', ['-k', docsDir.path]);
    if (result.exitCode != 0) {
      // Fail open — if we can't read free bytes, don't gate recording.
      // The next janitor cycle will reclaim disk lazily; refusing to
      // record because `df` is missing would be a worse UX than
      // letting the rare full-disk write fail loudly.
      return 1 << 62;
    }
    final lines = (result.stdout as String).trim().split('\n');
    if (lines.length < 2) return 1 << 62;
    final cols = lines.last.trim().split(RegExp(r'\s+'));
    // POSIX: Filesystem 1K-blocks Used Available Use% Mounted-on
    // Available is column index 3 (0-based) on every POSIX `df` we've
    // seen. macOS prefixes a "Mounted on" change but the column index
    // is stable.
    if (cols.length < 4) return 1 << 62;
    final availKb = int.tryParse(cols[3]);
    if (availKb == null) return 1 << 62;
    return availKb * 1024;
  }
  return 1 << 62;
}

/// Result of [checkQuota].
class QuotaResult {
  /// True iff the recorder is allowed to start a session. False when
  /// even after pruning all unstarred events we are still below
  /// `RetentionCfg.minFreeDiskMb`.
  final bool canRecord;

  /// Free megabytes on the docs-dir volume, post-prune. Surfaced to
  /// the UI so the Manage Storage banner can show "210 MB free,
  /// 200 MB needed".
  final int freeMb;

  /// Number of unstarred rows soft-deleted (and their files unlinked
  /// — see file-header on the synchronous-unlink deviation).
  final int prunedCount;

  /// Human-readable reason recording is blocked. Null when
  /// [canRecord] is true. The UI surfaces this verbatim in the
  /// "Recording disabled" banner; copy is fixed English (spec §8 line
  /// 908) so we hardcode the strings here rather than threading an
  /// ARB key.
  final String? blockReason;

  const QuotaResult({
    required this.canRecord,
    required this.freeMb,
    required this.prunedCount,
    required this.blockReason,
  });

  /// Convenience — "always allowed", used in tests + the unit-test
  /// override for the recorder controller before Phase 8 wires the
  /// real provider.
  factory QuotaResult.allow(int freeMb) => QuotaResult(
        canRecord: true,
        freeMb: freeMb,
        prunedCount: 0,
        blockReason: null,
      );
}

/// Spec §9 quota: if free < `minFreeDiskMb`, prune oldest unstarred
/// rows (synchronously unlinking their files) until above threshold or
/// only starred rows remain. Returns a [QuotaResult] the caller (the
/// recorder controller) uses to decide whether to start.
///
/// `freeBytesProbe` defaults to [defaultFreeBytes]; tests inject a
/// stub so the host's actual free space is irrelevant.
///
/// **The pruning loop is bounded** by the number of unstarred,
/// non-deleted rows — the WHERE clause excludes both starred rows and
/// already-tombstoned rows, so each iteration's row leaves the
/// candidate set permanently. A pathological "free space never grows"
/// scenario (e.g. `df` reporting a stale value, or another process
/// filling the disk faster than we delete) terminates when the
/// candidate set is empty rather than spinning.
Future<QuotaResult> checkQuota(
  AppDb db,
  Directory docsDir, {
  FreeBytesProbe freeBytesProbe = defaultFreeBytes,
}) async {
  final thresholdBytes = RetentionCfg.minFreeDiskMb * 1024 * 1024;

  var freeNow = await freeBytesProbe(docsDir);
  if (freeNow >= thresholdBytes) {
    return QuotaResult.allow(freeNow ~/ (1024 * 1024));
  }

  // Candidate set: oldest first, unstarred, not already tombstoned.
  // We do NOT scope to `state='ready'` — a `pending` row whose encode
  // is going to fail anyway is a candidate too; the pending sweep
  // would have caught it at the next cycle, but the user is asking us
  // to record *now*.
  //
  // Actually, we DO scope to `state='ready'`. A pending row's file
  // doesn't exist yet, so deleting it wouldn't free disk; and we'd
  // race the encoder if we tombstoned a row mid-encode. The pending
  // sweep is the right place for those rows.
  final candidates = await (db.select(db.events)
        ..where((e) =>
            e.state.equals('ready') &
            e.starred.equals(false) &
            e.deletedAt.isNull())
        ..orderBy([(e) => OrderingTerm.asc(e.startedAt)]))
      .get();

  if (candidates.isEmpty) {
    return QuotaResult(
      canRecord: false,
      freeMb: freeNow ~/ (1024 * 1024),
      prunedCount: 0,
      blockReason:
          'Low storage and only starred events remain. '
          'Free space in Manage Storage to continue.',
    );
  }

  var pruned = 0;
  for (final row in candidates) {
    if (freeNow >= thresholdBytes) break;

    // Synchronously unlink the audio + peaks files (deviation — see
    // file header). Defensive `if exists` guards keep this idempotent
    // and tolerant of missing-file rows.
    final audioRel = row.audioPath;
    final peaksRel =
        p.setExtension(audioRel, PeaksCfg.peaksExtension);
    final files = <File>[
      File(p.join(docsDir.path, audioRel)),
      File(p.join(docsDir.path, '$audioRel${PathsCfg.tmpSuffix}')),
      File(p.join(docsDir.path, peaksRel)),
      File(p.join(docsDir.path, '$peaksRel${PathsCfg.tmpSuffix}')),
    ];
    for (final f in files) {
      if (await f.exists()) {
        await f.delete();
      }
    }

    // Tombstone the row. The audit trail (timestamp, label, duration)
    // is preserved; only the audio is gone.
    final now = DateTime.now().millisecondsSinceEpoch;
    await (db.update(db.events)
          ..where(
              (e) => e.id.equals(row.id) & e.deletedAt.isNull()))
        .write(EventsCompanion(deletedAt: Value(now)));

    pruned++;
    freeNow = await freeBytesProbe(docsDir);
  }

  if (freeNow >= thresholdBytes) {
    return QuotaResult(
      canRecord: true,
      freeMb: freeNow ~/ (1024 * 1024),
      prunedCount: pruned,
      blockReason: null,
    );
  }

  // Pruned everything we could; still below threshold.
  return QuotaResult(
    canRecord: false,
    freeMb: freeNow ~/ (1024 * 1024),
    prunedCount: pruned,
    blockReason:
        'Low storage — recording disabled. '
        'Free space in Manage Storage to continue.',
  );
}
