/// Drift `recording_gaps` table — one row per period the recorder was
/// deaf within an active session.
///
/// Spec: `docs/IMPLEMENTATION.md` §10.2 lines 996–1003 + the Phase 9
/// crash-detection note. Spec snippet omits a primary key; we add `id`
/// because Drift requires one and the timeline UI needs stable identity
/// for `GapTile`s (drag/long-press handlers, re-orders on insert).
///
/// Reasons:
/// - `'interruption'` — `AVAudioSession.interruptionNotification` (call,
///   alarm, Siri).
/// - `'route_change'` — `AVAudioSession.routeChangeNotification` (BT
///   disconnect, headphones unplug).
/// - `'crash'` — detected on app launch when `session_started_at` is set
///   but `last_clean_shutdown_at` is unset.
///
/// Reason values are persisted as plain strings rather than an enum so
/// they survive schema migrations without a value-mapping headache, and
/// so they grep as-is in `debug.log`.
library;

import 'package:drift/drift.dart';

class RecordingGaps extends Table {
  IntColumn get id => integer().autoIncrement()();

  /// Epoch ms when the recorder went deaf.
  IntColumn get startedAt => integer()();

  /// Epoch ms when the recorder resumed (or was given up on, in the
  /// crash case where the gap end is the last heartbeat timestamp).
  IntColumn get endedAt => integer()();

  /// One of `'interruption'`, `'route_change'`, `'crash'`. See
  /// file-header.
  TextColumn get reason => text()();
}
