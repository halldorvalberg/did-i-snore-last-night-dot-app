/// Contract tests for `RuntimeFloorRefiner`.
///
/// The load-bearing safety property is "tHigh is monotonic non-increasing
/// across the session". The refiner exists *because* a naive online median
/// would let user-produced events (snoring, talking) raise the floor and
/// silently shut the gate. Every test below pins down a different way that
/// invariant could be broken.
library;

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

import 'package:did_i_snore/config/constants.dart';
import 'package:did_i_snore/recorder/calibrator.dart';

void main() {
  group('RuntimeFloorRefiner', () {
    test('high-variance window is ignored even if candidate is lower', () {
      // The "user already snoring" guard from spec §3.3. Variance > 9
      // dBFS^2 means the window wasn't really quiet — the candidate's
      // median is misleading and must be rejected regardless of value.
      final refiner = RuntimeFloorRefiner(const NoiseFloor(-50.0, 2.0));
      final before = refiner.current;

      refiner.maybeRefine(
        windowMedianDbfs: -55.0, // would lower tHigh from -40 to -45
        windowMadDbfs: 1.0,
        windowVarianceDbfs2: 12.0, // > GateCfg.maxRefinementVarianceDbfs2
      );

      expect(refiner.current, equals(before),
          reason: 'noisy window: candidate median is not trustworthy');
    });

    test('lower candidate at low variance is adopted', () {
      final refiner = RuntimeFloorRefiner(const NoiseFloor(-50.0, 2.0));
      // current.tHigh = -50 + 5*2 = -40

      refiner.maybeRefine(
        windowMedianDbfs: -56.0,
        windowMadDbfs: 1.0,
        windowVarianceDbfs2: 1.0,
      );

      // candidate.tHigh = -56 + 5*1 = -51, strictly lower than -40.
      expect(refiner.current.tHighDbfs, equals(-51.0));
      expect(refiner.current.medianDbfs, equals(-56.0));
      expect(refiner.current.madDbfs, equals(1.0));
    });

    test('equal-tHigh candidate is NOT adopted (strictly lower only)', () {
      // Pin the boundary: the spec says "strictly lower". Build a
      // candidate that produces the same tHigh = -40 but with a different
      // median+MAD pair. Refiner must not update.
      final refiner = RuntimeFloorRefiner(const NoiseFloor(-50.0, 2.0));
      // current.tHigh = -40; candidate median=-55, mad=3 => -55+15 = -40.

      refiner.maybeRefine(
        windowMedianDbfs: -55.0,
        windowMadDbfs: 3.0,
        windowVarianceDbfs2: 1.0,
      );

      expect(refiner.current.medianDbfs, equals(-50.0),
          reason: 'tie on tHigh: keep the original (strictly-lower rule)');
      expect(refiner.current.madDbfs, equals(2.0));
    });

    test('higher candidate is not adopted (the obvious case)', () {
      final refiner = RuntimeFloorRefiner(const NoiseFloor(-50.0, 2.0));

      refiner.maybeRefine(
        windowMedianDbfs: -45.0,
        windowMadDbfs: 2.0,
        windowVarianceDbfs2: 1.0,
      );

      expect(refiner.current, equals(const NoiseFloor(-50.0, 2.0)));
    });

    test('boundary: variance == max is allowed (>, not >=)', () {
      // The implementation uses `>` so a window at exactly the threshold
      // is still considered. Lock that down so a future "harden the
      // guard" change to `>=` is a deliberate decision, not a regression.
      final refiner = RuntimeFloorRefiner(const NoiseFloor(-50.0, 2.0));

      refiner.maybeRefine(
        windowMedianDbfs: -56.0,
        windowMadDbfs: 1.0,
        windowVarianceDbfs2: GateCfg.maxRefinementVarianceDbfs2,
      );

      expect(refiner.current.medianDbfs, equals(-56.0),
          reason: 'variance at the threshold passes the guard');
    });

    test('monotonic non-increasing tHigh across a noisy random sequence', () {
      // The headline property test. If any code path in the refiner ever
      // raises tHigh mid-session, this test fires. This is the assertion
      // that backs the spec-reviewer pass.
      final rng = math.Random(7);
      final refiner = RuntimeFloorRefiner(const NoiseFloor(-50.0, 2.0));

      var prev = refiner.current.tHighDbfs;
      for (var i = 0; i < 200; i++) {
        final median = -70.0 + 40.0 * rng.nextDouble(); // [-70, -30]
        final mad = 0.5 + 4.5 * rng.nextDouble(); // [0.5, 5]
        final variance = 20.0 * rng.nextDouble(); // [0, 20]

        refiner.maybeRefine(
          windowMedianDbfs: median,
          windowMadDbfs: mad,
          windowVarianceDbfs2: variance,
        );

        final now = refiner.current.tHighDbfs;
        expect(now, lessThanOrEqualTo(prev),
            reason: 'iteration $i: tHigh raised from $prev to $now '
                '(median=$median, mad=$mad, var=$variance)');
        prev = now;
      }
    });

    test('initial floor is exposed unchanged before any refine call', () {
      const seed = NoiseFloor(-48.0, 1.5);
      final refiner = RuntimeFloorRefiner(seed);
      expect(refiner.initial, equals(seed));
      expect(refiner.current, equals(seed));
    });
  });
}
