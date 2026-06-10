/// Riverpod wiring shared across UI screens.
///
/// Spec: `docs/IMPLEMENTATION.md` §8 lines 877–908. Three of the four
/// providers listed in the spec live here; the fourth
/// (`recorderControllerProvider`) ships in
/// `lib/recorder/recorder_controller_provider.dart` next to its service
/// dependency.
///
/// **Lifecycle ground rules:**
///
/// - `appDbProvider` is keep-alive (a plain `Provider`, not autoDispose).
///   The DB is a process-singleton: closing it on dispose would tear down
///   the only sqlite handle the recorder, janitor, and timeline all share,
///   so the keep-alive lock is structural — not an optimisation. The
///   `onDispose` close exists for `ProviderScope` overrides in tests
///   where the scope's lifetime IS the DB's lifetime.
/// - `eventRepoProvider` is a thin wrapper around the keep-alive DB.
/// - `docsDirProvider` is a `FutureProvider` so the path resolves once
///   per process and every screen joins against the same root.
/// - `yamnetProvider` lazy-loads the int8-quantized TFLite model. The
///   4.1 MB asset parses in <1 s on a Nothing Phone 3a, but UI callers
///   should still surface a spinner when this provider's `AsyncValue`
///   is `loading` because the first record-button tap waits on it.
///
/// **`gapsForNightProvider`** streams `recording_gaps` for the night via
/// `EventRepo.gapsForNightStream` — rows inserted by native interruption
/// detection (`reason='interruption'`) and crash detection
/// (`reason='crash'`). The timeline interleaves them with events.
///
/// **No telemetry, no analytics, no crash reporters.** Spec line 902 —
/// if a future dep tries to add one, refuse it.
library;

import 'dart:io';

import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../classifier/yamnet.dart';
import '../config/constants.dart';
import '../data/db.dart';
import '../data/event_repo.dart';
import '../janitor/quota.dart' as quota;
import 'manage_storage/night_summary.dart';

/// Process-singleton `AppDb`. One instance per `ProviderScope`; in
/// production the scope IS the process (root `ProviderScope` in
/// `main.dart` lives for the whole app lifetime).
///
/// `onDispose(db.close)` is structurally a no-op in production — the
/// scope never tears down — but matters in tests that build a fresh
/// `ProviderScope` per group: closing the DB on scope tear-down lets
/// the next test open a fresh in-memory database without leaking the
/// previous handle.
final appDbProvider = Provider<AppDb>((ref) {
  final db = AppDb();
  ref.onDispose(db.close);
  return db;
});

/// Repository over the singleton DB. Stateless wrapper; one instance
/// shared by every screen that watches it.
final eventRepoProvider = Provider<EventRepo>(
  (ref) => EventRepo(ref.watch(appDbProvider)),
);

/// Application documents directory. Memoised — the recorder controller
/// and the encode queue both need it, and resolving twice is harmless
/// but wasteful.
final docsDirProvider = FutureProvider<Directory>(
  (_) => getApplicationDocumentsDirectory(),
);

/// YAMNet classifier. Loaded lazily on first watch; the model is parsed
/// off the asset bundle (cold start ~1 s on the reference device). The
/// recorder controller awaits this before calling `RecorderService.start`,
/// so the home screen's record button shows a spinner during this load.
///
/// `onDispose(y.close)` releases the native interpreter when the
/// `ProviderScope` tears down — only meaningful in tests where the
/// scope's lifetime is bounded.
final yamnetProvider = FutureProvider<Yamnet>((ref) async {
  final y = Yamnet();
  await y.load();
  ref.onDispose(y.close);
  return y;
});

/// Live stream of the night's events. Wraps
/// `EventRepo.eventsForNightStream`, which filters
/// `state='ready' AND deletedAt IS NULL` and applies the local-day
/// window. Spec §8 lines 882, 904.
///
/// The `family` argument is the `night` `DateTime`. Two screens watching
/// the same night share one underlying Drift `watch()` because Riverpod
/// memoises by argument equality (and `DateTime` is value-equal).
final eventsForNightProvider =
    StreamProvider.family<List<Event>, DateTime>((ref, night) {
  return ref.watch(eventRepoProvider).eventsForNightStream(night);
});

/// Free-disk byte count for a directory. Spec §9 line 921. Phase 9
/// resolves this via `lib/janitor/quota.dart`'s `defaultFreeBytes`,
/// which uses `df -k` under the hood (POSIX-portable, dep-free).
///
/// Family-keyed by directory because the Manage Storage screen passes
/// a resolved `docsDir` and the recorder controller pulls the future
/// off `docsDirProvider`; sharing one cache keeps the bytes stat from
/// being run twice on the same screen build.
final freeBytesProvider = FutureProvider.family<int, Directory>(
  (ref, dir) => quota.defaultFreeBytes(dir),
);

/// Quota result — the gate the recorder controller checks before
/// `start()` is allowed to proceed, and the source of the home
/// screen's "Recording disabled" banner. Spec §9 lines 919–927.
///
/// Read-only mirror: this provider never prunes. The destructive
/// `quota.checkQuota` (which can soft-delete + unlink files) is only
/// called from `RecorderController.start()` at the moment the user
/// taps record. The banner instead reads the current free disk and
/// asks "would we be able to record right now without pruning?".
///
/// **Idle state.** Returns `canRecord=true` whenever free disk is
/// already above threshold OR the user has unstarred events the
/// recorder *would* prune. Returns `canRecord=false` only in the
/// terminal "below threshold and only starred remain" state, which
/// is exactly the condition the Manage Storage banner needs to
/// surface.
///
/// Use `ref.invalidate(quotaResultProvider)` after Manage Storage
/// actions (bulk-delete, unstar) so the banner refreshes immediately.
final quotaResultProvider = FutureProvider<quota.QuotaResult>((ref) async {
  final db = ref.watch(appDbProvider);
  final docsDir = await ref.watch(docsDirProvider.future);
  final freeBytes = await ref.watch(freeBytesProvider(docsDir).future);
  final thresholdBytes = RetentionCfg.minFreeDiskMb * 1024 * 1024;
  if (freeBytes >= thresholdBytes) {
    return quota.QuotaResult.allow(freeBytes ~/ (1024 * 1024));
  }
  // Below threshold — would the recorder be able to free enough by
  // pruning unstarred? The banner is "informational" so we don't run
  // the destructive prune here; we just check whether any unstarred
  // ready row exists. If yes, surface "low storage but recoverable";
  // if no, surface the terminal "only starred remain" state.
  final unstarred = await (db.select(db.events)
        ..where((e) =>
            e.state.equals('ready') &
            e.starred.equals(false) &
            e.deletedAt.isNull())
        ..limit(1))
      .get();
  final hasUnstarred = unstarred.isNotEmpty;
  return quota.QuotaResult(
    canRecord: hasUnstarred,
    freeMb: freeBytes ~/ (1024 * 1024),
    prunedCount: 0,
    blockReason: hasUnstarred
        ? null
        : 'Low storage and only starred events remain. '
            'Free space in Manage Storage to continue.',
  );
});

/// Manage Storage screen's full snapshot. One async fetch composes the
/// numbers the screen renders:
///
/// - Total bytes used by `events/` (sum across every ready, non-
///   deleted row's `.opus` + optional `.peaks` files).
/// - Free bytes on the docs-dir volume.
/// - Per-night breakdown ([NightSummary]s) sorted newest-first.
/// - Flat list of starred events for the star-management section.
///
/// Spec §9 lines 929–935.
///
/// Why a `FutureProvider` (not a `StreamProvider`): the screen is
/// snapshot-driven. Bulk-delete + undo invalidate this provider
/// explicitly to refresh the view; a live stream would emit mid-loop
/// while the user is staring at the confirmation dialog and rebuild
/// the list under their finger.
///
/// **Caller responsibility — invalidate after any mutation.** The
/// Manage Storage screen `ref.invalidate(manageStorageStateProvider)`
/// after every `softDelete` / `undelete` / `setStarred` so the next
/// build sees the updated counts.
class ManageStorageSnapshot {
  final int totalUsedBytes;
  final int freeBytes;
  final List<NightSummary> nights;
  final List<Event> starredEvents;
  const ManageStorageSnapshot({
    required this.totalUsedBytes,
    required this.freeBytes,
    required this.nights,
    required this.starredEvents,
  });
}

final manageStorageStateProvider =
    FutureProvider<ManageStorageSnapshot>((ref) async {
  final repo = ref.watch(eventRepoProvider);
  final docsDir = await ref.watch(docsDirProvider.future);
  final events = await repo.allReadyEvents();

  // Resolve on-disk bytes for every event up-front (one stat per file).
  // Storing the result in a `Map<int, int>` keyed by event id keeps the
  // sync `groupByNight` pure — it just looks up the precomputed size.
  final sizes = <int, int>{};
  var totalUsed = 0;
  for (final e in events) {
    final audioSize = await _safeFileSize(p.join(docsDir.path, e.audioPath));
    final peaksSize = e.peaksPath == null
        ? 0
        : await _safeFileSize(p.join(docsDir.path, e.peaksPath!));
    final rowSize = audioSize + peaksSize;
    sizes[e.id] = rowSize;
    totalUsed += rowSize;
  }

  final nights = groupByNight(events, (e) => sizes[e.id] ?? 0);
  final starred = events.where((e) => e.starred).toList(growable: false);
  final freeBytes = await ref.watch(freeBytesProvider(docsDir).future);

  return ManageStorageSnapshot(
    totalUsedBytes: totalUsed,
    freeBytes: freeBytes,
    nights: nights,
    starredEvents: starred,
  );
});

/// `File(path).length()` with "missing → 0" semantics. A missing audio
/// file means the missing-file sweep in `lib/janitor/janitor.dart` is
/// about to soft-delete the row; reporting zero bytes for it lets the
/// screen render in the meantime instead of crashing.
Future<int> _safeFileSize(String absPath) async {
  try {
    final f = File(absPath);
    if (!await f.exists()) return 0;
    return await f.length();
  } catch (_) {
    return 0;
  }
}

/// Threshold (bytes) for the Manage Storage free-disk chip. Mirrors
/// `RetentionCfg.minFreeDiskMb` so the UI shows red when the gate the
/// recorder uses is at-or-below trigger. Centralised here so the chip
/// and the (future) quota gate can never disagree.
int get manageStorageFreeBytesThreshold =>
    RetentionCfg.minFreeDiskMb * 1024 * 1024;

/// Live stream of the night's recording gaps. Spec §8 line 883.
///
/// Wired to `recording_gaps` (Phase 10.2 / Tier 2): rows are inserted by
/// the native interruption path (`reason='interruption'`, via
/// `RecorderService`) and crash detection (`reason='crash'`,
/// `crash_heartbeat.dart`). The timeline interleaves these with events on
/// one axis. `route_change` gaps remain deferred (a Bluetooth route change
/// doesn't silence `AudioRecord` on Android).
final gapsForNightProvider =
    StreamProvider.family<List<RecordingGap>, DateTime>((ref, night) {
  // Phase 10.2 / Tier 2: gaps now come from native interruption events
  // (`reason='interruption'`) and crash detection (`reason='crash'`),
  // surfaced via a Drift `.watch()` over the same
  // `[nightStart, nightStart+24h)` window as `eventsForNightProvider`.
  return ref.watch(eventRepoProvider).gapsForNightStream(night);
});
