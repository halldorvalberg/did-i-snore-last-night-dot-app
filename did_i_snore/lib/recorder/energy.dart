/// Frame-level energy helpers: mean-square and RMS dBFS for int16 PCM.
///
/// Pure top-level functions — no class state, easy to call from the gate /
/// calibrator. These run at ~50 Hz (every 20 ms frame), so a single
/// per-call allocation when alignment forces a copy is fine; per-byte work
/// is not.
library;

import 'dart:math' as math;
import 'dart:typed_data';

/// dBFS floor. `meanSquare == 0` (true silence) or numerically tiny values
/// would produce `-inf`/very-negative dB; we clamp here so downstream
/// statistics (median, MAD) are well-defined.
const double _minDbfs = -120.0;

/// Square of the largest representable int16 sample (`32768`). Reference
/// for full-scale dBFS: `0 dBFS == sample value == 32768`.
const double _int16FullScaleSquared = 32768.0 * 32768.0;

/// Mean of the squares of little-endian int16 samples in `pcmBytes`.
///
/// Reads via `ByteData.getInt16` which is alignment-agnostic. The slicer
/// yields `Uint8List.sublistView` frames whose `offsetInBytes` is usually
/// odd after a stitch — `Int16List.view` would throw on those, and copying
/// to align would allocate ~640 bytes per frame at 50 Hz. `ByteData` reads
/// at any byte offset, no allocation.
///
/// `pcmBytes.length` must be even (one trailing byte is silently ignored).
/// Returns 0.0 for an empty input.
double meanSquare(Uint8List pcmBytes) {
  final n = pcmBytes.length >> 1;
  if (n == 0) return 0.0;

  final view = ByteData.sublistView(pcmBytes);

  // Double accumulator. Even at 16 kHz a 20 ms frame is 320 samples;
  // worst-case sum is 320 * 32768^2 = ~3.4e11 which is well inside
  // double's mantissa.
  var sumSquares = 0.0;
  for (var i = 0; i < n; i++) {
    final s = view.getInt16(i << 1, Endian.little).toDouble();
    sumSquares += s * s;
  }
  return sumSquares / n;
}

/// Converts a mean-square value to dBFS, clamped to `_minDbfs` for
/// silence or non-positive inputs.
///
/// `dBFS = 10 * log10(meanSquare / 32768^2)` — i.e. full-scale int16
/// sine-wave RMS sits at 0 dBFS.
double rmsDbfs(double meanSquare) {
  if (meanSquare <= 0.0) return _minDbfs;
  final db = 10.0 * (math.log(meanSquare / _int16FullScaleSquared) / math.ln10);
  return db < _minDbfs ? _minDbfs : db;
}
