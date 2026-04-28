/// Contract tests for `EventWindow`.
///
/// Each event window is a single contiguous PCM blob: pre-roll + live + tail.
/// `takePcm` is single-use; `firstSamplesAsFloat32` is what the spectral
/// probe reads. Both contracts have to hold even when chunks arrive at odd
/// boundaries (the slicer's tail behaviour means callers don't get neat
/// round-numbered chunks).
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:did_i_snore/config/constants.dart';
import 'package:did_i_snore/recorder/event_window.dart';

const int _bytesPerMs = AudioCfg.sampleRateHz * 2 ~/ 1000; // 32

/// Build `n` int16 samples at the given amplitude, alternating sign,
/// returned as little-endian bytes.
Uint8List _int16Bytes(int numSamples, int magnitude) {
  final samples = Int16List(numSamples);
  for (var i = 0; i < numSamples; i++) {
    samples[i] = i.isOdd ? -magnitude : magnitude;
  }
  return Uint8List.view(samples.buffer);
}

void main() {
  group('EventWindow — construction', () {
    test('pre-roll is included at construction', () {
      final preRoll = Uint8List(64000); // 2 seconds at 16 kHz mono int16
      final w = EventWindow(123, preRoll);
      expect(w.totalBytes, 64000);
      expect(w.durationMs, 2000);
      expect(w.startMs, 123);
    });

    test('empty pre-roll is allowed', () {
      final w = EventWindow(0, Uint8List(0));
      expect(w.totalBytes, 0);
      expect(w.durationMs, 0);
    });
  });

  group('EventWindow — appendChunk', () {
    test('appendChunk accumulates', () {
      final w = EventWindow(0, Uint8List(0));
      w.appendChunk(Uint8List(32000));
      expect(w.totalBytes, 32000);
      expect(w.durationMs, 1000);
    });

    test('multiple appends sum correctly', () {
      final w = EventWindow(0, Uint8List(0));
      w.appendChunk(Uint8List(640));
      w.appendChunk(Uint8List(640));
      w.appendChunk(Uint8List(1920));
      expect(w.totalBytes, 3200);
      expect(w.durationMs, 100);
    });

    test('multiple appendChunk calls do not change startMs', () {
      // startMs is the wall-clock anchor for the event; it must be set
      // once at construction and never mutated by chunk arrivals.
      final w = EventWindow(54321, Uint8List(0));
      expect(w.startMs, 54321);
      w.appendChunk(Uint8List(640));
      expect(w.startMs, 54321);
      w.appendChunk(Uint8List(1280));
      expect(w.startMs, 54321);
    });
  });

  group('EventWindow — takePcm', () {
    test('takePcm returns concat of preRoll + appended chunks in order', () {
      final w = EventWindow(0, Uint8List.fromList([1, 2, 3, 4]));
      w.appendChunk(Uint8List.fromList([5, 6]));
      w.appendChunk(Uint8List.fromList([7, 8, 9, 10]));

      final pcm = w.takePcm();
      expect(pcm, orderedEquals([1, 2, 3, 4, 5, 6, 7, 8, 9, 10]));
    });

    test('takePcm is single-use; subsequent calls throw StateError', () {
      final w = EventWindow(0, Uint8List.fromList([1, 2]));
      w.appendChunk(Uint8List.fromList([3, 4]));

      final pcm = w.takePcm();
      expect(pcm, orderedEquals([1, 2, 3, 4]));
      expect(w.takePcm, throwsStateError);
    });
  });

  group('EventWindow — durationMs', () {
    test('32 bytes → 1ms', () {
      final w = EventWindow(0, Uint8List(_bytesPerMs));
      expect(w.durationMs, 1);
    });

    test('32000 bytes → 1000ms', () {
      final w = EventWindow(0, Uint8List(32000));
      expect(w.durationMs, 1000);
    });

    test('64000 bytes → 2000ms', () {
      final w = EventWindow(0, Uint8List(64000));
      expect(w.durationMs, 2000);
    });
  });

  group('EventWindow — firstSamplesAsFloat32', () {
    test(
        'returns the first n samples post-pre-roll, normalised to [-1, 1] '
        'against int16 full scale', () {
      // 64000-byte all-zero pre-roll then 1024 known int16 samples in a
      // single appendChunk. firstSamplesAsFloat32(1024) must return the
      // 1024-element float view of those bytes.
      const knownSamples = 1024;
      const magnitude = 16384; // exactly half-scale
      final preRoll = Uint8List(64000); // 2000 ms of silence
      final w = EventWindow(0, preRoll);
      w.appendChunk(_int16Bytes(knownSamples, magnitude));

      final out = w.firstSamplesAsFloat32(knownSamples);
      expect(out.length, knownSamples);

      // Half-scale int16 → ±0.5 in float (32768.0 normalisation).
      for (var i = 0; i < knownSamples; i++) {
        final expected = (i.isOdd ? -magnitude : magnitude) / 32768.0;
        expect(out[i], closeTo(expected, 1e-6),
            reason: 'sample $i should be $expected');
      }
    });

    test('shorter-than-requested event returns whatever is available', () {
      // CONTRACT NOTE: the implementation hard-codes the post-pre-roll
      // offset at AudioCfg.preRollMs * 32 = 64000 bytes (i.e. "the
      // canonical 2 s pre-roll"), NOT at `preRoll.length` from the
      // constructor. So we set up a full 64000-byte pre-roll and then
      // append 320 samples (= 640 bytes); requesting 1024 samples returns
      // the 320 we have.
      const present = 320;
      final preRoll = Uint8List(64000);
      final w = EventWindow(0, preRoll);
      w.appendChunk(_int16Bytes(present, 8000));

      final out = w.firstSamplesAsFloat32(1024);
      // Contract: we get back what was available; we don't fabricate
      // padding and we don't crash.
      expect(out.length, lessThanOrEqualTo(1024));
      expect(out.length, present);
      // Spot-check a sample.
      expect(out[0], closeTo(8000 / 32768.0, 1e-6));
    });

    test(
        'with an under-full pre-roll, the canonical 64000-byte offset still '
        'applies — request returns empty', () {
      // Pin the surprise so it is loud the next time someone refactors:
      // the post-pre-roll offset is the constant `AudioCfg.preRollMs * 32`,
      // not the actual `preRoll.length`. In the first ~2 s of a recorder
      // session the ring is not full yet; if a gate-open fired then, the
      // EventWindow is constructed with a smaller pre-roll, and the
      // spectral probe slice would be empty/short until enough body bytes
      // have accumulated past the 64000 mark. This is a regression test
      // for that — change at your peril.
      final shortPreRoll = Uint8List(32000); // only 1 s of pre-roll
      final w = EventWindow(0, shortPreRoll);
      w.appendChunk(_int16Bytes(320, 8000));

      final out = w.firstSamplesAsFloat32(1024);
      // 32000 + 640 = 32640 bytes; that's well under the 64000 cutoff,
      // so nothing is returned. If the contract changes to "skip
      // preRoll.length bytes" this test should be updated and the spec
      // §4.3 wording revisited.
      expect(out.length, 0,
          reason: 'firstSamplesAsFloat32 indexes from the canonical '
              '64000-byte mark, not from the actual preRoll length');
    });
  });
}
