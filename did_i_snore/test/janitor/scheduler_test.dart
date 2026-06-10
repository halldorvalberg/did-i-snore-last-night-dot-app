/// Host-side tests for `lib/janitor/scheduler.dart`.
///
/// The Android WorkManager registration is platform-channel work that
/// can't run in a host-side `flutter test` — that's exercised by the
/// integration suite + manual device runs. What this file covers:
///
/// - `runJanitorOnce` invokes `runAll` exactly once and forwards the
///   per-pass counts to the logger.
/// - `runOnAppLaunch` is the same shape (no Android/iOS gating).
/// - `runOnRecorderStop` is iOS-gated — on the host (Linux/macOS via
///   `Platform.isIOS == false`), it short-circuits and returns
///   without calling `runAll`. We assert by injecting a logger and
///   confirming it was NOT called.
///
/// Errors thrown by `runAll` propagate from `runJanitorOnce`; the
/// recorder-stop hook swallows them and logs `janitor_recorder_stop_failed`.
library;

import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:did_i_snore/data/db.dart';
import 'package:did_i_snore/data/event_repo.dart';
import 'package:did_i_snore/janitor/scheduler.dart';

void main() {
  late AppDb db;
  late EventRepo repo;
  late Directory tempDir;

  setUp(() async {
    db = AppDb.forTesting(NativeDatabase.memory());
    repo = EventRepo(db);
    tempDir =
        await Directory.systemTemp.createTemp('snore_scheduler_test_');
  });

  tearDown(() async {
    await db.close();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  /// Stage one of each sweep target so [runAll] returns nonzero counts
  /// — gives the logger something to record.
  Future<void> stageOneOfEach() async {
    // Pending: aged pending row + final file.
    const pendingRel = 'events/2026-05-07/pending.opus';
    final pendingId = await repo.insertPending(
      startedAt: 1,
      endedAt: 2,
      durationMs: 1,
      audioPath: pendingRel,
    );
    final f = File(p.join(tempDir.path, pendingRel));
    await f.parent.create(recursive: true);
    await f.writeAsBytes([0]);
    await (db.update(db.events)..where((e) => e.id.equals(pendingId)))
        .write(EventsCompanion(
      createdAt: Value(
          DateTime.now().millisecondsSinceEpoch - 65 * 1000),
    ));
  }

  test('runJanitorOnce calls runAll exactly once and emits one log',
      () async {
    await stageOneOfEach();

    final logged = <(String, Map<String, Object?>)>[];
    final result = await runJanitorOnce(
      db: db,
      docsDir: tempDir,
      onLog: (event, fields) => logged.add((event, fields)),
    );

    expect(result.pending, 1, reason: 'aged pending row picked up');
    expect(logged.length, 1,
        reason: 'one log line per cycle — janitor_cycle');
    expect(logged.first.$1, 'janitor_cycle');
    expect(logged.first.$2['pending'], 1);
  });

  test('runOnAppLaunch delegates to runJanitorOnce', () async {
    final logged = <(String, Map<String, Object?>)>[];
    final result = await runOnAppLaunch(
      db: db,
      docsDir: tempDir,
      onLog: (event, fields) => logged.add((event, fields)),
    );
    expect(result.hardDeleted, 0);
    expect(result.autoPruned, 0);
    expect(result.pending, 0);
    expect(result.orphan, 0);
    expect(result.missing, 0);
    expect(logged.first.$1, 'janitor_cycle');
  });

  test('runOnRecorderStop is a no-op on non-iOS hosts', () async {
    // The host running this test is Linux (or possibly macOS). On
    // both, `Platform.isIOS` is false, so the hook short-circuits
    // without invoking runAll. Assert via the logger: a `janitor_cycle`
    // event would have been emitted if runAll had run.
    expect(Platform.isIOS, isFalse,
        reason: 'sanity: this test assumes a non-iOS host');

    await stageOneOfEach();

    final logged = <(String, Map<String, Object?>)>[];
    await runOnRecorderStop(
      db: db,
      docsDir: tempDir,
      onLog: (event, fields) => logged.add((event, fields)),
    );

    expect(logged, isEmpty,
        reason: 'non-iOS hosts skip the recorder-stop janitor cycle '
            '— Android WorkManager owns cadence there');

    // And the staged pending row is still present (runAll didn't run).
    final stillPending = await (db.select(db.events)
          ..where((e) => e.state.equals('pending')))
        .get();
    expect(stillPending.length, 1,
        reason: 'runAll did NOT run, so the aged pending row survives');
  });

  test('runJanitorOnce returns the same shape as runAll', () async {
    final result = await runJanitorOnce(
      db: db,
      docsDir: tempDir,
    );
    // The record fields the UI / telemetry code expects.
    expect(result.hardDeleted, isA<int>());
    expect(result.autoPruned, isA<int>());
    expect(result.pending, isA<int>());
    expect(result.orphan, isA<int>());
    expect(result.missing, isA<int>());
  });
}
