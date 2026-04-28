/// Contract tests for `meanSquare` and `rmsDbfs`.
///
/// These run at ~50 Hz on a sleeping phone for 8+ hours; the math has to be
/// right and the alignment-handling has to be safe.
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:did_i_snore/recorder/energy.dart';

/// Build a `Uint8List` of `numSamples` int16 samples with the given value
/// (alternating sign if `alternate` is true). Little-endian.
Uint8List _int16Bytes(int numSamples, int magnitude, {bool alternate = false}) {
  final samples = Int16List(numSamples);
  for (var i = 0; i < numSamples; i++) {
    final sign = alternate && (i.isOdd) ? -1 : 1;
    samples[i] = sign * magnitude;
  }
  return Uint8List.view(samples.buffer);
}

void main() {
  group('meanSquare', () {
    test('all-zero input returns 0.0', () {
      final bytes = Uint8List(640);
      expect(meanSquare(bytes), 0.0);
    });

    test('empty input returns 0.0 without throwing', () {
      expect(meanSquare(Uint8List(0)), 0.0);
    });

    test('full-scale square wave (±32767) → ~32767² mean-square', () {
      // 320 samples (one 20 ms frame) of alternating ±32767.
      final bytes = _int16Bytes(320, 32767, alternate: true);
      final ms = meanSquare(bytes);
      expect(ms, closeTo(32767.0 * 32767.0, 1.0));
    });

    test('half-scale square wave (±16384) → ~16384² mean-square', () {
      final bytes = _int16Bytes(320, 16384, alternate: true);
      final ms = meanSquare(bytes);
      expect(ms, closeTo(16384.0 * 16384.0, 1.0));
    });

    test('odd byte length: processes lengthInBytes ~/ 2 samples and does not throw',
        () {
      // 321 bytes = 160 full int16 samples + 1 dangling byte.
      final src = _int16Bytes(160, 10000, alternate: false);
      final padded = Uint8List(src.length + 1);
      padded.setRange(0, src.length, src);
      padded[src.length] = 0x7f; // any junk byte

      final ms = meanSquare(padded);
      // 160 samples of 10000 → mean square = 10000^2.
      expect(ms, closeTo(10000.0 * 10000.0, 1.0));
    });

    test('misaligned offsetInBytes: still computes correctly', () {
      // Build a parent with one byte of leading padding, then a sublist
      // view starting at offset 1 (odd → misaligned for Int16List.view).
      final parent = Uint8List(1 + 320 * 2);
      // Fill the int16 region with magnitude 8000 alternating ±.
      final samples = Int16List(320);
      for (var i = 0; i < samples.length; i++) {
        samples[i] = i.isOdd ? -8000 : 8000;
      }
      final src = Uint8List.view(samples.buffer);
      parent.setRange(1, parent.length, src);

      final misaligned = Uint8List.sublistView(parent, 1, parent.length);
      expect(misaligned.offsetInBytes & 1, 1,
          reason: 'precondition: this view has odd offsetInBytes');

      final ms = meanSquare(misaligned);
      expect(ms, closeTo(8000.0 * 8000.0, 1.0));
    });
  });

  group('rmsDbfs', () {
    test('rmsDbfs(0) clamps to -120', () {
      expect(rmsDbfs(0.0), -120.0);
    });

    test('rmsDbfs of a negative input clamps to -120 (does not throw)', () {
      // Negative is technically illegal but we promise to clamp, not crash.
      expect(rmsDbfs(-1.0), -120.0);
      expect(rmsDbfs(-1e9), -120.0);
    });

    test('rmsDbfs of full-scale square-wave mean-square ≈ 0 dBFS', () {
      // 32768^2 is the reference; 32767^2 is one LSB below — about -2.6e-4 dB.
      final ms = 32767.0 * 32767.0;
      final db = rmsDbfs(ms);
      expect(db, closeTo(0.0, 0.1));
    });

    test('rmsDbfs of half-scale (16384) ≈ -6 dBFS', () {
      final ms = 16384.0 * 16384.0;
      final db = rmsDbfs(ms);
      // Exact: 20*log10(16384/32768) = -6.0206 dB.
      expect(db, closeTo(-6.02, 0.1));
    });

    test('rmsDbfs of tenth-scale (3276.8) ≈ -20 dBFS', () {
      // 32768 / 10 = 3276.8.
      final amp = 32768.0 / 10.0;
      final ms = amp * amp;
      final db = rmsDbfs(ms);
      expect(db, closeTo(-20.0, 0.1));
    });

    test('rmsDbfs floors at -120 even for tiny but positive values', () {
      // 1e-30 is way below the -120 dB floor.
      expect(rmsDbfs(1e-30), -120.0);
    });
  });

  group('integration: meanSquare + rmsDbfs', () {
    test('full-scale through both stages ≈ 0 dBFS', () {
      final bytes = _int16Bytes(320, 32767, alternate: true);
      expect(rmsDbfs(meanSquare(bytes)), closeTo(0.0, 0.1));
    });

    test('silence through both stages → -120 dBFS', () {
      final bytes = Uint8List(640);
      expect(rmsDbfs(meanSquare(bytes)), -120.0);
    });
  });
}
