/// Contract tests for `SpectralProbe`.
///
/// The spectral pre-filter is a fan-rejector, not a snore-detector — these
/// tests pin the directions the math has to obey: a tonal signal in the
/// 50–500 Hz snore band has high `snoreBandFraction` and low `flatness`,
/// white noise has high `flatness`, and out-of-band tones have low
/// `snoreBandFraction`. We avoid asserting tight numeric values because
/// FFT implementations vary; we assert the right side of the
/// `SpectralCfg.minSnoreBandFraction` / `SpectralCfg.maxFlatness` decision
/// boundary instead.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:did_i_snore/config/constants.dart';
import 'package:did_i_snore/recorder/spectral.dart';

const int _windowN = 15360; // 960ms at 16kHz

/// Generate `n` samples of a cosine at `freqHz` (sample rate 16 kHz).
Float32List _cosine(double freqHz, {int n = _windowN, double amp = 0.5}) {
  final out = Float32List(n);
  final twoPi = 2 * math.pi;
  for (var i = 0; i < n; i++) {
    out[i] = amp * math.cos(twoPi * freqHz * i / AudioCfg.sampleRateHz);
  }
  return out;
}

/// Seeded uniform white noise on [-1, 1].
Float32List _whiteNoise(int seed, {int n = _windowN, double amp = 0.5}) {
  final rng = math.Random(seed);
  final out = Float32List(n);
  for (var i = 0; i < n; i++) {
    out[i] = amp * (2.0 * rng.nextDouble() - 1.0);
  }
  return out;
}

void main() {
  group('SpectralProbe — tonal signals', () {
    test('200 Hz sine: high snore-band fraction, low flatness', () {
      final probe = SpectralProbe();
      final r = probe.analyze(_cosine(200.0));

      expect(r.snoreBandFraction, greaterThan(0.8),
          reason: '200 Hz is well inside [50, 500] Hz; most magnitude should '
              'concentrate there');
      expect(r.flatness, lessThan(0.05),
          reason: 'a single sinusoid is the opposite of white — flatness '
              'should be tiny');
      // Sanity: this passes the two reject conditions.
      expect(r.snoreBandFraction,
          greaterThanOrEqualTo(SpectralCfg.minSnoreBandFraction));
      expect(r.flatness, lessThanOrEqualTo(SpectralCfg.maxFlatness));
    });

    test('2000 Hz sine: low snore-band fraction, low flatness', () {
      final probe = SpectralProbe();
      final r = probe.analyze(_cosine(2000.0));

      expect(r.snoreBandFraction, lessThan(0.05),
          reason: '2 kHz is well above the snore band; almost nothing in [50, 500]');
      expect(r.flatness, lessThan(0.05),
          reason: 'still a single tone, just out of band');
      // Sanity: this fails the snore-band condition (the reject path).
      expect(r.snoreBandFraction,
          lessThan(SpectralCfg.minSnoreBandFraction));
    });

    test('snore-band low edge: 50 Hz sine has most energy in band', () {
      // The IMPLEMENTATION reference uses `f >= 50 && f <= 500` — these
      // edge tests pin the inclusive comparison so a future refactor to
      // `f > 50` (or `< 500`) doesn't silently shift the boundary.
      final probe = SpectralProbe();
      final r = probe.analyze(_cosine(50.0));

      expect(r.snoreBandFraction, greaterThan(0.5),
          reason: '50 Hz must register as in-band');
    });

    test('snore-band high edge: 500 Hz sine has most energy in band', () {
      final probe = SpectralProbe();
      final r = probe.analyze(_cosine(500.0));

      expect(r.snoreBandFraction, greaterThan(0.5),
          reason: '500 Hz must register as in-band');
    });
  });

  group('SpectralProbe — white noise', () {
    test('white noise: high flatness', () {
      final probe = SpectralProbe();
      final r = probe.analyze(_whiteNoise(7));

      // White noise on a 15360-sample window doesn't reach 1.0 because of
      // finite-sample variance and DC/edge effects, but it should be well
      // above the typical tonal value (<0.05) and above maxFlatness=0.65
      // is a stretch on raw uniform noise — pin a generous floor.
      expect(r.flatness, greaterThan(0.4),
          reason: 'uniform noise should have substantially higher flatness '
              'than tones');
    });

    test('white noise has non-trivial energy in every band', () {
      final probe = SpectralProbe();
      final r = probe.analyze(_whiteNoise(11));

      // White noise has ~equal magnitude across all bins. The snore band
      // is 50..500 Hz of an 8 kHz Nyquist range, so a white spectrum
      // should land around 450/8000 ~= 0.056 of total in-band — small,
      // but not zero, and bounded.
      expect(r.snoreBandFraction, greaterThan(0.0));
      expect(r.snoreBandFraction, lessThan(0.5),
          reason: 'white noise is far from concentrating in the snore band');
    });
  });

  group('SpectralProbe — degenerate inputs', () {
    test('all-zero input returns finite, safe defaults', () {
      // Spec: when total energy is zero, flatness defaults to 1.0 (which
      // would trigger the reject path — exactly what we want for silence).
      // snoreBandFraction must be 0.0 (or NaN-free, definitely finite).
      final probe = SpectralProbe();
      final r = probe.analyze(Float32List(_windowN));

      expect(r.flatness.isFinite, isTrue);
      expect(r.snoreBandFraction.isFinite, isTrue);
      expect(r.snoreBandFraction, 0.0);
      expect(r.flatness, closeTo(1.0, 1e-6),
          reason: 'all-zero input → spec contract: flatness == 1.0');
    });
  });

  group('SpectralProbe — output range', () {
    test('snoreBandFraction and flatness stay in [0, 1] across a frequency sweep',
        () {
      // Cheap regression: math edits that overflow [0, 1] (e.g. swapped
      // numerator/denominator, dropped clamp) would fail this immediately.
      final probe = SpectralProbe();
      const freqs = [100.0, 200.0, 400.0, 800.0, 1600.0, 3200.0, 6400.0];
      for (final f in freqs) {
        final r = probe.analyze(_cosine(f));
        expect(r.snoreBandFraction, inInclusiveRange(0.0, 1.0),
            reason: 'snoreBandFraction at $f Hz out of range');
        expect(r.flatness, inInclusiveRange(0.0, 1.0),
            reason: 'flatness at $f Hz out of range');
      }
    });

    test('white noise output also stays in [0, 1]', () {
      final probe = SpectralProbe();
      for (final seed in [1, 2, 3, 4, 5]) {
        final r = probe.analyze(_whiteNoise(seed));
        expect(r.snoreBandFraction, inInclusiveRange(0.0, 1.0));
        expect(r.flatness, inInclusiveRange(0.0, 1.0));
      }
    });
  });
}
