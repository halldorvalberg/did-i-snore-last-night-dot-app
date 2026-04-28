/// Pure-math contract tests for `NoiseFloor` and `estimateFloor`.
///
/// Locks in the median+MAD shape the gate's hysteresis math depends on:
/// `tHigh = median + 5*MAD`, `tLow = median + 3*MAD`, and the median is
/// the robust-to-outliers point that makes those thresholds stable when
/// the calibration session catches a stray cough.
library;

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

import 'package:did_i_snore/config/constants.dart';
import 'package:did_i_snore/recorder/calibrator.dart';

void main() {
  group('estimateFloor', () {
    test('uniform distribution: median ~= midpoint, MAD ~= (b-a)/4', () {
      // Uniform on [-60, -40] has true median -50, true MAD 5.0.
      final rng = math.Random(42);
      final samples = List<double>.generate(
        1500,
        (_) => -60.0 + 20.0 * rng.nextDouble(),
        growable: false,
      );

      final result = estimateFloor(samples);

      expect(result.medianDbfs, closeTo(-50.0, 0.5));
      expect(result.madDbfs, closeTo(5.0, 1.0));
    });

    test('outliers do not pull tHigh up — the whole point of MAD', () {
      // 1480 frames around -55 dBFS (Gaussian, stddev 1) + 20 outliers at
      // -10 dBFS. Mean would be dragged toward -10; median should not be.
      final rng = math.Random(123);
      final samples = <double>[];
      for (var i = 0; i < 1480; i++) {
        // Box-Muller for one Gaussian sample.
        final u1 = rng.nextDouble().clamp(1e-12, 1.0);
        final u2 = rng.nextDouble();
        final z = math.sqrt(-2.0 * math.log(u1)) * math.cos(2 * math.pi * u2);
        samples.add(-55.0 + z); // stddev 1 dB
      }
      for (var i = 0; i < 20; i++) {
        samples.add(-10.0);
      }

      final result = estimateFloor(samples);

      expect(result.medianDbfs, closeTo(-55.0, 1.0),
          reason: 'median is robust; outliers must not move it');
      expect(result.tHighDbfs, lessThan(-30.0),
          reason: 'tHigh must remain far below the -10 dBFS outliers');
    });

    test('all-identical input: MAD == 0, no NaN/Infinity downstream', () {
      final result = estimateFloor(List<double>.filled(50, -45.0));

      expect(result.medianDbfs, equals(-45.0));
      expect(result.madDbfs, equals(0.0));
      // With madK = 5 and (madK - 2) = 3, both thresholds collapse onto the
      // median. The contract is "no division by MAD anywhere"; verify.
      expect(result.tHighDbfs, equals(-45.0));
      expect(result.tLowDbfs, equals(-45.0));
      expect(result.tHighDbfs.isNaN, isFalse);
      expect(result.tHighDbfs.isInfinite, isFalse);
      expect(result.tLowDbfs.isNaN, isFalse);
      expect(result.tLowDbfs.isInfinite, isFalse);
    });

    test('empty input throws ArgumentError', () {
      expect(() => estimateFloor(<double>[]), throwsArgumentError);
    });

    test('median uses length ~/ 2 (low-median, not midpoint average)', () {
      // We picked low-median to match the spec: estimateFloor uses
      // `sorted[length ~/ 2]`. For [1, 2] (length 2) that's index 1, so
      // the median is 2.0 — NOT 1.5. This is the canonical behavior the
      // recorder relies on; locking it in here.
      final evenLen = estimateFloor(<double>[1.0, 2.0]);
      expect(evenLen.medianDbfs, equals(2.0),
          reason: 'even length picks the upper-of-two-middle (length ~/ 2)');

      final oddLen = estimateFloor(<double>[1.0, 2.0, 3.0]);
      expect(oddLen.medianDbfs, equals(2.0),
          reason: 'odd length picks the true middle');
    });

    test('tHigh - tLow == 2 * MAD invariant across random inputs', () {
      // The arithmetic is `median + 5*mad` vs `median + 3*mad`. On IEEE 754
      // these can differ by ~1 ULP but in practice the subtraction is exact.
      final rng = math.Random(99);
      for (var trial = 0; trial < 10; trial++) {
        final samples = List<double>.generate(
          200,
          (_) => -70.0 + 30.0 * rng.nextDouble(),
          growable: false,
        );
        final floor = estimateFloor(samples);

        expect(floor.tHighDbfs - floor.tLowDbfs,
            closeTo(2.0 * floor.madDbfs, 1e-9),
            reason: 'hysteresis gap must equal 2 MAD-units exactly');
      }
    });
  });

  group('NoiseFloor thresholds', () {
    test('tHigh and tLow use GateCfg.madK', () {
      // Defensive: if someone changes madK in constants, the thresholds
      // here move with it. Test reads the config rather than hard-coding 5.
      const floor = NoiseFloor(-50.0, 2.0);
      expect(floor.tHighDbfs, equals(-50.0 + GateCfg.madK * 2.0));
      expect(floor.tLowDbfs, equals(-50.0 + (GateCfg.madK - 2.0) * 2.0));
    });

    test('value equality + hashCode', () {
      // estimateFloor is referentially-transparent on input; two calls with
      // the same data must produce equal NoiseFloors. The == operator is
      // load-bearing for the refiner's "candidate >= current" guard.
      const a = NoiseFloor(-47.5, 1.7);
      const b = NoiseFloor(-47.5, 1.7);
      const c = NoiseFloor(-47.5, 1.8);
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      expect(a, isNot(equals(c)));
    });
  });
}
