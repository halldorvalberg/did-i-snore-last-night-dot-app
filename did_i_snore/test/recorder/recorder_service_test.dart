/// Integration tests for `RecorderService` covering three branches the
/// per-stage tests cannot reach by themselves:
///
///  1. The session-level `_filterEnabled=false` bypass when ambient MAD
///     exceeds `SpectralCfg.maxAmbientMadForFilter`.
///  2. The per-event spectral-skip when the post-pre-roll slice is shorter
///     than `_classifierSamples`.
///  3. The in-flight-window drop on `stop()`.
///
/// All three are wired through a fake `MicSource` so no platform mic is
/// involved. Wall-clock delays are real because `RecorderService._onChunk`
/// reads `DateTime.now().millisecondsSinceEpoch` itself; per the task brief
/// we do NOT add a clock-injection seam to production code.
library;

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:did_i_snore/config/constants.dart';
import 'package:did_i_snore/data/db.dart';
import 'package:did_i_snore/data/event_repo.dart';
import 'package:did_i_snore/recorder/calibrator.dart';
import 'package:did_i_snore/recorder/mic_source.dart';
import 'package:did_i_snore/recorder/recorder_service.dart';

/// Method-channel name used by `record` 6.x. Stubbed so the parent
/// `MicSource` constructor (which instantiates `AudioRecorder`) does not
/// hit the platform during test setup.
const _recordChannel = MethodChannel('com.llfbandit.record/messages');

void _stubRecordChannel() {
  TestWidgetsFlutterBinding.ensureInitialized();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_recordChannel, (call) async => null);
}

void _clearStub() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_recordChannel, null);
}

/// Fake mic source that exposes a controllable `pcm16` stream. `start()` /
/// `stop()` are no-op state flips. Subclasses `MicSource` so it satisfies
/// the `MicSource? mic` injection point in `RecorderService`.
class _FakeMicSource extends MicSource {
  final StreamController<Uint8List> _ctrl =
      StreamController<Uint8List>.broadcast();

  /// Fake of the native interruption-events stream (Android only in prod;
  /// driven by tests here). Mirrors the real `MicSource.nativeEvents`.
  final StreamController<Map<String, dynamic>> _events =
      StreamController<Map<String, dynamic>>.broadcast();

  @override
  Stream<Uint8List> get pcm16 => _ctrl.stream;

  @override
  Stream<Map<String, dynamic>> get nativeEvents => _events.stream;

  @override
  Future<void> start() async {}

  @override
  Future<void> stop() async {
    if (!_ctrl.isClosed) await _ctrl.close();
    if (!_events.isClosed) await _events.close();
  }

  /// Push a chunk into the stream and yield to the microtask queue so the
  /// recorder's listener gets to process it before we push the next one.
  Future<void> push(Uint8List chunk) async {
    _ctrl.add(chunk);
    await Future<void>.delayed(Duration.zero);
  }

  /// Push a native event map (e.g. interruption began/ended) and yield so
  /// the recorder's `_onNativeEvent` handler processes it before we continue.
  Future<void> pushEvent(Map<String, dynamic> event) async {
    _events.add(event);
    await Future<void>.delayed(Duration.zero);
  }
}

/// Builds a single-frame chunk of a sine at `freqHz` with peak amplitude
/// `peak` (int16). RMS dBFS for a sine is `20 * log10(peak / sqrt(2) /
/// 32768)`, so callers can dial dBFS by choosing `peak`.
Uint8List _sineFrame(double freqHz, int peak, {required int phaseSamples}) {
  final samples = Int16List(AudioCfg.frameBytes ~/ 2);
  final twoPi = 2 * math.pi;
  for (var i = 0; i < samples.length; i++) {
    final t = (phaseSamples + i) / AudioCfg.sampleRateHz;
    samples[i] = (peak * math.sin(twoPi * freqHz * t)).round();
  }
  return Uint8List.view(samples.buffer);
}

/// All-zero chunk of one frame's worth of bytes. dBFS clamps to -120 → way
/// below any tLow used in this file.
Uint8List _silentFrame() => Uint8List(AudioCfg.frameBytes);

/// Peak amplitude that clears `tHigh` for the given floor. We aim for an
/// RMS ~10 dB above tHigh so jitter in the conversion is irrelevant. RMS of
/// a sine at peak `p` is `p / sqrt(2)`; full-scale is 32768 → peak `p`
/// produces dBFS ≈ `20*log10(p) - 90.31`. Inverting for a target dBFS
/// gives `p = 10^((target+90.31)/20)`. We add a 10 dB margin.
int _peakForDbfs(double targetDbfs) {
  final p = math.pow(10, (targetDbfs + 90.31) / 20.0).toDouble();
  return p.round().clamp(1, 32767);
}

void main() {
  setUp(_stubRecordChannel);
  tearDown(_clearStub);

  group('RecorderService', () {
    test(
        'filterEnabled=false bypass: noisy-ambient session emits a long '
        'out-of-band event without spectral check',
        () async {
      // Floor with MAD above maxAmbientMadForFilter (= 4.0) → filter off.
      // tHigh = -50 + 5*5 = -25 dBFS, tLow = -50 + 3*5 = -35 dBFS.
      const floor = NoiseFloor(-50.0, 5.0);
      final mic = _FakeMicSource();
      // `classifier: null` skips Phase 5 classification — accepted events
      // come through with empty labels and `('Other', 0.0)`. Keeps tflite
      // out of the unit-test harness (it can't load on Linux anyway).
      final svc = RecorderService(
        noiseFloor: floor,
        mic: mic,
        classifier: null,
      );

      expect(svc.filterEnabled, isFalse,
          reason: 'MAD 5.0 > maxAmbientMadForFilter 4.0 → filter disabled');

      final events = <ClassifiedEvent>[];
      final rejections = <RejectedEvent>[];
      final eSub = svc.events.listen(events.add);
      final rSub = svc.rejections.listen(rejections.add);

      await svc.start();

      // 2 kHz tone: well above the [50, 500] Hz snore band, so if the
      // filter were running it would reject on snoreBandFraction. We feed
      // it WAY above tHigh so the gate definitely opens.
      final loudPeak = _peakForDbfs(floor.tHighDbfs + 10.0);

      // 16 frames spaced 20 ms apart spans 300 ms of wall-clock between
      // first above-tHigh frame and the trigger frame → gate opens.
      var phase = 0;
      for (var i = 0; i < 16; i++) {
        await mic.push(_sineFrame(2000.0, loudPeak, phaseSamples: phase));
        phase += AudioCfg.frameBytes ~/ 2;
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }

      // Stuff enough additional loud frames into the open window that the
      // post-pre-roll slice is long enough to exceed _classifierSamples.
      // Pre-roll bytes ≈ 16 frames * 640 = 10240; canonical pre-roll mark
      // is 64000; classifier wants 30720 post-pre-roll bytes; total wanted
      // ≥ 94720. We pump these rapidly — the gate is open, so frame-by-
      // frame state doesn't change and wall-clock delays are unnecessary.
      for (var i = 0; i < 160; i++) {
        await mic.push(_sineFrame(2000.0, loudPeak, phaseSamples: phase));
        phase += AudioCfg.frameBytes ~/ 2;
      }

      // Tail: ≥ 1000 ms of below-tLow → gate closes.
      for (var i = 0; i < 55; i++) {
        await mic.push(_silentFrame());
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }

      // Drain any pending microtasks so the close handler runs.
      await Future<void>.delayed(const Duration(milliseconds: 50));

      await svc.stop();
      await eSub.cancel();
      await rSub.cancel();

      expect(events, hasLength(1),
          reason: 'with filter disabled the 2 kHz event must pass through');
      expect(rejections, isEmpty,
          reason: 'no rejection reason should fire when filter is bypassed');
      // Sanity: the event is long enough that the spectral filter WOULD
      // have rejected it if it had run. If this fails, the test's setup
      // ate its own premise (event was actually too short to be a useful
      // bypass test).
      expect(events.single.window.totalBytes, greaterThanOrEqualTo(94720),
          reason: 'event must be long enough that the bypass is what '
              'saved it, not the short-event skip');
      // With `classifier: null` the §5.3 path emits an empty label map
      // and falls back to the Other-tagged top label; assert that
      // contract here so future regressions don't silently change it.
      expect(events.single.labels, isEmpty);
      expect(events.single.topLabel, 'Other');
      expect(events.single.topScore, 0.0);
    });

    test(
        'filterEnabled=true short-event skip: event passes duration filter '
        'but post-pre-roll < classifierSamples → spectral check skipped',
        () async {
      // Floor with MAD below maxAmbientMadForFilter → filter on.
      // tHigh = -50 + 5*2 = -40 dBFS, tLow = -50 + 3*2 = -44 dBFS.
      const floor = NoiseFloor(-50.0, 2.0);
      final mic = _FakeMicSource();
      final svc = RecorderService(
        noiseFloor: floor,
        mic: mic,
        classifier: null,
      );

      expect(svc.filterEnabled, isTrue,
          reason: 'MAD 2.0 ≤ maxAmbientMadForFilter 4.0 → filter enabled');

      final events = <ClassifiedEvent>[];
      final rejections = <RejectedEvent>[];
      final eSub = svc.events.listen(events.add);
      final rSub = svc.rejections.listen(rejections.add);

      await svc.start();

      // 2 kHz tone that would be REJECTED if the spectral filter ran
      // (snoreBandFraction ≈ 0 for 2 kHz).
      final loudPeak = _peakForDbfs(floor.tHighDbfs + 10.0);

      // Hold (300 ms): gate opens.
      var phase = 0;
      for (var i = 0; i < 16; i++) {
        await mic.push(_sineFrame(2000.0, loudPeak, phaseSamples: phase));
        phase += AudioCfg.frameBytes ~/ 2;
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }

      // Tail (1000 ms): gate closes. NO rapid loud-burst middle, so total
      // bytes stay short. Pre-roll at open ≈ 16 * 640 = 10240; tail ≈
      // 55 * 640 = 35200; total ≈ 45440 bytes. That is BELOW the canonical
      // 64000-byte pre-roll mark, so `firstSamplesAsFloat32` returns 0
      // samples (< _classifierSamples = 15360) → spectral check skipped.
      // durationMs ≈ 45440 / 32 = 1420 ms ≥ minEventDurationMs (500), so
      // the duration filter passes, putting us in exactly the branch we
      // want.
      for (var i = 0; i < 55; i++) {
        await mic.push(_silentFrame());
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }

      await Future<void>.delayed(const Duration(milliseconds: 50));

      await svc.stop();
      await eSub.cancel();
      await rSub.cancel();

      expect(events, hasLength(1),
          reason: 'short-post-pre-roll branch must pass the event through');
      expect(rejections, isEmpty,
          reason: 'spectral check was skipped — no rejection should fire');
      // Sanity: the event is short enough that the skip is what passed
      // it. If totalBytes ≥ 64000 + 30720 = 94720, the spectral check
      // would have run (and rejected, since it is 2 kHz).
      expect(events.single.window.totalBytes, lessThan(94720),
          reason: 'event must be short enough post-pre-roll that the skip '
              'branch is what passed it');
      expect(events.single.window.durationMs,
          greaterThanOrEqualTo(AudioCfg.minEventDurationMs),
          reason: 'must clear the duration filter to reach the spectral '
              'branch in the first place');
    });

    test(
        'stop() drops in-flight EventWindow without emitting and closes '
        'output streams', () async {
      const floor = NoiseFloor(-50.0, 2.0);
      final mic = _FakeMicSource();
      final svc = RecorderService(
        noiseFloor: floor,
        mic: mic,
        classifier: null,
      );

      final events = <ClassifiedEvent>[];
      final rejections = <RejectedEvent>[];
      final eDone = Completer<void>();
      final rDone = Completer<void>();
      final eSub = svc.events.listen(events.add, onDone: eDone.complete);
      final rSub =
          svc.rejections.listen(rejections.add, onDone: rDone.complete);

      await svc.start();

      // Open the gate but DON'T close it. 16 above-tHigh frames spanning
      // 300 ms wall-clock → gate opens. We use 200 Hz here (in-band) so
      // even if the test were accidentally driven to close, the event
      // would land on `events`, not `rejections` — which would still fail
      // the assertion below but with a clearer signal.
      final loudPeak = _peakForDbfs(floor.tHighDbfs + 10.0);
      var phase = 0;
      for (var i = 0; i < 16; i++) {
        await mic.push(_sineFrame(200.0, loudPeak, phaseSamples: phase));
        phase += AudioCfg.frameBytes ~/ 2;
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }

      // Stop while the gate is still open and the EventWindow is in flight.
      await svc.stop();

      // No event, no rejection — stop() drops _current.
      expect(events, isEmpty,
          reason: 'in-flight EventWindow must be dropped, not emitted');
      expect(rejections, isEmpty,
          reason: 'no rejection should fire on stop()');

      // Streams must be closed.
      await expectLater(eDone.future, completes);
      await expectLater(rDone.future, completes);

      await eSub.cancel();
      await rSub.cancel();
    });

    test(
        'YAMNet reject policy: low maxCurated AND high Other → '
        'lowConfidence rejection; thrown classifier → classifierError '
        'rejection; otherwise event passes with topLabel set',
        () async {
      // Helper to drive a full open-then-close cycle on the given service
      // with the given fake classifier. We use an in-band 200 Hz tone so
      // the spectral pre-filter passes (snoreBandFraction is high inside
      // [50, 500] Hz, flatness is low). The filter is enabled here (MAD =
      // 2.0 ≤ 4.0); whichever post-spectral path the classifier triggers
      // is what gets observed.
      Future<({List<ClassifiedEvent> events, List<RejectedEvent> rejections})>
          run(Classifier classifier) async {
        const floor = NoiseFloor(-50.0, 2.0);
        final mic = _FakeMicSource();
        final svc = RecorderService(
          noiseFloor: floor,
          mic: mic,
          classifier: classifier,
        );
        expect(svc.filterEnabled, isTrue);

        final events = <ClassifiedEvent>[];
        final rejections = <RejectedEvent>[];
        final eSub = svc.events.listen(events.add);
        final rSub = svc.rejections.listen(rejections.add);

        await svc.start();

        final loudPeak = _peakForDbfs(floor.tHighDbfs + 10.0);

        // 16 frames @ 20 ms wall-clock spacing → gate's 300 ms hold
        // satisfied → gate opens.
        var phase = 0;
        for (var i = 0; i < 16; i++) {
          await mic.push(_sineFrame(200.0, loudPeak, phaseSamples: phase));
          phase += AudioCfg.frameBytes ~/ 2;
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }

        // Pump enough additional 200 Hz frames that the post-pre-roll
        // slice exceeds _classifierSamples (so the spectral probe runs
        // and passes — 200 Hz is in-band).
        for (var i = 0; i < 160; i++) {
          await mic.push(_sineFrame(200.0, loudPeak, phaseSamples: phase));
          phase += AudioCfg.frameBytes ~/ 2;
        }

        // Tail: ≥ 1000 ms below tLow → gate closes.
        for (var i = 0; i < 55; i++) {
          await mic.push(_silentFrame());
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }

        await Future<void>.delayed(const Duration(milliseconds: 50));
        await svc.stop();
        await eSub.cancel();
        await rSub.cancel();

        return (events: events, rejections: rejections);
      }

      // Case A — REJECT: maxCurated == 0 (no curated label present),
      // Other == 0.6 > maxOtherForKeep (0.5).
      final rejectResult = await run((_) => {'Other': 0.6});
      expect(rejectResult.events, isEmpty,
          reason: 'low-confidence event must not surface on `events`');
      expect(rejectResult.rejections, hasLength(1));
      expect(rejectResult.rejections.single.reason,
          RejectionReason.lowConfidence);
      expect(rejectResult.rejections.single.reading, isNull,
          reason: 'lowConfidence rejections carry no SpectralReading');

      // Case B — KEEP: maxCurated == 0.5 ≥ minTopCuratedForKeep (0.3),
      // so the event passes regardless of the Other score. Tests the
      // disjunctive nature of the §5.3 policy (kept when EITHER curated
      // has a foothold OR Other isn't dominant).
      final keepResult =
          await run((_) => {'Snoring': 0.5, 'Other': 0.3});
      expect(keepResult.rejections, isEmpty);
      expect(keepResult.events, hasLength(1));
      expect(keepResult.events.single.topLabel, 'Snoring');
      expect(keepResult.events.single.topScore, 0.5);
      expect(keepResult.events.single.labels, {'Snoring': 0.5, 'Other': 0.3});

      // Case C — REJECT (classifierError): the classifier throws (e.g.
      // interpreter not loaded, native-side failure, unsupported output
      // dtype). The recorder must surface this as a loud rejection rather
      // than silently degrading to Other — a broken model should not be
      // invisible in field reports.
      final errorResult = await run((_) {
        throw StateError('simulated classifier failure');
      });
      expect(errorResult.events, isEmpty,
          reason: 'thrown classifier must not produce a `events` entry');
      expect(errorResult.rejections, hasLength(1));
      expect(errorResult.rejections.single.reason,
          RejectionReason.classifierError);
      expect(errorResult.rejections.single.reading, isNull,
          reason: 'classifierError rejections carry no SpectralReading');
    });

    test(
        'repo injection: an accepted event triggers insertPending with the '
        "canonical events/YYYY-MM-DD/<startedAt>.opus path in state='pending'",
        () async {
      // Phase 6 wire-up: when `repo` is non-null, the recorder must write a
      // `state='pending'` row before the event surfaces on the public
      // stream. We back the repo with an in-memory AppDb so the assertion
      // can read the row back; no path_provider plugin shim required.
      final db = AppDb.forTesting(NativeDatabase.memory());
      addTearDown(() async => db.close());
      final repo = EventRepo(db);

      const floor = NoiseFloor(-50.0, 2.0);
      final mic = _FakeMicSource();
      final svc = RecorderService(
        noiseFloor: floor,
        mic: mic,
        // Fake classifier puts us on the §5.3 keep arm: maxCurated = 0.6
        // ≥ minTopCuratedForKeep (0.3), so the event passes regardless of
        // the Other score. Result: `_emitEvent` runs → `repo.insertPending`
        // is invoked.
        classifier: (_) => {'Snoring': 0.6},
        repo: repo,
      );

      final events = <ClassifiedEvent>[];
      final eSub = svc.events.listen(events.add);

      await svc.start();

      final loudPeak = _peakForDbfs(floor.tHighDbfs + 10.0);

      // 16 frames @ 20 ms wall-clock spacing → gate's 300 ms hold elapses
      // → gate opens. Use 200 Hz (in-band) so the spectral pre-filter
      // passes — same shape as the existing keep-case test.
      var phase = 0;
      for (var i = 0; i < 16; i++) {
        await mic.push(_sineFrame(200.0, loudPeak, phaseSamples: phase));
        phase += AudioCfg.frameBytes ~/ 2;
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }

      // Pump enough additional in-band frames that post-pre-roll exceeds
      // _classifierSamples → spectral probe runs and accepts.
      for (var i = 0; i < 160; i++) {
        await mic.push(_sineFrame(200.0, loudPeak, phaseSamples: phase));
        phase += AudioCfg.frameBytes ~/ 2;
      }

      // Tail: ≥ 1000 ms below tLow → gate closes.
      for (var i = 0; i < 55; i++) {
        await mic.push(_silentFrame());
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }

      // Drain the close handler AND the fire-and-forget insertPending
      // future. The recorder doesn't `await` the insert (mic loop must
      // not stall on disk I/O), so we yield here long enough for the
      // microtask + DB round-trip to settle.
      await Future<void>.delayed(const Duration(milliseconds: 100));

      await svc.stop();
      await eSub.cancel();

      expect(events, hasLength(1),
          reason: 'one accepted event must surface on the stream');

      // Read every row from the `events` table — there should be exactly
      // one, and it should be in state='pending' (markReady is the
      // encoder's job, which we have not run here).
      final rows = await db.select(db.events).get();
      expect(rows, hasLength(1),
          reason: 'recorder must insert exactly one pending row per event');
      final row = rows.single;
      expect(row.state, 'pending',
          reason: 'the recorder writes pending only; markReady is owned '
              'by the encoder layer');
      expect(row.startedAt, events.single.window.startMs,
          reason: 'startedAt must match the gate-open timestamp');
      expect(
        RegExp(r'^events/\d{4}-\d{2}-\d{2}/\d+\.opus$').hasMatch(row.audioPath),
        isTrue,
        reason: 'audioPath must be the canonical relative layout from spec '
            '§6.3 — got ${row.audioPath}',
      );
    });
  });

  // Android interruption → RecordingGap rows (the Android equivalent of the
  // iOS §10.2 interruption handling). These drive the fake mic's native
  // events stream directly — no PCM, no gate; the gap-writing path is
  // independent of the audio pipeline.
  group('RecorderService interruption gaps', () {
    /// Builds a recorder wired to an in-memory repo and starts it. Returns
    /// the pieces the tests poke at. The db is torn down automatically.
    Future<({_FakeMicSource mic, RecorderService svc, AppDb db})> build() async {
      final db = AppDb.forTesting(NativeDatabase.memory());
      addTearDown(() async => db.close());
      const floor = NoiseFloor(-50.0, 2.0);
      final mic = _FakeMicSource();
      final svc = RecorderService(
        noiseFloor: floor,
        mic: mic,
        classifier: null,
        repo: EventRepo(db),
      );
      await svc.start();
      return (mic: mic, svc: svc, db: db);
    }

    Future<List<RecordingGap>> gapsOf(AppDb db) async {
      final rows = await db.select(db.recordingGaps).get();
      rows.sort((a, b) => a.startedAt.compareTo(b.startedAt));
      return rows;
    }

    test('began → ended writes exactly one interruption gap with the right '
        'start/end', () async {
      final h = await build();

      await h.mic.pushEvent({'type': 'interruption_began', 'atMs': 1000});
      await h.mic.pushEvent({'type': 'interruption_ended', 'atMs': 16000});

      // Yield for the fire-and-forget gap write (DB round-trip).
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final gaps = await gapsOf(h.db);
      expect(gaps, hasLength(1),
          reason: 'one began/ended pair → exactly one gap');
      expect(gaps.single.startedAt, 1000);
      expect(gaps.single.endedAt, 16000);
      expect(gaps.single.reason, 'interruption');

      await h.svc.stop();
    });

    test('began then stop() (no ended) writes a gap covering began→stop',
        () async {
      final h = await build();

      final beforeStop = DateTime.now().millisecondsSinceEpoch;
      await h.mic.pushEvent({'type': 'interruption_began', 'atMs': 5000});

      // No matching `ended`. stop() must close the gap to ~now.
      await h.svc.stop();
      final afterStop = DateTime.now().millisecondsSinceEpoch;

      final gaps = await gapsOf(h.db);
      expect(gaps, hasLength(1),
          reason: 'stop mid-interruption must close the open gap');
      expect(gaps.single.startedAt, 5000);
      expect(gaps.single.reason, 'interruption');
      // endedAt is wall-clock `now` at stop() — bracket it loosely.
      expect(gaps.single.endedAt, greaterThanOrEqualTo(beforeStop));
      expect(gaps.single.endedAt, lessThanOrEqualTo(afterStop + 1000));
    });

    test('no interruption events → no gap rows', () async {
      final h = await build();

      // Push some PCM-free silence: just stop cleanly with no events.
      await h.svc.stop();

      final gaps = await gapsOf(h.db);
      expect(gaps, isEmpty,
          reason: 'a session with no interruption writes no gaps');
    });

    test('ended with endedAt <= began startedAt is not written (degenerate)',
        () async {
      final h = await build();

      await h.mic.pushEvent({'type': 'interruption_began', 'atMs': 10000});
      // `ended` arrives at or before the start — a clock glitch. The guard
      // in _writeGap must drop it rather than persist a zero/negative gap.
      await h.mic.pushEvent({'type': 'interruption_ended', 'atMs': 10000});

      await Future<void>.delayed(const Duration(milliseconds: 50));

      final gaps = await gapsOf(h.db);
      expect(gaps, isEmpty,
          reason: 'endedAt <= startedAt must not produce a gap row');

      await h.svc.stop();
    });

    test('duplicate began keeps the earliest start; trailing ended without '
        'began is ignored', () async {
      final h = await build();

      await h.mic.pushEvent({'type': 'interruption_began', 'atMs': 2000});
      // Second `began` before any `ended` — keep the FIRST start so the gap
      // spans the whole dead period.
      await h.mic.pushEvent({'type': 'interruption_began', 'atMs': 4000});
      await h.mic.pushEvent({'type': 'interruption_ended', 'atMs': 9000});
      // Stray `ended` with nothing open — must be ignored, no second gap.
      await h.mic.pushEvent({'type': 'interruption_ended', 'atMs': 12000});

      await Future<void>.delayed(const Duration(milliseconds: 50));

      final gaps = await gapsOf(h.db);
      expect(gaps, hasLength(1),
          reason: 'one gap spanning the earliest began to the first ended');
      expect(gaps.single.startedAt, 2000,
          reason: 'duplicate began keeps the earliest start');
      expect(gaps.single.endedAt, 9000);

      await h.svc.stop();
    });
  });
}
