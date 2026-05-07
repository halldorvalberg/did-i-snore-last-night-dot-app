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

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:did_i_snore/config/constants.dart';
import 'package:did_i_snore/recorder/calibrator.dart';
import 'package:did_i_snore/recorder/event_window.dart';
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

  @override
  Stream<Uint8List> get pcm16 => _ctrl.stream;

  @override
  Future<void> start() async {}

  @override
  Future<void> stop() async {
    if (!_ctrl.isClosed) await _ctrl.close();
  }

  /// Push a chunk into the stream and yield to the microtask queue so the
  /// recorder's listener gets to process it before we push the next one.
  Future<void> push(Uint8List chunk) async {
    _ctrl.add(chunk);
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
      final svc = RecorderService(noiseFloor: floor, mic: mic);

      expect(svc.filterEnabled, isFalse,
          reason: 'MAD 5.0 > maxAmbientMadForFilter 4.0 → filter disabled');

      final events = <EventWindow>[];
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
      expect(events.single.totalBytes, greaterThanOrEqualTo(94720),
          reason: 'event must be long enough that the bypass is what '
              'saved it, not the short-event skip');
    });

    test(
        'filterEnabled=true short-event skip: event passes duration filter '
        'but post-pre-roll < classifierSamples → spectral check skipped',
        () async {
      // Floor with MAD below maxAmbientMadForFilter → filter on.
      // tHigh = -50 + 5*2 = -40 dBFS, tLow = -50 + 3*2 = -44 dBFS.
      const floor = NoiseFloor(-50.0, 2.0);
      final mic = _FakeMicSource();
      final svc = RecorderService(noiseFloor: floor, mic: mic);

      expect(svc.filterEnabled, isTrue,
          reason: 'MAD 2.0 ≤ maxAmbientMadForFilter 4.0 → filter enabled');

      final events = <EventWindow>[];
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
      expect(events.single.totalBytes, lessThan(94720),
          reason: 'event must be short enough post-pre-roll that the skip '
              'branch is what passed it');
      expect(events.single.durationMs,
          greaterThanOrEqualTo(AudioCfg.minEventDurationMs),
          reason: 'must clear the duration filter to reach the spectral '
              'branch in the first place');
    });

    test(
        'stop() drops in-flight EventWindow without emitting and closes '
        'output streams', () async {
      const floor = NoiseFloor(-50.0, 2.0);
      final mic = _FakeMicSource();
      final svc = RecorderService(noiseFloor: floor, mic: mic);

      final events = <EventWindow>[];
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
  });
}
