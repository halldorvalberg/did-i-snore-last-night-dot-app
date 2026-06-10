/// Quota-under-pressure tests for `lib/janitor/quota.dart`.
///
/// Spec: `docs/IMPLEMENTATION.md` §9 lines 919–927. The orchestrator
/// runs *before* recording starts and decides whether to allow the
/// session, pruning oldest unstarred events as needed. Starred rows
/// are protected absolutely — that's the test's centerpiece.
///
/// Free-bytes is injected via the [FreeBytesProbe] typedef so the
/// host's actual disk space is irrelevant; tests drive the prune
/// behaviour deterministically.
library;

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:did_i_snore/config/constants.dart';
import 'package:did_i_snore/data/db.dart';
import 'package:did_i_snore/data/event_repo.dart';
import 'package:did_i_snore/janitor/quota.dart';

void main() {
  late AppDb db;
  late EventRepo repo;
  late Directory tempDir;

  setUp(() async {
    db = AppDb.forTesting(NativeDatabase.memory());
    repo = EventRepo(db);
    tempDir = await Directory.systemTemp.createTemp('snore_quota_test_');
  });

  tearDown(() async {
    await db.close();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  /// Bytes corresponding to `RetentionCfg.minFreeDiskMb` — the gate.
  final thresholdBytes = RetentionCfg.minFreeDiskMb * 1024 * 1024;

  /// Bytes a hair below the gate so any prune flips us over.
  final justBelow = thresholdBytes - 1;

  /// Helper: insert a `state='ready'` row at a specific `startedAt`,
  /// optionally write a sized file alongside.
  Future<int> insertReady(
    String rel, {
    required int startedAtMs,
    bool starred = false,
    int fileSizeBytes = 0,
  }) async {
    final id = await repo.insertPending(
      startedAt: startedAtMs,
      endedAt: startedAtMs + 1,
      durationMs: 1,
      audioPath: rel,
    );
    await repo.markReady(
      id: id,
      topLabel: 'Snoring',
      labelsJson: '{}',
      peaksPath: null,
    );
    if (starred) await repo.setStarred(id, true);
    if (fileSizeBytes > 0) {
      final f = File(p.join(tempDir.path, rel));
      await f.parent.create(recursive: true);
      await f.writeAsBytes(List<int>.filled(fileSizeBytes, 0));
    }
    return id;
  }

  test('above threshold: canRecord=true, prunedCount=0', () async {
    // No rows, plenty of free space. Should pass through cleanly.
    final result = await checkQuota(
      db,
      tempDir,
      freeBytesProbe: (_) async => thresholdBytes + 1024 * 1024 * 100,
    );
    expect(result.canRecord, isTrue);
    expect(result.prunedCount, 0);
    expect(result.blockReason, isNull);
    expect(result.freeMb, greaterThan(RetentionCfg.minFreeDiskMb));
  });

  test('below threshold with no rows: canRecord=false, blockReason set',
      () async {
    final result = await checkQuota(
      db,
      tempDir,
      freeBytesProbe: (_) async => justBelow,
    );
    expect(result.canRecord, isFalse,
        reason: 'no candidates → cannot recover');
    expect(result.prunedCount, 0);
    expect(result.blockReason, isNotNull);
    expect(result.blockReason, contains('Manage Storage'));
  });

  test(
      'below threshold with prunable rows: prunes oldest first, '
      'flips to canRecord=true', () async {
    // Two unstarred ready rows. A counter on the probe simulates "free
    // space grew after we deleted a file."
    const oldestRel = 'events/2026-05-07/oldest.opus';
    const newerRel = 'events/2026-05-08/newer.opus';
    final oldestId = await insertReady(
      oldestRel,
      startedAtMs:
          DateTime.now().millisecondsSinceEpoch - 7 * 24 * 3600 * 1000,
      fileSizeBytes: 8,
    );
    final newerId = await insertReady(
      newerRel,
      startedAtMs:
          DateTime.now().millisecondsSinceEpoch - 1 * 24 * 3600 * 1000,
      fileSizeBytes: 8,
    );
    final oldestFile = File(p.join(tempDir.path, oldestRel));
    final newerFile = File(p.join(tempDir.path, newerRel));
    expect(await oldestFile.exists(), isTrue);
    expect(await newerFile.exists(), isTrue);

    // First probe call returns below-threshold. After one prune, the
    // probe returns above-threshold and the loop exits.
    var calls = 0;
    Future<int> probe(Directory _) async {
      calls++;
      if (calls == 1) return justBelow;
      return thresholdBytes + 1;
    }

    final result = await checkQuota(db, tempDir, freeBytesProbe: probe);
    expect(result.canRecord, isTrue);
    expect(result.prunedCount, 1,
        reason: 'one prune was enough to recover');
    expect(result.blockReason, isNull);

    // Oldest pruned (ASC order); newer survives.
    final oldestRow = await repo.getById(oldestId);
    expect(oldestRow!.deletedAt, isNotNull,
        reason: 'oldest unstarred is pruned first');
    final newerRow = await repo.getById(newerId);
    expect(newerRow!.deletedAt, isNull,
        reason: 'newer survives because the loop exited after one prune');

    // Synchronous file unlink is the documented deviation.
    expect(await oldestFile.exists(), isFalse,
        reason: 'quota path unlinks audio synchronously');
    expect(await newerFile.exists(), isTrue);
  });

  test(
      'below threshold with only starred remaining: canRecord=false, '
      'starred is NOT pruned', () async {
    const starredRel = 'events/2026-05-07/starred.opus';
    final starredId = await insertReady(
      starredRel,
      startedAtMs:
          DateTime.now().millisecondsSinceEpoch - 30 * 24 * 3600 * 1000,
      starred: true,
      fileSizeBytes: 8,
    );
    final starredFile = File(p.join(tempDir.path, starredRel));

    // Probe always returns below-threshold; quota has nothing it's
    // *willing* to delete.
    final result = await checkQuota(
      db,
      tempDir,
      freeBytesProbe: (_) async => justBelow,
    );
    expect(result.canRecord, isFalse,
        reason: 'starred is the user signal — must survive every '
            'automatic path');
    expect(result.prunedCount, 0,
        reason: 'no candidates were touched');
    expect(result.blockReason, isNotNull);

    final row = await repo.getById(starredId);
    expect(row!.deletedAt, isNull,
        reason: 'starred row must NOT be tombstoned');
    expect(await starredFile.exists(), isTrue,
        reason: 'starred audio must survive');
  });

  test(
      'mixed starred + unstarred, still below after pruning all '
      'unstarred: canRecord=false', () async {
    // Stage: one starred + two unstarred. Probe always returns below
    // threshold so the loop exhausts unstarred candidates.
    await insertReady(
      'events/2026-05-07/starred.opus',
      startedAtMs:
          DateTime.now().millisecondsSinceEpoch - 30 * 24 * 3600 * 1000,
      starred: true,
      fileSizeBytes: 8,
    );
    await insertReady(
      'events/2026-05-07/unstarred-old.opus',
      startedAtMs:
          DateTime.now().millisecondsSinceEpoch - 20 * 24 * 3600 * 1000,
      fileSizeBytes: 8,
    );
    await insertReady(
      'events/2026-05-08/unstarred-young.opus',
      startedAtMs:
          DateTime.now().millisecondsSinceEpoch - 1 * 24 * 3600 * 1000,
      fileSizeBytes: 8,
    );

    final result = await checkQuota(
      db,
      tempDir,
      freeBytesProbe: (_) async => justBelow,
    );
    expect(result.canRecord, isFalse,
        reason: 'all unstarred pruned, still below → block');
    expect(result.prunedCount, 2,
        reason: 'pruned every unstarred row, then gave up');
    expect(result.blockReason, isNotNull);
  });

  test('idempotent: a second call after recovery returns cleanly',
      () async {
    // First call recovers. Second call sees free above threshold and
    // returns immediately with prunedCount=0.
    await insertReady(
      'events/2026-05-07/oldest.opus',
      startedAtMs:
          DateTime.now().millisecondsSinceEpoch - 7 * 24 * 3600 * 1000,
      fileSizeBytes: 8,
    );
    var firstCallProbeCount = 0;
    Future<int> firstProbe(Directory _) async {
      firstCallProbeCount++;
      if (firstCallProbeCount == 1) return justBelow;
      return thresholdBytes + 1;
    }

    final first = await checkQuota(db, tempDir, freeBytesProbe: firstProbe);
    expect(first.canRecord, isTrue);
    expect(first.prunedCount, 1);

    final second = await checkQuota(
      db,
      tempDir,
      freeBytesProbe: (_) async => thresholdBytes + 1,
    );
    expect(second.canRecord, isTrue);
    expect(second.prunedCount, 0,
        reason: 'second call is above threshold from the first probe; '
            'loop never enters');
  });
}
