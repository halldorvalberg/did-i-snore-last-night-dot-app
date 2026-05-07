/// Drift `events` table — one row per accepted detection event.
///
/// Spec: `docs/IMPLEMENTATION.md` §6.1. The row + audio file are written
/// separately (see §6.2 state machine) so the table carries an explicit
/// `state` column that the recovery sweeps in `lib/janitor/janitor.dart`
/// use to clean up half-written events.
///
/// **Path columns are relative.** `audioPath` and `peaksPath` store paths
/// relative to `getApplicationDocumentsDirectory()`. iOS rebuilds the
/// sandbox UUID on TestFlight reinstall, so an absolute path baked into
/// the DB at write time will not resolve after reinstall. `EventRepo`
/// asserts this on insert; the resolver in the UI layer joins the docs
/// dir at read time.
///
/// **Pre-computed `topLabel`.** Derived from `labelsJson` at the moment
/// the row flips to `state='ready'` and stored on the row so the timeline
/// renderer doesn't have to JSON-parse every tile. A noisy night can hold
/// hundreds of events; per-frame parsing burns CPU on scroll.
library;

import 'package:drift/drift.dart';

/// One row per accepted event. `state` advances `pending` → `ready`; soft
/// deletion sets `deletedAt` (rows are never hard-deleted by the app
/// outside of the pending sweep).
class Events extends Table {
  IntColumn get id => integer().autoIncrement()();

  /// Wall-clock epoch ms when the gate opened (event start). Used to
  /// place the event on the night timeline; indexed.
  IntColumn get startedAt => integer()();

  /// Wall-clock epoch ms when the gate closed (event end).
  IntColumn get endedAt => integer()();

  /// `endedAt - startedAt`, denormalised so the timeline doesn't compute
  /// it per render.
  IntColumn get durationMs => integer()();

  /// Audit field — when the row was inserted. Drives the pending-sweep
  /// 60-second grace window (`createdAt < now - 60s` and still pending →
  /// the encoder crashed mid-flight).
  IntColumn get createdAt => integer()();

  /// Always 1 in v1. The `MigrationStrategy` in `db.dart` will bump this
  /// column when the schema changes; existing rows will be migrated by
  /// the `onUpgrade` hook.
  IntColumn get schemaVersion =>
      integer().withDefault(const Constant(1))();

  /// `'pending'` immediately after insert; `'ready'` once the encoder
  /// has finished writing the file and `EventRepo.markReady` has run.
  /// The pending sweep targets stale `'pending'` rows; the timeline
  /// query filters to `'ready'`.
  TextColumn get state =>
      text().withDefault(const Constant('pending'))();

  /// Curated top label (e.g. `'Snoring'`, `'Other'`) — pre-computed from
  /// `labelsJson` at the moment of `markReady`. Null while the row is
  /// pending. See file-header note on why this column exists.
  TextColumn get topLabel => text().nullable()();

  /// JSON-encoded `Map<String, double>` of curated label → confidence.
  /// Source of truth for the relabel UI; the displayed label uses
  /// `topLabel` first to avoid re-parsing on every render.
  TextColumn get labelsJson => text().nullable()();

  /// Path to the encoded `.opus` file, **relative to**
  /// `getApplicationDocumentsDirectory()`. Canonical layout is
  /// `events/YYYY-MM-DD/<startedAt>.opus`. The DB does NOT store
  /// absolute paths (see file-header note on iOS sandbox UUIDs).
  TextColumn get audioPath => text()();

  /// Path to the pre-computed waveform peaks sidecar, also relative.
  /// Null until `markReady` (Phase 7 writes the peaks file alongside
  /// the encoded audio).
  TextColumn get peaksPath => text().nullable()();

  /// User-facing star toggle. Starred events are exempt from auto-prune
  /// and from quota-under-pressure soft-deletion (Phase 9).
  BoolColumn get starred => boolean().withDefault(const Constant(false))();

  /// User-supplied label override. When set, the UI displays this
  /// instead of `topLabel`. Null clears the override.
  TextColumn get userLabel => text().nullable()();

  /// Soft-delete tombstone. Non-null = the row is hidden from the
  /// timeline. The Phase 9 hard-delete pass eventually removes rows
  /// where `deletedAt < now - hardDeleteAfterDays`.
  IntColumn get deletedAt => integer().nullable()();
}
