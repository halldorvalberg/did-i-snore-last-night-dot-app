/// Tests for `EncodeQueue` — Phase 7 §7.3 backpressure + the
/// pending→ready flip from Phase 6 §6.2.
///
/// The queue's `encode` parameter is the test seam: production passes
/// the real `encodeEventToOpus`, which loads the native ffmpeg plugin
/// and won't initialise on the Linux host. Every test here injects a
/// fake closure that records its invocations and either succeeds (by
/// writing a stub file at `<docsDir>/<relPath>`) or throws.
///
/// The DB is in-memory (`AppDb.forTesting(NativeDatabase.memory())`)
/// per test, mirroring `recorder_service_test.dart`. The `docsDir` is
/// a per-test `Directory.systemTemp` partition, deleted in tearDown so
/// nothing leaks between runs.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:did_i_snore/data/db.dart';
import 'package:did_i_snore/data/event_repo.dart';
import 'package:did_i_snore/recorder/encode_queue.dart';

/// One log call captured by the fake `EncodeLogger`.
typedef _LogCall = ({String event, Map<String, Object?> fields});

/// One invocation of the fake encoder, captured for ordering assertions.
typedef _EncodeCall = ({String relPath, int pcmLen});

/// Builds a fake encoder closure that records every call into [calls],
/// honours [shouldThrow] for per-invocation failure injection, and (on
/// success) writes a tiny stub file at the canonical output path so a
/// real-encoder caller would be indistinguishable from this fake.
///
/// The signature matches `encodeEventToOpus` exactly; the queue picks
/// it up via the `encode:` constructor parameter.
Future<File> Function({
  required Int16List pcm,
  required String relPath,
  required Directory docsDir,
}) _buildFakeEncoder({
  required List<_EncodeCall> calls,
  bool Function(int callIndex)? shouldThrow,
  Future<void> Function(int callIndex)? gate,
}) {
  return ({
    required Int16List pcm,
    required String relPath,
    required Directory docsDir,
  }) async {
    final idx = calls.length;
    calls.add((relPath: relPath, pcmLen: pcm.length));
    if (gate != null) await gate(idx);
    if (shouldThrow != null && shouldThrow(idx)) {
      throw StateError('boom@$idx');
    }
    final outPath = p.join(docsDir.path, relPath);
    await Directory(p.dirname(outPath)).create(recursive: true);
    final f = File(outPath);
    await f.writeAsBytes(const [0x00], flush: true);
    return f;
  };
}

/// Inserts a pending row with a deterministic `audioPath` derived from
/// [name] so each test can correlate ids back to job tags.
Future<int> _insertPending(EventRepo repo, String name) {
  final now = DateTime.now().millisecondsSinceEpoch;
  return repo.insertPending(
    startedAt: now,
    endedAt: now + 1000,
    durationMs: 1000,
    audioPath: 'events/2026-05-08/$name.opus',
  );
}

EncodeJob _job({
  required int id,
  required String name,
  Map<String, double>? labels,
  String topLabel = 'Snoring',
}) {
  return EncodeJob(
    eventId: id,
    pcm: Int16List(16),
    relPath: 'events/2026-05-08/$name.opus',
    topLabel: topLabel,
    labels: labels ?? const {'Snoring': 0.71},
  );
}

void main() {
  late AppDb db;
  late EventRepo repo;
  late Directory tempDir;
  late List<_LogCall> logCalls;
  late EncodeLogger logger;

  setUp(() {
    db = AppDb.forTesting(NativeDatabase.memory());
    repo = EventRepo(db);
    tempDir = Directory.systemTemp.createTempSync('snore_encode_test_');
    logCalls = <_LogCall>[];
    logger = (event, fields) =>
        logCalls.add((event: event, fields: fields));
  });

  tearDown(() async {
    await db.close();
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  group('EncodeQueue submit + happy path', () {
    test(
        'single submit: encoder invoked once with the right '
        '(pcm, relPath, docsDir); row reaches state=ready with labels '
        'round-tripping through EventRepo.decodeLabels',
        () async {
      final calls = <_EncodeCall>[];
      final encoder = _buildFakeEncoder(calls: calls);
      final queue = EncodeQueue(
        repo: repo,
        docsDir: tempDir,
        onLog: logger,
        encode: encoder,
      );

      final id = await _insertPending(repo, 'a');
      queue.submit(_job(
        id: id,
        name: 'a',
        labels: const {'Snoring': 0.71},
      ));
      await queue.drain();

      expect(calls, hasLength(1),
          reason: 'a single submit must produce exactly one encode call');
      expect(calls.single.relPath, 'events/2026-05-08/a.opus');
      expect(calls.single.pcmLen, 16,
          reason: 'fake job pcm is Int16List(16); the queue must not '
              'truncate or copy');

      final row = await repo.getById(id);
      expect(row, isNotNull);
      expect(row!.state, 'ready');
      expect(row.topLabel, 'Snoring');
      expect(row.peaksPath, isNull,
          reason: 'Phase 7 always writes peaksPath=null; peaks land in '
              'Phase 8');
      expect(row.labelsJson, isNotNull);
      final decoded = EventRepo.decodeLabels(row.labelsJson);
      expect(decoded, {'Snoring': 0.71},
          reason: 'labels must round-trip via decodeLabels exactly');
      expect(logCalls, isEmpty,
          reason: 'happy path emits no log events');
    });

    test(
        'three sequential submits: encoder runs in submission order',
        () async {
      final calls = <_EncodeCall>[];
      final encoder = _buildFakeEncoder(calls: calls);
      final queue = EncodeQueue(
        repo: repo,
        docsDir: tempDir,
        onLog: logger,
        encode: encoder,
      );

      final id1 = await _insertPending(repo, 'one');
      final id2 = await _insertPending(repo, 'two');
      final id3 = await _insertPending(repo, 'three');

      queue.submit(_job(id: id1, name: 'one'));
      queue.submit(_job(id: id2, name: 'two'));
      queue.submit(_job(id: id3, name: 'three'));

      await queue.drain();

      expect(calls.map((c) => c.relPath).toList(), [
        'events/2026-05-08/one.opus',
        'events/2026-05-08/two.opus',
        'events/2026-05-08/three.opus',
      ], reason: 'serial drain must preserve submission order');

      for (final id in [id1, id2, id3]) {
        final row = await repo.getById(id);
        expect(row?.state, 'ready', reason: 'row id=$id should be ready');
      }
    });

    test('drain() resolves immediately on a fresh queue with no submits',
        () async {
      final encoder = _buildFakeEncoder(calls: <_EncodeCall>[]);
      final queue = EncodeQueue(
        repo: repo,
        docsDir: tempDir,
        onLog: logger,
        encode: encoder,
      );

      // Should not hang. We wrap in an expectLater with a timeout so a
      // regression here surfaces as a clean failure instead of a CI
      // timeout.
      await expectLater(
        queue.drain().timeout(const Duration(seconds: 2)),
        completes,
      );
    });

    test('drain() is idempotent: a second call after empty also resolves',
        () async {
      final calls = <_EncodeCall>[];
      final encoder = _buildFakeEncoder(calls: calls);
      final queue = EncodeQueue(
        repo: repo,
        docsDir: tempDir,
        onLog: logger,
        encode: encoder,
      );

      final id = await _insertPending(repo, 'a');
      queue.submit(_job(id: id, name: 'a'));
      await queue.drain();

      // Second call after the queue has emptied: must resolve without
      // hanging on a stale completer.
      await expectLater(
        queue.drain().timeout(const Duration(seconds: 2)),
        completes,
        reason: 'drain() called after the queue is idle must resolve '
            'immediately, not block on a stale completer',
      );
    });

    test('pending getter reflects queue depth across the lifecycle',
        () async {
      // Use a gated encoder so we can observe pending while a job is
      // in flight (the in-flight job is NOT counted in pending).
      final completer = Completer<void>();
      final calls = <_EncodeCall>[];
      final encoder = _buildFakeEncoder(
        calls: calls,
        gate: (i) async {
          if (i == 0) await completer.future;
        },
      );
      final queue = EncodeQueue(
        repo: repo,
        docsDir: tempDir,
        onLog: logger,
        encode: encoder,
      );

      expect(queue.pending, 0, reason: 'fresh queue is empty');

      final id1 = await _insertPending(repo, 'one');
      final id2 = await _insertPending(repo, 'two');

      queue.submit(_job(id: id1, name: 'one'));
      queue.submit(_job(id: id2, name: 'two'));
      // First job is in-flight (awaiting the completer); second is
      // queued. In-flight does not count.
      // We need to yield a microtask so _drain pulls the first job.
      await Future<void>.delayed(Duration.zero);
      expect(queue.pending, 1,
          reason: 'one in-flight + one queued → pending=1');

      completer.complete();
      await queue.drain();
      expect(queue.pending, 0, reason: 'drain() leaves pending=0');
    });
  });

  group('EncodeQueue drop-oldest overflow', () {
    test(
        'maxDepth=2 with 5 synchronous submits: head + 2 mids dropped, '
        'in-flight + 2 newest survive and reach ready',
        () async {
      // Gate the first encode so it stays in flight while the rest of
      // the synchronous submits land. Without the gate, between submits
      // the awaiting `_drain` microtask wouldn't fire (we never yield),
      // but the FIRST submit's `_kickDrain` runs `_drain` synchronously
      // up to its first `await` — which means j0 is already pulled off
      // the queue (in-flight) by the time submit returns. The encoder's
      // `await firstReleased.future` is what holds j0 mid-flight.
      //
      // Trace with maxDepth=2, given the in-flight pull on j0:
      //   submit j0: depth 0 → add → kickDrain → _drain pulls j0 →
      //              awaits encoder.gate(0). Queue now [].
      //   submit j1: depth 0 → add → [j1]
      //   submit j2: depth 1 → add → [j1, j2]
      //   submit j3: depth 2 ≥ 2 → drop j1 → add j3 → [j2, j3]
      //   submit j4: depth 2 ≥ 2 → drop j2 → add j4 → [j3, j4]
      // Drops: j1, j2 (2 drops). Survivors that reach the encoder: j0
      // (in flight), j3, j4 → 3 encoder calls in order.
      final firstReleased = Completer<void>();
      final calls = <_EncodeCall>[];
      final encoder = _buildFakeEncoder(
        calls: calls,
        gate: (i) async {
          if (i == 0) await firstReleased.future;
        },
      );
      final queue = EncodeQueue(
        repo: repo,
        docsDir: tempDir,
        onLog: logger,
        maxDepth: 2,
        encode: encoder,
      );

      final ids = <int>[];
      for (var i = 0; i < 5; i++) {
        ids.add(await _insertPending(repo, 'j$i'));
      }

      for (var i = 0; i < 5; i++) {
        queue.submit(_job(id: ids[i], name: 'j$i'));
      }

      firstReleased.complete();
      await queue.drain();

      // Encoder ran on j0 (in flight when overflow happened), j3, j4.
      expect(calls.map((c) => c.relPath).toList(), [
        'events/2026-05-08/j0.opus',
        'events/2026-05-08/j3.opus',
        'events/2026-05-08/j4.opus',
      ], reason: 'in-flight head + 2 newest survive; mids j1 and j2 '
          'are dropped before they reach the encoder');

      // Two drop logs, in drop order (j1, j2).
      final dropLogs = logCalls
          .where((c) => c.event == 'encode_dropped_overflow')
          .toList();
      expect(dropLogs, hasLength(2));
      expect(
        dropLogs.map((c) => c.fields['id']).toList(),
        [ids[1], ids[2]],
        reason: 'drops must be logged in oldest-first order',
      );

      // Survivors are ready; dropped rows are soft-deleted (deletedAt
      // non-null) and their state column was never advanced past pending.
      final j0 = await repo.getById(ids[0]);
      final j3 = await repo.getById(ids[3]);
      final j4 = await repo.getById(ids[4]);
      expect(j0?.state, 'ready', reason: 'in-flight job completes normally');
      expect(j3?.state, 'ready');
      expect(j4?.state, 'ready');
      expect(j0?.deletedAt, isNull);
      expect(j3?.deletedAt, isNull);
      expect(j4?.deletedAt, isNull);

      for (final droppedId in [ids[1], ids[2]]) {
        final row = await repo.getById(droppedId);
        expect(row, isNotNull);
        expect(row!.state, 'pending',
            reason: 'overflow drop never flips state past pending; only '
                'deletedAt is set');
        expect(row.deletedAt, isNotNull,
            reason: 'overflow drop must soft-delete the row id=$droppedId');
      }
    });

    test(
        'maxDepth=2 with in-flight head + 2 queued: no drop yet; a 4th '
        'submit drops exactly the oldest queued (NOT the in-flight head)',
        () async {
      // Spec contract per encode_queue.dart line 167: "an in-flight
      // encode is NOT counted in the depth check — only the buffered
      // tail is". So with maxDepth=2 and one job in flight, the queue
      // can hold 2 more before overflow. This test pins exactly that.
      final firstReleased = Completer<void>();
      final calls = <_EncodeCall>[];
      final encoder = _buildFakeEncoder(
        calls: calls,
        gate: (i) async {
          if (i == 0) await firstReleased.future;
        },
      );
      final queue = EncodeQueue(
        repo: repo,
        docsDir: tempDir,
        onLog: logger,
        maxDepth: 2,
        encode: encoder,
      );

      final idA = await _insertPending(repo, 'a');
      final idB = await _insertPending(repo, 'b');
      final idC = await _insertPending(repo, 'c');

      // submit A: kick drain → A becomes in-flight (queue empty).
      queue.submit(_job(id: idA, name: 'a'));
      // submit B, C: queued tail is now [B, C], at depth=maxDepth.
      queue.submit(_job(id: idB, name: 'b'));
      queue.submit(_job(id: idC, name: 'c'));

      // No drops yet — the tail is at capacity but we haven't tried to
      // overflow it.
      expect(
        logCalls.where((c) => c.event == 'encode_dropped_overflow'),
        isEmpty,
        reason: 'tail at capacity but no overflow → no drop logged yet',
      );

      // Fourth submit — pushes the tail into overflow. The head of the
      // tail is B, so B is what gets dropped. A (in flight) is unaffected.
      final idD = await _insertPending(repo, 'd');
      queue.submit(_job(id: idD, name: 'd'));

      final dropLogs = logCalls
          .where((c) => c.event == 'encode_dropped_overflow')
          .toList();
      expect(dropLogs, hasLength(1),
          reason: 'one overflow → one drop');
      expect(dropLogs.single.fields['id'], idB,
          reason: 'drop-OLDEST targets the head of the QUEUED tail; the '
              'in-flight head (A) must not be touched');

      firstReleased.complete();
      await queue.drain();
    });

    test(
        'encode_dropped_overflow log payload contains both id and '
        'queueDepth at the moment of the drop',
        () async {
      final firstReleased = Completer<void>();
      final calls = <_EncodeCall>[];
      final encoder = _buildFakeEncoder(
        calls: calls,
        gate: (i) async {
          if (i == 0) await firstReleased.future;
        },
      );
      final queue = EncodeQueue(
        repo: repo,
        docsDir: tempDir,
        onLog: logger,
        maxDepth: 2,
        encode: encoder,
      );

      // 4 submits at maxDepth=2: j0 in-flight, [j1, j2] fills tail,
      // j3 overflows and drops j1. (The depth check excludes in-flight,
      // per the spec contract — see prior test for the trace.)
      final id0 = await _insertPending(repo, 'a');
      final id1 = await _insertPending(repo, 'b');
      final id2 = await _insertPending(repo, 'c');
      final id3 = await _insertPending(repo, 'd');

      queue.submit(_job(id: id0, name: 'a'));
      queue.submit(_job(id: id1, name: 'b'));
      queue.submit(_job(id: id2, name: 'c'));
      queue.submit(_job(id: id3, name: 'd'));

      final drop = logCalls
          .firstWhere((c) => c.event == 'encode_dropped_overflow');
      expect(drop.fields.keys.toSet(), {'id', 'queueDepth'},
          reason: 'overflow log payload must carry id + queueDepth — and '
              'no extras that could leak PII');
      expect(drop.fields['id'], id1,
          reason: 'the dropped row is the head of the queued tail');
      expect(drop.fields['queueDepth'], isA<int>());

      firstReleased.complete();
      await queue.drain();
    });
  });

  group('EncodeQueue encode failure', () {
    test(
        'fake throws on first job: row stays pending (no soft-delete), '
        'second job still encodes; one encode_failed log fired',
        () async {
      final calls = <_EncodeCall>[];
      final encoder = _buildFakeEncoder(
        calls: calls,
        // Throw on the very first encode call.
        shouldThrow: (i) => i == 0,
      );
      final queue = EncodeQueue(
        repo: repo,
        docsDir: tempDir,
        onLog: logger,
        encode: encoder,
      );

      final id1 = await _insertPending(repo, 'fail');
      final id2 = await _insertPending(repo, 'ok');

      queue.submit(_job(id: id1, name: 'fail'));
      queue.submit(_job(id: id2, name: 'ok'));

      await queue.drain();

      // Row 1: encode failed → state stays pending, deletedAt null.
      // The pending sweep is the canonical recovery path; the queue MUST
      // NOT pre-empt it with a soft-delete (that's the overflow path).
      final row1 = await repo.getById(id1);
      expect(row1?.state, 'pending',
          reason: 'encode-failure path must leave row in pending for the '
              'pending sweep; soft-delete is reserved for overflow');
      expect(row1?.deletedAt, isNull,
          reason: 'encode-failure must NOT soft-delete');

      // Row 2: drain didn't halt — second job ran and succeeded.
      final row2 = await repo.getById(id2);
      expect(row2?.state, 'ready',
          reason: 'a single failed job must not poison the rest of the queue');

      // Exactly one encode_failed log; payload contains id + error.
      final failLogs =
          logCalls.where((c) => c.event == 'encode_failed').toList();
      expect(failLogs, hasLength(1));
      expect(failLogs.single.fields['id'], id1);
      expect(failLogs.single.fields['error'], contains('boom'),
          reason: 'error field must surface the throw\'s message');
    });
  });

  group('EncodeQueue markReady race', () {
    test(
        'row deleted from under the queue before encode completes: '
        'encode_markready_missing logged, drain still resolves',
        () async {
      final calls = <_EncodeCall>[];
      final encoder = _buildFakeEncoder(calls: calls);
      final queue = EncodeQueue(
        repo: repo,
        docsDir: tempDir,
        onLog: logger,
        encode: encoder,
      );

      final id = await _insertPending(repo, 'gone');
      // Pretend the pending sweep tore down the row mid-encode by hard-
      // deleting it before submit. markReady's WHERE clause filters on
      // `state='pending'`, so the UPDATE will match zero rows and return
      // false → the queue logs encode_markready_missing.
      await (db.delete(db.events)
            ..where((e) => e.id.equals(id)))
          .go();

      queue.submit(_job(id: id, name: 'gone'));
      // Drain must resolve, not loop forever.
      await queue.drain().timeout(const Duration(seconds: 2));

      final missLogs = logCalls
          .where((c) => c.event == 'encode_markready_missing')
          .toList();
      expect(missLogs, hasLength(1),
          reason: 'a vanished row must be logged exactly once');
      expect(missLogs.single.fields['id'], id);

      // The encoder DID run (succeeded from its own perspective). The
      // file the encoder wrote is now an orphan — Phase 9's orphan sweep
      // is responsible for it; not the queue's job to clean up.
      expect(calls, hasLength(1));
    });
  });

  group('EncodeQueue drain timing', () {
    test(
        'drain() does not resolve until the in-flight encoder completes; '
        'pending counts the queued tail only (in-flight excluded)',
        () async {
      final firstReleased = Completer<void>();
      final calls = <_EncodeCall>[];
      final encoder = _buildFakeEncoder(
        calls: calls,
        gate: (i) async {
          if (i == 0) await firstReleased.future;
        },
      );
      final queue = EncodeQueue(
        repo: repo,
        docsDir: tempDir,
        onLog: logger,
        encode: encoder,
      );

      final id1 = await _insertPending(repo, 'one');
      queue.submit(_job(id: id1, name: 'one'));

      // Yield once so the drain loop pulls the job and enters the gated
      // encoder. After this, _queue.isEmpty (pulled) and _draining=true
      // (encoding). Pending counts the tail only.
      await Future<void>.delayed(Duration.zero);
      expect(queue.pending, 0,
          reason: 'in-flight encode is NOT counted in pending — only the '
              'buffered tail is');

      // Submit a second job during the in-flight gap → pending bumps to 1.
      final id2 = await _insertPending(repo, 'two');
      queue.submit(_job(id: id2, name: 'two'));
      expect(queue.pending, 1,
          reason: 'a tail submit during in-flight encode bumps pending');

      // drain() must not resolve until the encoder is released. Race a
      // 200 ms delay against drain(); whichever fires first wins. The
      // delay should win.
      var drainResolved = false;
      // ignore: discarded_futures — fire-and-forget probe of drain().
      queue.drain().then((_) => drainResolved = true);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(drainResolved, isFalse,
          reason: 'drain() must remain unresolved while the encoder is '
              'gated mid-flight');

      // Release the gate; drain resolves.
      firstReleased.complete();
      await queue.drain().timeout(const Duration(seconds: 2));

      expect(calls, hasLength(2),
          reason: 'both jobs must encode after the gate releases');
    });
  });
}
