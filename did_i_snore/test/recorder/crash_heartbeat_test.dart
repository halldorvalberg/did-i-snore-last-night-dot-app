/// Tests for `lib/recorder/crash_heartbeat.dart`.
///
/// Spec: `docs/IMPLEMENTATION.md` §9 lines 940–949. The detector reads
/// `shared_preferences` for the previous session's start / clean-
/// shutdown markers, and on a "started but never cleanly stopped"
/// state inserts a `recording_gaps` row covering the inferred gap.
///
/// `SharedPreferences.setMockInitialValues` drives the prefs state.
/// The AppDb is in-memory.
library;

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:did_i_snore/data/db.dart';
import 'package:did_i_snore/recorder/crash_heartbeat.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDb db;

  setUp(() {
    db = AppDb.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
  });

  test('clean shutdown previously: no detection, no gap inserted',
      () async {
    SharedPreferences.setMockInitialValues({
      'did_i_snore.last_clean_shutdown_at': 1000,
      // session_started_at intentionally absent
    });

    final result = await CrashHeartbeat.detectAndClear(db);
    expect(result.detected, isFalse);
    expect(result.gapStart, isNull);
    expect(result.gapEnd, isNull);

    final gaps = await db.select(db.recordingGaps).get();
    expect(gaps, isEmpty,
        reason: 'a clean shutdown must NOT insert a gap row');
  });

  test('session_started_at without clean shutdown: gap inserted with '
      'clamped start', () async {
    // Simulate a long-running session that crashed: started 1 hour ago,
    // last heartbeat 10 minutes ago. The gap should start AT the last-
    // heartbeat-minus-interval (the recorder was demonstrably alive at
    // the heartbeat) and end AT the heartbeat — NOT swallow the entire
    // hour-long session.
    final now = DateTime.now();
    final sessionStart =
        now.subtract(const Duration(hours: 1)).millisecondsSinceEpoch;
    final lastHeartbeat =
        now.subtract(const Duration(minutes: 10)).millisecondsSinceEpoch;

    SharedPreferences.setMockInitialValues({
      'did_i_snore.session_started_at': sessionStart,
      'did_i_snore.last_heartbeat_at': lastHeartbeat,
    });

    final result = await CrashHeartbeat.detectAndClear(db);
    expect(result.detected, isTrue);
    expect(result.gapStart, isNotNull);
    expect(result.gapEnd, isNotNull);
    // gapEnd == last heartbeat
    expect(result.gapEnd!.millisecondsSinceEpoch, lastHeartbeat);
    // gapStart is clamped: max(sessionStart, lastHeartbeat - 30s).
    // lastHeartbeat - 30s is 10 min ago - 30 s, which is much later
    // than sessionStart (1 h ago), so gapStart == lastHeartbeat - 30s.
    expect(
      result.gapStart!.millisecondsSinceEpoch,
      lastHeartbeat - 30 * 1000,
    );

    final gaps = await db.select(db.recordingGaps).get();
    expect(gaps.length, 1);
    expect(gaps.first.reason, 'crash');
    expect(gaps.first.startedAt, lastHeartbeat - 30 * 1000);
    expect(gaps.first.endedAt, lastHeartbeat);
  });

  test('missing heartbeat falls back to "now" for gapEnd', () async {
    // Crash within the first heartbeat interval — no heartbeat ever
    // written. The detector should fall back to `now` as the gap end
    // (best signal we have) and use `session_started_at` as the start.
    final now = DateTime.now();
    final fixedNow = now;
    final sessionStart =
        now.subtract(const Duration(seconds: 5)).millisecondsSinceEpoch;

    SharedPreferences.setMockInitialValues({
      'did_i_snore.session_started_at': sessionStart,
      // last_heartbeat_at intentionally absent
    });

    final result = await CrashHeartbeat.detectAndClear(
      db,
      now: () => fixedNow,
    );
    expect(result.detected, isTrue);
    expect(result.gapStart!.millisecondsSinceEpoch, sessionStart);
    expect(
      result.gapEnd!.millisecondsSinceEpoch,
      fixedNow.millisecondsSinceEpoch,
      reason: 'no heartbeat → fall back to now',
    );
  });

  test('idempotent: a second detectAndClear returns no-detection',
      () async {
    final now = DateTime.now();
    final sessionStart =
        now.subtract(const Duration(minutes: 5)).millisecondsSinceEpoch;
    SharedPreferences.setMockInitialValues({
      'did_i_snore.session_started_at': sessionStart,
    });

    final first = await CrashHeartbeat.detectAndClear(db, now: () => now);
    expect(first.detected, isTrue);

    final second = await CrashHeartbeat.detectAndClear(db, now: () => now);
    expect(second.detected, isFalse,
        reason: 'session_started_at is cleared after first call → '
            'second call sees no signal');

    final gaps = await db.select(db.recordingGaps).get();
    expect(gaps.length, 1, reason: 'only one gap row was inserted');
  });

  test('markSessionStarted clears clean-shutdown and prior heartbeat',
      () async {
    SharedPreferences.setMockInitialValues({
      'did_i_snore.last_clean_shutdown_at': 1000,
      'did_i_snore.last_heartbeat_at': 500,
    });

    await CrashHeartbeat.markSessionStarted();
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt('did_i_snore.session_started_at'), isNotNull);
    expect(prefs.getInt('did_i_snore.last_clean_shutdown_at'), isNull,
        reason: 'starting a session must clear the prior clean-shutdown '
            'marker so the next launch sees the session-in-progress');
    expect(prefs.getInt('did_i_snore.last_heartbeat_at'), isNull,
        reason: 'prior heartbeat would skew the next crash recovery — '
            'must be cleared on session start');
  });

  test('markCleanShutdown clears session-started and heartbeat', () async {
    SharedPreferences.setMockInitialValues({
      'did_i_snore.session_started_at': 2000,
      'did_i_snore.last_heartbeat_at': 3000,
    });

    await CrashHeartbeat.markCleanShutdown();
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt('did_i_snore.last_clean_shutdown_at'), isNotNull);
    expect(prefs.getInt('did_i_snore.session_started_at'), isNull,
        reason: 'a clean stop must clear the in-progress marker so the '
            'next launch returns no-detection');
    expect(prefs.getInt('did_i_snore.last_heartbeat_at'), isNull);
  });

  test('writeHeartbeat updates last_heartbeat_at to now', () async {
    SharedPreferences.setMockInitialValues({});

    final beforeMs = DateTime.now().millisecondsSinceEpoch;
    await CrashHeartbeat.writeHeartbeat();
    final afterMs = DateTime.now().millisecondsSinceEpoch;

    final prefs = await SharedPreferences.getInstance();
    final hb = prefs.getInt('did_i_snore.last_heartbeat_at');
    expect(hb, isNotNull);
    expect(hb!, greaterThanOrEqualTo(beforeMs));
    expect(hb, lessThanOrEqualTo(afterMs));
  });

  test('a fresh install (empty prefs): no detection', () async {
    SharedPreferences.setMockInitialValues({});

    final result = await CrashHeartbeat.detectAndClear(db);
    expect(result.detected, isFalse);

    final gaps = await db.select(db.recordingGaps).get();
    expect(gaps, isEmpty);
  });

  test('logger is invoked with crash_detected event on detection',
      () async {
    final now = DateTime.now();
    final sessionStart =
        now.subtract(const Duration(minutes: 5)).millisecondsSinceEpoch;
    final lastHeartbeat =
        now.subtract(const Duration(minutes: 1)).millisecondsSinceEpoch;
    SharedPreferences.setMockInitialValues({
      'did_i_snore.session_started_at': sessionStart,
      'did_i_snore.last_heartbeat_at': lastHeartbeat,
    });

    final logged = <(String, Map<String, Object?>)>[];
    await CrashHeartbeat.detectAndClear(
      db,
      now: () => now,
      onLog: (event, fields) => logged.add((event, fields)),
    );

    expect(logged.length, 1);
    expect(logged.first.$1, 'crash_detected');
    expect(logged.first.$2['hadHeartbeat'], isTrue);
  });
}
