/// Repository over the `events` table.
///
/// Spec: `docs/IMPLEMENTATION.md` §6.2 state machine. The repo owns the
/// row half of `pending` → `ready`; the encoder (Phase 7) owns the
/// `.tmp` file write + atomic rename. The split is enforced by API
/// shape: `markReady` is the only call site that flips state.
///
/// **Sequence (do not reorder):**
///
/// ```
///   1. EventRepo.insertPending(audioPath: "events/YYYY-MM-DD/<ts>.opus")
///      → row is now state='pending', file does not exist.
///   2. Encoder writes "<docs>/events/YYYY-MM-DD/<ts>.opus.tmp".
///   3. Encoder File.rename(...tmp → ...opus).
///   4. EventRepo.markReady(id, ...)
///      → row is state='ready', file exists at audioPath.
/// ```
///
/// If the worker crashes between any two steps, the recovery sweeps in
/// `lib/janitor/janitor.dart` clean up. That's the whole point of the
/// state machine.
///
/// **`writeAudioAtomic` lives in the encoder (Phase 7), not here.** The
/// rename happens between steps 2 and 3 above; this layer only owns the
/// row half.
library;

import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:path/path.dart' as p;

import 'db.dart';

/// Repository over the `events` table. Construct with the singleton
/// `AppDb`; one repo per process is fine, no per-call ownership.
class EventRepo {
  final AppDb _db;

  EventRepo(this._db);

  /// Inserts a new row in `state='pending'`. Returns the new row id.
  ///
  /// `audioPath` MUST be relative to the application documents
  /// directory (e.g. `events/2026-05-07/1714900000000.opus`). Absolute
  /// paths are rejected because iOS rebuilds the sandbox UUID on
  /// TestFlight reinstall (spec §6.3) — anything baked in absolute will
  /// break across reinstalls. The check uses `path.isAbsolute` to catch
  /// both POSIX and Windows-style absolutes (defensive; the app runs on
  /// iOS/Android only, but tests run on the host).
  ///
  /// `createdAt` is captured here (not by the caller) so the audit
  /// column is consistent with `state='pending'`'s 60-second sweep
  /// window — it always reflects insert time, not gate-open time.
  Future<int> insertPending({
    required int startedAt,
    required int endedAt,
    required int durationMs,
    required String audioPath,
  }) async {
    if (p.isAbsolute(audioPath)) {
      throw ArgumentError.value(
        audioPath,
        'audioPath',
        'Must be relative to the application documents directory; got '
            'an absolute path. iOS rebuilds the sandbox UUID on '
            'TestFlight reinstall — absolute paths break.',
      );
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    return _db.into(_db.events).insert(
          EventsCompanion(
            startedAt: Value(startedAt),
            endedAt: Value(endedAt),
            durationMs: Value(durationMs),
            createdAt: Value(now),
            audioPath: Value(audioPath),
            // state defaults to 'pending', schemaVersion to 1, starred
            // to false — let Drift's column defaults apply.
          ),
        );
  }

  /// Flips a row from `state='pending'` to `state='ready'`, populating
  /// the post-encode columns. Called by the encoder *after* the
  /// `.tmp` → final rename succeeds.
  ///
  /// Returns `true` if a row was updated, `false` if no matching row
  /// existed (e.g. the pending sweep already deleted it because the
  /// encoder took longer than the 60-second grace window — in that
  /// case the encoded file is now an orphan and the orphan sweep will
  /// handle it on the next janitor cycle).
  ///
  /// `peaksPath` is null when the encoder skipped peak generation
  /// (e.g. degenerate-short events). The player falls back to
  /// computing peaks on the fly.
  Future<bool> markReady({
    required int id,
    required String topLabel,
    required String labelsJson,
    required String? peaksPath,
  }) async {
    if (peaksPath != null && p.isAbsolute(peaksPath)) {
      throw ArgumentError.value(
        peaksPath,
        'peaksPath',
        'Must be relative to the application documents directory.',
      );
    }
    final updated = await (_db.update(_db.events)
          ..where((e) => e.id.equals(id) & e.state.equals('pending')))
        .write(
      EventsCompanion(
        state: const Value('ready'),
        topLabel: Value(topLabel),
        labelsJson: Value(labelsJson),
        peaksPath: Value(peaksPath),
      ),
    );
    return updated > 0;
  }

  /// Convenience: encode a label map to the JSON string Drift stores in
  /// `labelsJson`. Single source of truth for the encoding so callers
  /// don't roll their own and end up with mismatched key ordering.
  static String encodeLabels(Map<String, double> labels) =>
      jsonEncode(labels);

  /// Inverse of [encodeLabels]. Returns an empty map for null/empty
  /// inputs so the timeline never NPEs on a row that flipped to ready
  /// with no surviving labels.
  static Map<String, double> decodeLabels(String? json) {
    if (json == null || json.isEmpty) return const <String, double>{};
    final decoded = jsonDecode(json) as Map<String, dynamic>;
    return decoded.map((k, v) => MapEntry(k, (v as num).toDouble()));
  }

  /// Live stream of the night's events: `state='ready' AND deletedAt IS
  /// NULL AND startedAt ∈ [nightStart, nightStart + 24h)`, ordered by
  /// `startedAt ASC`.
  ///
  /// Night boundary is the local-day window for `night`. A session that
  /// started at 23:55 belongs to that day; events that crossed midnight
  /// would still bear their original `startedAt`, so we use the local
  /// 00:00 → 24:00 window of `night` itself. Day-boundary policy lives
  /// in spec §8 line 901 and is implemented once in `nightOf` (Phase
  /// 8). This stream is a thin filter that the UI layer composes with
  /// the policy helper.
  Stream<List<Event>> eventsForNightStream(DateTime night) {
    final dayStart = DateTime(night.year, night.month, night.day);
    final dayEnd = dayStart.add(const Duration(days: 1));
    final startMs = dayStart.millisecondsSinceEpoch;
    final endMs = dayEnd.millisecondsSinceEpoch;

    final query = _db.select(_db.events)
      ..where((e) =>
          e.state.equals('ready') &
          e.deletedAt.isNull() &
          e.startedAt.isBiggerOrEqualValue(startMs) &
          e.startedAt.isSmallerThanValue(endMs))
      ..orderBy([(e) => OrderingTerm.asc(e.startedAt)]);
    return query.watch();
  }

  /// Marks a row as soft-deleted. Idempotent — a second call after the
  /// row is already deleted is a no-op (the `deletedAt IS NULL` guard
  /// in the WHERE clause). Hard deletion happens in Phase 9 after the
  /// `hardDeleteAfterDays` retention window.
  Future<void> softDelete(int id) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await (_db.update(_db.events)
          ..where((e) => e.id.equals(id) & e.deletedAt.isNull()))
        .write(EventsCompanion(deletedAt: Value(now)));
  }

  /// Inverse of [softDelete]. Used by the player's undo-snackbar
  /// (Phase 8 spec line 889) to roll back a soft delete that the user
  /// regrets. Idempotent — if the row was never deleted (or has
  /// already been undeleted) this is a no-op.
  ///
  /// **Hard-deletion race.** If Phase 9's `hardDelete` pass already
  /// tore the row down (`deletedAt < now - hardDeleteAfterDays`), the
  /// row no longer exists and this method silently does nothing. The
  /// undo SnackBar's auto-dismiss is ~5 s, well inside the 1-day
  /// `hardDeleteAfterDays` window, so this is theoretical — but the
  /// idempotent shape keeps it safe.
  Future<void> undelete(int id) async {
    await (_db.update(_db.events)
          ..where((e) => e.id.equals(id) & e.deletedAt.isNotNull()))
        .write(const EventsCompanion(deletedAt: Value(null)));
  }

  /// Toggles the star flag. Starred events are exempt from auto-prune
  /// + quota-under-pressure (Phase 9).
  Future<void> setStarred(int id, bool starred) async {
    await (_db.update(_db.events)..where((e) => e.id.equals(id)))
        .write(EventsCompanion(starred: Value(starred)));
  }

  /// Sets a user override label, or clears it when `userLabel` is null.
  Future<void> setUserLabel(int id, String? userLabel) async {
    await (_db.update(_db.events)..where((e) => e.id.equals(id))).write(
      EventsCompanion(userLabel: Value(userLabel)),
    );
  }

  /// Test/diagnostic helper — fetch one row by id, or null. Used by
  /// the janitor sweep tests; the UI layer prefers the streaming API.
  Future<Event?> getById(int id) async {
    return (_db.select(_db.events)..where((e) => e.id.equals(id)))
        .getSingleOrNull();
  }

  /// Fetches every `state='ready' AND deletedAt IS NULL` row, ordered
  /// by `startedAt DESC`. The Manage Storage screen calls this once
  /// per refresh and groups in-memory by `nightOf(Event)` (Phase 8 day
  /// boundary policy). Spec: `docs/IMPLEMENTATION.md` §9 lines 929–938.
  ///
  /// Why a one-shot fetch (not a `watch()`): the screen's bulk-delete
  /// flow already invalidates the provider after every action; a live
  /// stream would emit mid-loop while the user is staring at the
  /// confirmation dialog and rebuild the list under their finger.
  /// Snapshot semantics keep the screen stable for the duration of the
  /// interaction.
  ///
  /// Excludes pending and soft-deleted rows the same way
  /// [eventsForNightStream] does — Manage Storage is reasoning about
  /// what the user *can see and reclaim*, not the state-machine
  /// scratch space.
  Future<List<Event>> allReadyEvents() async {
    return (_db.select(_db.events)
          ..where((e) =>
              e.state.equals('ready') & e.deletedAt.isNull())
          ..orderBy([(e) => OrderingTerm.desc(e.startedAt)]))
        .get();
  }
}
