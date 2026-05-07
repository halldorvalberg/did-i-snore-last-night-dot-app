/// Engine-level tests for `Calibrator._emitTick`'s quiet-streak behaviour.
///
/// Regression suite for the 2026-05-07 device walkthrough bug: the streak
/// check used the running median directly, so by construction ~50% of
/// samples were "above the floor" and the streak never reached 10 s in any
/// non-silent room (even one with merely a fan or fridge running).
///
/// The fix replaces the median check with a `tHigh = median + madK*MAD`
/// band. These tests pin the new behaviour so the regression cannot return
/// silently. They drive the engine via a fake `MicSource` exactly like
/// `recorder_service_test.dart`; no platform mic is involved.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:did_i_snore/config/constants.dart';
import 'package:did_i_snore/recorder/calibrator.dart';
import 'package:did_i_snore/recorder/mic_source.dart';

// ---------------------------------------------------------------------------
// Test plumbing
// ---------------------------------------------------------------------------

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

/// Fake mic source — same shape as the one in `recorder_service_test.dart`.
/// Lets a test push raw PCM chunks synchronously into the engine.
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

  /// Push a chunk and yield to the microtask queue so the engine's
  /// listener finishes processing before the next push.
  Future<void> push(Uint8List chunk) async {
    _ctrl.add(chunk);
    await Future<void>.delayed(Duration.zero);
  }
}

// ---------------------------------------------------------------------------
// Frame builders
// ---------------------------------------------------------------------------

/// Number of int16 samples per 20 ms frame (320 at 16 kHz).
const int _samplesPerFrame = AudioCfg.frameBytes ~/ 2;

/// Builds one 20 ms frame whose every sample is the int16 value `s`. This
/// is a DC-like signal — its mean-square is exactly `s*s`, giving a frame
/// dBFS of `10*log10(s*s / 32768^2)`. Convenient when we want to dial dBFS
/// and don't care about spectral content (the calibrator only looks at
/// frame-RMS).
Uint8List _dcFrame(int s) {
  final samples = Int16List(_samplesPerFrame);
  for (var i = 0; i < samples.length; i++) {
    samples[i] = s;
  }
  return Uint8List.view(samples.buffer);
}

/// All-zero frame. Mean-square is exactly 0, so `rmsDbfs` clamps to its
/// floor (-120 dBFS). Useful as the "definitely below tHigh" signal.
Uint8List _silentFrame() => Uint8List(AudioCfg.frameBytes);

/// Full-scale frame: every sample at the int16 max. Mean-square is
/// 32767^2, so dBFS sits arbitrarily close to 0 dBFS — well above any
/// reasonable tHigh constructed from the quiet noise frames in these tests.
Uint8List _loudFrame() {
  final samples = Int16List(_samplesPerFrame);
  for (var i = 0; i < samples.length; i++) {
    samples[i] = 32767;
  }
  return Uint8List.view(samples.buffer);
}

/// Push `n` copies of `frame` through `mic`, awaiting each to let the
/// engine drain the chunk fully before the next arrives.
Future<void> _pumpFrames(_FakeMicSource mic, Uint8List frame, int n) async {
  for (var i = 0; i < n; i++) {
    await mic.push(frame);
  }
}

// ---------------------------------------------------------------------------
// Cadence constants — re-derived from public AudioCfg numbers so the tests
// don't drift if the engine's private `_smoothingFrames` constant changes.
// ---------------------------------------------------------------------------

/// 5 — frames per 100 ms tick.
const int _framesPerTick = 100 ~/ AudioCfg.frameMs;

/// 50 — frames per second.
const int _framesPerSecond = 1000 ~/ AudioCfg.frameMs;

/// 10000 — minimum quiet streak (ms) for `canSave`. Keep in sync with
/// `_minContiguousQuietMs` inside calibrator.dart.
const int _minQuietMs = 10000;

void main() {
  setUp(_stubRecordChannel);
  tearDown(_clearStub);

  group('Calibrator._emitTick — quiet-streak behaviour', () {
    test(
        'sanity: identical-amplitude input with the MAD floor lets the '
        'streak accumulate monotonically', () async {
      // Every frame is the same DC value → every frame-RMS is identical,
      // so MAD of the collection is 0. The fixed engine floors MAD at a
      // tiny positive value (0.5 dBFS at time of writing); with that
      // floor, tHigh sits a hair above median and smoothedDbfs (which
      // exactly equals every frame's dBFS) stays at-or-below tHigh on
      // every tick. The streak should tick up by 100 ms each tick with
      // no resets.
      final mic = _FakeMicSource();
      final cal = Calibrator(mic: mic);

      final emits = <CalibrationState>[];
      final sub = cal.state.listen(emits.add);
      await cal.start();

      // 12 s of identical frames = 600 frames = 120 ticks.
      const seconds = 12;
      await _pumpFrames(mic, _dcFrame(150), seconds * _framesPerSecond);

      await sub.cancel();
      await cal.dispose();

      expect(emits, isNotEmpty);
      // Streak is monotonically non-decreasing across all emits.
      for (var i = 1; i < emits.length; i++) {
        expect(
          emits[i].contiguousQuietMs,
          greaterThanOrEqualTo(emits[i - 1].contiguousQuietMs),
          reason: 'streak must never reset on identical input '
              '(tick ${i - 1} -> $i)',
        );
      }
      // 12 s of pumping clears the 10 s requirement well over.
      expect(emits.last.contiguousQuietMs, greaterThanOrEqualTo(_minQuietMs));
      expect(emits.last.canSave, isTrue);
      // tHigh must be finite — if MAD-floor logic is missing, this
      // would be exactly the median (degenerate), which is still finite,
      // so this is a softer check that catches Infinity/NaN regressions.
      expect(emits.last.estimatedFloorDbfs.isFinite, isTrue);
    });

    test(
        'regression: noisy-but-stable input (steady-fan-like) accumulates '
        'past 10 s and reaches canSave=true', () async {
      // The bug this test guards against: under the old engine the
      // streak check was `smoothedDbfs <= median`, which fails roughly
      // half the time on any input with non-zero MAD. We synthesise
      // frames whose mean-square fluctuates frame-to-frame around a
      // stable mean, simulating what a fan or HVAC produces. With a
      // realistic ~3-4 dB MAD, tHigh = median + 5*MAD sits well above
      // any individual smoothedDbfs, so the streak should now tick
      // every emit.
      //
      // Construction: cycle through 8 distinct DC sample values that
      // give frame-RMS values spanning roughly -52 .. -48 dBFS. The
      // pattern is deterministic (seeded by index, not time) so this
      // test is reproducible.
      final mic = _FakeMicSource();
      final cal = Calibrator(mic: mic);

      final emits = <CalibrationState>[];
      final sub = cal.state.listen(emits.add);
      await cal.start();

      // 8 amplitude levels, picked so the resulting dBFS values span a
      // few dB and so consecutive smoothing windows differ visibly:
      // 80 ->  6400 -> -52.31 dBFS
      // 95 ->  9025 -> -50.84 dBFS
      // 110 -> 12100 -> -49.59 dBFS
      // 125 -> 15625 -> -48.49 dBFS
      // (etc; the asymmetric step pattern below produces a non-trivial
      // distribution, not a tidy two-mode one.)
      const levels = <int>[80, 110, 95, 125, 105, 85, 115, 100];

      // 12 s = 600 frames covers the 10 s requirement plus margin for
      // the engine's per-frame state to settle.
      const seconds = 12;
      const totalFrames = seconds * _framesPerSecond;
      for (var i = 0; i < totalFrames; i++) {
        await mic.push(_dcFrame(levels[i % levels.length]));
      }

      await sub.cancel();
      await cal.dispose();

      // The headline assertion: at least one emitted state has
      // canSave == true. Under the OLD engine this would virtually
      // never happen for noisy input, because the streak would reset
      // every time smoothedDbfs crossed above the median.
      final canSaveEmits = emits.where((e) => e.canSave).toList();
      expect(canSaveEmits, isNotEmpty,
          reason: 'streak should reach $_minQuietMs ms within $seconds s of '
              'steady-fan-like noisy input');

      // Sanity: the emitted estimatedFloorDbfs should be tHigh-shaped
      // (median + madK*MAD), not bare median. The frame dBFS values are
      // all in [-52.5, -48.0]; if the engine were emitting the bare
      // median, the value would land in that band. Under the fix it's
      // shifted up by madK*MAD ≈ 5 dB, putting it clearly above the
      // band's upper edge.
      expect(
        emits.last.estimatedFloorDbfs,
        greaterThan(-48.0),
        reason: 'estimatedFloorDbfs should be median + madK*MAD, well '
            'above the input range upper bound',
      );
    });

    test(
        'a single full-scale frame in the middle of a quiet streak resets '
        'contiguousQuietMs to 0, then the next quiet block re-accumulates',
        () async {
      // Guards against the opposite failure: a fix that widens the band
      // so much that real loud events (snores) no longer reset the
      // calibration streak. We feed quiet frames for ~5 s, inject one
      // full-scale frame, then resume quiet — the streak must reset.
      final mic = _FakeMicSource();
      final cal = Calibrator(mic: mic);

      final emits = <CalibrationState>[];
      final sub = cal.state.listen(emits.add);
      await cal.start();

      // 5 s of identical quiet frames — accumulates ~5 s of streak.
      await _pumpFrames(mic, _dcFrame(150), 5 * _framesPerSecond);
      // Snapshot the streak BEFORE the loud spike. The spike will land
      // on tick boundaries different from `seconds * _framesPerSecond`,
      // so we can't pin an exact value — just record it.
      final preSpikeStreak = emits.last.contiguousQuietMs;
      expect(preSpikeStreak, greaterThan(0),
          reason: 'baseline: 5 s of quiet should already be ticking');

      // One frame at full-scale. This is a single 20 ms frame, but it
      // dominates the 100 ms smoothing window: the smoothed mean-square
      // for the 5-frame window containing this spike is roughly (4 *
      // 22500 + 32767^2) / 5 ≈ 2.15e8, which in dBFS is ~ -7 dB. That
      // is overwhelmingly above any plausible tHigh built from the
      // quiet history → the streak resets at the spike's tick.
      await mic.push(_loudFrame());
      // Pad out to the next tick boundary so _emitTick runs with the
      // spike inside its smoothing window.
      await _pumpFrames(mic, _silentFrame(), _framesPerTick - 1);

      // The MOST RECENT emit after the spike should have streak == 0.
      final spikeEmit = emits.last;
      expect(spikeEmit.contiguousQuietMs, equals(0),
          reason: 'a full-scale frame must reset the streak');

      // Now resume quiet for ≥ 1 s and verify the streak begins
      // re-accumulating from zero.
      const recoverFrames = 2 * _framesPerSecond;
      await _pumpFrames(mic, _dcFrame(150), recoverFrames);

      await sub.cancel();
      await cal.dispose();

      // The post-recovery streak should be > 0 but also strictly less
      // than (preSpikeStreak + 2000) because we genuinely zero'd it.
      // The "less than" half is the load-bearing assertion: it confirms
      // the post-recovery counter restarted from 0 instead of resuming
      // from the pre-spike value.
      final lastStreak = emits.last.contiguousQuietMs;
      expect(lastStreak, greaterThan(0),
          reason: 'quiet should resume ticking after the spike');
      expect(lastStreak, lessThan(preSpikeStreak + 2000),
          reason: 'recovery must start from 0, not resume from the '
              'pre-spike streak value');
    });

    test(
        'edge case: start() with no chunks pumped emits no states and '
        'leaves contiguousQuietMs at 0', () async {
      // The `_runningTHighDbfs()` helper returns negativeInfinity when
      // no frames have been collected; this never reaches a public
      // CalibrationState because _emitTick only runs after 5 frames
      // have been processed. The observable contract is therefore:
      // "no chunks pumped => no states emitted => streak invisibly 0".
      // We cannot directly observe the internal _contiguousQuietMs, but
      // the absence of any emit (and the first emit being non-stale,
      // see further down) is equivalent.
      final mic = _FakeMicSource();
      final cal = Calibrator(mic: mic);

      final emits = <CalibrationState>[];
      final sub = cal.state.listen(emits.add);
      await cal.start();

      // No frames pumped. Yield generously so any spurious emit would
      // have time to land.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(emits, isEmpty,
          reason: 'no chunks => no emits — there is no floor yet to '
              'compare against');

      // Now pump exactly one tick's worth of frames (5 frames). The
      // first emit's streak is either 0 (if smoothedDbfs > tHigh on
      // tick 1) or 100 (if smoothedDbfs <= tHigh). Either is a
      // legitimate post-fix outcome — the load-bearing assertion is
      // that there is no _hidden_ accumulation from before the first
      // chunk.
      await _pumpFrames(mic, _dcFrame(150), _framesPerTick);
      expect(emits, hasLength(1),
          reason: 'exactly one tick of frames => exactly one emit');
      expect(emits.first.contiguousQuietMs, lessThanOrEqualTo(100),
          reason: 'first emit reflects exactly one tick (≤ 100 ms), not '
              'any pre-data backlog');

      await sub.cancel();
      await cal.dispose();
    });

    test(
        'reset() during a streak zeroes contiguousQuietMs without '
        'closing the state stream', () async {
      // The Calibrator exposes reset() for the "Cancel and try again"
      // link in the UI. Important contract: it zeros the streak so the
      // user starts over fresh. This isn't strictly a quiet-streak math
      // test, but it sits next to the other contiguousQuietMs assertions
      // and would have masked the original bug if the UI ever called it
      // automatically — worth pinning.
      final mic = _FakeMicSource();
      final cal = Calibrator(mic: mic);

      final emits = <CalibrationState>[];
      final sub = cal.state.listen(emits.add);
      await cal.start();

      // Accumulate ~3 s of streak.
      await _pumpFrames(mic, _dcFrame(150), 3 * _framesPerSecond);
      expect(emits.last.contiguousQuietMs, greaterThan(0));

      await cal.reset();

      // Pump one more tick post-reset; the resulting emit should show
      // the streak restarting from at most 100 ms.
      await _pumpFrames(mic, _dcFrame(150), _framesPerTick);
      // Find the first emit whose stream index is after the reset call.
      // Easiest: the last emit. It must be either 0 or 100 ms.
      expect(emits.last.contiguousQuietMs, lessThanOrEqualTo(100),
          reason: 'reset() must zero the streak; the post-reset tick can '
              'only have added at most 100 ms');

      await sub.cancel();
      await cal.dispose();
    });
  });
}
