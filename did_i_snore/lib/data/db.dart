/// Drift database — `events` + `recording_gaps`, opened against a
/// SQLite file under `getApplicationDocumentsDirectory()`.
///
/// Spec: `docs/IMPLEMENTATION.md` §6.1.
///
/// The DB file lives under the same root as the audio files
/// (`<docs>/db/snore.sqlite`) so relative `audioPath` / `peaksPath`
/// values join cleanly off the same prefix. `events/YYYY-MM-DD/...`
/// audio sits as a sibling.
///
/// Indices created in `onCreate` (post `m.createAll()`):
/// - `events_started_at_idx`     — timeline queries.
/// - `events_state_idx`           — pending sweep.
/// - `events_pruning_idx`         — Phase 9 auto-prune `(starred,
///   started_at)` composite.
/// - `events_deleted_at_idx`      — missing-file sweep + Phase 9 hard
///   delete.
///
/// `MigrationStrategy.onUpgrade` ships a v1→v2 stub (commented). When
/// the next contributor adds a column they uncomment + adapt; without
/// the marker they would spend an hour re-reading Drift docs to
/// remember the migration shape.
library;

import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'events_table.dart';
import 'recording_gaps_table.dart';

part 'db.g.dart';

@DriftDatabase(tables: [Events, RecordingGaps])
class AppDb extends _$AppDb {
  AppDb() : super(_openConnection());

  /// Test-only: open against a caller-supplied executor. Lets the
  /// repo/janitor tests use `NativeDatabase.memory()` without
  /// touching `path_provider`.
  AppDb.forTesting(super.executor);

  @override
  int get schemaVersion => 1;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) async {
          await m.createAll();
          // Indices live next to schema rather than in their own .drift
          // file because we only have four — short of needing the .drift
          // tooling. Keep them aligned with the spec §6.1 list.
          await customStatement(
            'CREATE INDEX IF NOT EXISTS events_started_at_idx '
            'ON events(started_at)',
          );
          await customStatement(
            'CREATE INDEX IF NOT EXISTS events_state_idx '
            'ON events(state)',
          );
          await customStatement(
            'CREATE INDEX IF NOT EXISTS events_pruning_idx '
            'ON events(starred, started_at)',
          );
          await customStatement(
            'CREATE INDEX IF NOT EXISTS events_deleted_at_idx '
            'ON events(deleted_at)',
          );
        },
        onUpgrade: (m, from, to) async {
          // v1 has no upgrades. Template kept here so the next schema
          // change has an obvious place to land. Drift's `Migrator`
          // exposes `addColumn`, `createTable`, `createIndex`, etc.
          //
          // Example for v2:
          // if (from < 2) {
          //   await m.addColumn(events, events.someNewColumn);
          //   await customStatement(
          //     'CREATE INDEX IF NOT EXISTS events_some_new_idx '
          //     'ON events(some_new_column)',
          //   );
          // }
        },
      );
}

/// Opens the SQLite file at `<docs>/db/snore.sqlite`. The directory is
/// created lazily on first open. Uses `createInBackground` so the
/// initial open + migrations run on a background isolate; the main
/// isolate communicates over a port. This keeps the cold-start frame
/// budget intact when the DB grows past a few thousand rows.
LazyDatabase _openConnection() {
  return LazyDatabase(() async {
    final docs = await getApplicationDocumentsDirectory();
    final dbDir = Directory(p.join(docs.path, 'db'));
    if (!await dbDir.exists()) {
      await dbDir.create(recursive: true);
    }
    final file = File(p.join(dbDir.path, 'snore.sqlite'));
    return NativeDatabase.createInBackground(file);
  });
}
