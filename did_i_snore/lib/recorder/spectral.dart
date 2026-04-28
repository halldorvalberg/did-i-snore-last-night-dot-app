/// Phase 4 spectral pre-filter. Cheap reject before YAMNet for events
/// whose spectrum looks nothing like snoring. Spec §4.2.
///
/// Two scalar features per event:
///
/// - **Snore-band fraction.** Energy in `[snoreBandLowHz, snoreBandHighHz]`
///   (50–500 Hz) divided by total energy. Real snores park most of their
///   energy here. Fan/HVAC/charging-coil whine typically peaks above
///   500 Hz; alarm clocks and electronic tones live in narrow bands far
///   from the snore range; both are rejected.
/// - **Spectral flatness.** Geometric mean / arithmetic mean of the
///   magnitudes. Near 0 = a single dominant tone or a few harmonics (a
///   voice, a snore, a beep). Near 1 = white-noise-like (HVAC hiss,
///   broadband static). Reject if too flat.
///
/// Apply to the first `AudioCfg.classifierFrameMs` (= 960 ms) of the
/// event — i.e. the post-pre-roll portion. Pre-roll is by definition
/// before the trigger, so it would dilute the snore-band measurement
/// with whatever was on either side of the open instant.
///
/// **Hann window first.** The spec calls for the FFT of a 960 ms slice;
/// without a window function, spectral leakage from strong DC and
/// low-frequency content (a 30 Hz hum, a 60 Hz mains harmonic, the
/// pre-roll's residual DC) bleeds into every other bin and inflates the
/// "total" denominator. A Hann window applied in-place before the FFT
/// is the standard fix and is cheap (one multiply per sample). Coefficients
/// are precomputed in the constructor — Hann is deterministic by length.
///
/// **Linear vs. power magnitudes for flatness.** The spec snippet uses
/// linear `magnitudes()` for both the band-fraction sum AND the flatness
/// geomean. The textbook definition of spectral flatness uses the *power*
/// spectrum (`mag^2`). Linear gives a slightly different scalar, but the
/// `SpectralCfg.maxFlatness` threshold (= 0.65) is calibrated against the
/// linear formulation in the spec. We keep linear for v1 to avoid a quiet
/// numerical drift in the threshold; v2 may swap to power once the
/// fixture corpus is large enough to recalibrate.
///   TODO(v2): swap to power-spectrum flatness and recalibrate
///   `SpectralCfg.maxFlatness` on the corpus.
///
/// **Ambient-MAD bypass is the recorder's job.** This class always
/// computes a [SpectralReading]; the decision to skip the filter for a
/// noisy session lives in `RecorderService` (per §4.2: a quiet snore in a
/// fan-running room has its band fraction dominated by the fan, so the
/// filter mis-rejects). Encoding that here would couple the probe to
/// `NoiseFloor`, which is not its concern.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:fftea/fftea.dart';

import '../config/constants.dart';

/// Numerical floor added to magnitudes before `log()` so silence doesn't
/// produce `-inf`. Spec snippet uses this exact value; keep it for
/// numerical compatibility with any cross-checked fixtures.
const double _logFloor = 1e-10;

/// Default analysis window length in samples = 960 ms × 16 kHz.
/// `fftea` handles non-power-of-two via Bluestein, so 15360 is fine; no
/// padding to 16384 unless the package complains (it doesn't, on 1.5.0).
const int _defaultN =
    AudioCfg.classifierFrameMs * AudioCfg.sampleRateHz ~/ 1000;

/// Result of analyzing one event window.
class SpectralReading {
  /// Sum of magnitudes in `[snoreBandLowHz, snoreBandHighHz]` divided
  /// by sum over the full half-spectrum. In `[0, 1]`. Higher = more
  /// snore-like.
  final double snoreBandFraction;

  /// Spectral flatness, `[0, 1]`. Near 1 = white-noise-like; near 0 =
  /// strongly tonal. We reject above `SpectralCfg.maxFlatness`.
  final double flatness;

  const SpectralReading(this.snoreBandFraction, this.flatness);

  @override
  String toString() =>
      'SpectralReading(snoreBand=${snoreBandFraction.toStringAsFixed(3)}, '
      'flatness=${flatness.toStringAsFixed(3)})';
}

/// Computes spectral features over a fixed-length window. One instance
/// per recorder session — the FFT plan and Hann coefficients are cached.
class SpectralProbe {
  /// FFT size in samples.
  final int n;

  /// Pre-computed Hann window of length `n`. Applied in-place before
  /// each FFT. Hann coefficients are deterministic for a given `n`, so
  /// computing them once at construction saves a `cos()` per sample on
  /// every analyze call.
  final Float64List _hann;

  /// Reusable input buffer the Hann-windowed samples go into. `realFft`
  /// allocates its own output (a Float64x2List of length `n`), so the
  /// only repeat allocation per analyze is fftea's; we can't avoid it
  /// without dropping into `inPlaceFft`, which would more than double
  /// the code complexity for ~one ~120 KB allocation per accepted
  /// event (= dozens per night, not hot).
  final Float64List _windowed;

  /// Cached FFT plan. fftea memoizes plans by size internally too, but
  /// holding the reference avoids the map lookup per call.
  final FFT _fft;

  /// Index range of bins inside the snore band, precomputed from
  /// `SpectralCfg.snoreBandLowHz` / `snoreBandHighHz` and `n`.
  final int _bandLoIdx;
  final int _bandHiIdx;

  SpectralProbe({this.n = _defaultN})
      : _hann = _buildHann(n),
        _windowed = Float64List(n),
        _fft = FFT(n),
        _bandLoIdx =
            (SpectralCfg.snoreBandLowHz * n / AudioCfg.sampleRateHz).floor(),
        _bandHiIdx =
            (SpectralCfg.snoreBandHighHz * n / AudioCfg.sampleRateHz).ceil();

  /// Analyzes the first `n` samples of `samples`. If `samples.length < n`
  /// the input is zero-padded — the Hann window already tapers the
  /// trailing zeros so this introduces no spectral discontinuity.
  ///
  /// Edge cases:
  /// - Empty / all-zero input → `SpectralReading(0.0, 1.0)`. Treating
  ///   silence as max-flat means it gets rejected by the
  ///   `flatness > maxFlatness` test, which is the correct outcome
  ///   (the recorder shouldn't have called us with silence anyway).
  /// - Numeric blow-up in the geomean is bounded by `_logFloor`.
  SpectralReading analyze(Float32List samples) {
    final take = samples.length < n ? samples.length : n;

    // Hann-window into the reusable buffer; zero out anything beyond
    // `take` from a previous call.
    for (var i = 0; i < take; i++) {
      _windowed[i] = samples[i] * _hann[i];
    }
    for (var i = take; i < n; i++) {
      _windowed[i] = 0.0;
    }

    final spec = _fft.realFft(_windowed).discardConjugates();
    final mags = spec.magnitudes();

    var inBand = 0.0;
    var total = 0.0;
    for (var i = 0; i < mags.length; i++) {
      final m = mags[i];
      total += m;
      if (i >= _bandLoIdx && i <= _bandHiIdx) inBand += m;
    }

    if (total <= 0.0) {
      // Pure silence (or numerical underflow). Flat by convention.
      return const SpectralReading(0.0, 1.0);
    }

    // Spectral flatness via log-mean trick: geomean = exp(mean(log(x))).
    // The `+ _logFloor` guards against `log(0)` for any zero bin.
    var logSum = 0.0;
    for (var i = 0; i < mags.length; i++) {
      logSum += math.log(mags[i] + _logFloor);
    }
    final geoMean = math.exp(logSum / mags.length);
    final arithMean = total / mags.length;
    // arithMean > 0 because total > 0; safe to divide.
    final flatness = geoMean / arithMean;

    final snoreBandFraction = inBand / total;
    return SpectralReading(snoreBandFraction, flatness);
  }

  /// No-op today; kept for symmetry with future heap-allocating FFT
  /// backends and to give the recorder a single place to release. fftea
  /// holds its plans in a static cache, so there's nothing instance-local
  /// to free.
  void dispose() {}

  // ---- helpers -----------------------------------------------------------

  static Float64List _buildHann(int n) {
    final out = Float64List(n);
    if (n == 1) {
      out[0] = 1.0;
      return out;
    }
    // Standard Hann: 0.5 * (1 - cos(2π i / (N-1))).
    final denom = (n - 1).toDouble();
    for (var i = 0; i < n; i++) {
      out[i] = 0.5 * (1.0 - math.cos(2.0 * math.pi * i / denom));
    }
    return out;
  }
}
