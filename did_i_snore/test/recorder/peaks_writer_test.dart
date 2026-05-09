/// Tests for `peaks_writer.dart` — the Phase 8-enabling sidecar
/// generator. Spec §6.4 lines 816–818.
///
/// The writer is a pure function over `(pcm, audioRelPath, docsDir)`;
/// every test runs against a per-test `Directory.systemTemp` partition
/// and asserts the on-disk shape (size, format, atomicity) plus the
/// peaks math (silent → all-zero, sine → non-zero, count == 200, range
/// in [0, 1]). Host-runnable; no plugins.
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:did_i_snore/config/constants.dart';
import 'package:did_i_snore/recorder/peaks_writer.dart';

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('snore_peaks_test_');
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  /// Build a day-partition + final opus file at `<tempDir>/<rel>` so
  /// the writer can drop a sidecar next to it. The encoder normally
  /// creates the parent directory; we mirror that here.
  Future<void> writeStubAudio(String rel) async {
    final f = File(p.join(tempDir.path, rel));
    await f.parent.create(recursive: true);
    await f.writeAsBytes(const [0x00], flush: true);
  }

  /// Read the peaks sidecar back as a `Float32List`. Mirrors the
  /// player's expected read path.
  Float32List readPeaks(String relPath) {
    final bytes = File(p.join(tempDir.path, relPath)).readAsBytesSync();
    return Float32List.view(
      Uint8List.fromList(bytes).buffer,
      0,
      bytes.length ~/ 4,
    );
  }

  group('writeEventPeaks output shape', () {
    test(
        'writes exactly PeaksCfg.peakCount × 4 bytes; returned relPath '
        'has the .peaks extension', () async {
      const audioRel = 'events/2026-05-08/100.opus';
      await writeStubAudio(audioRel);

      // Constant non-zero PCM so we can also sanity-check the value.
      final pcm = Int16List(8000);
      for (var i = 0; i < pcm.length; i++) {
        pcm[i] = 16384; // half-scale → 0.5 normalised peak
      }

      final returned = await writeEventPeaks(
        pcm: pcm,
        audioRelPath: audioRel,
        docsDir: tempDir,
      );

      expect(returned, 'events/2026-05-08/100${PeaksCfg.peaksExtension}',
          reason: 'returned path must be the audioRel with the extension '
              'swapped via p.setExtension — single convention with the '
              'player');

      final peaksFile = File(p.join(tempDir.path, returned));
      expect(await peaksFile.exists(), isTrue);

      final size = await peaksFile.length();
      expect(size, PeaksCfg.peakCount * 4,
          reason: 'file size must be peakCount × float32 = '
              '${PeaksCfg.peakCount * 4} bytes; no header, no trailer');
    });

    test('produces exactly PeaksCfg.peakCount float32 values', () async {
      const audioRel = 'events/2026-05-08/200.opus';
      await writeStubAudio(audioRel);

      final pcm = Int16List(8000); // all zero
      final returned = await writeEventPeaks(
        pcm: pcm,
        audioRelPath: audioRel,
        docsDir: tempDir,
      );

      final peaks = readPeaks(returned);
      expect(peaks.length, PeaksCfg.peakCount,
          reason: 'count is constant regardless of duration');
    });

    test('all peak values lie in [0.0, 1.0]', () async {
      const audioRel = 'events/2026-05-08/300.opus';
      await writeStubAudio(audioRel);

      // Mix of zero, half-scale, and full-scale samples to exercise
      // both ends of the [0, 1] range.
      final pcm = Int16List(8000);
      for (var i = 0; i < pcm.length; i++) {
        pcm[i] = (i % 3 == 0)
            ? 0
            : (i % 3 == 1)
                ? 16384
                : 32767;
      }

      final returned = await writeEventPeaks(
        pcm: pcm,
        audioRelPath: audioRel,
        docsDir: tempDir,
      );
      final peaks = readPeaks(returned);

      for (final v in peaks) {
        expect(v, greaterThanOrEqualTo(0.0));
        expect(v, lessThanOrEqualTo(1.0));
      }
    });
  });

  group('writeEventPeaks math', () {
    test('silent PCM produces all-zero peaks', () async {
      const audioRel = 'events/2026-05-08/silent.opus';
      await writeStubAudio(audioRel);

      final pcm = Int16List(16000); // 1s of silence

      final returned = await writeEventPeaks(
        pcm: pcm,
        audioRelPath: audioRel,
        docsDir: tempDir,
      );
      final peaks = readPeaks(returned);

      for (final v in peaks) {
        expect(v, 0.0,
            reason: 'silence in → zeros out; any non-zero is a math bug');
      }
    });

    test(
        'sine-wave PCM produces non-zero peaks; full-scale sine yields '
        'peaks ≈ 1.0', () async {
      const audioRel = 'events/2026-05-08/sine.opus';
      await writeStubAudio(audioRel);

      // Full-scale 440 Hz sine, 1s @ 16 kHz.
      final pcm = Int16List(AudioCfg.sampleRateHz);
      for (var i = 0; i < pcm.length; i++) {
        final s = math.sin(2 * math.pi * 440 * i / AudioCfg.sampleRateHz);
        pcm[i] = (s * 32767).round();
      }

      final returned = await writeEventPeaks(
        pcm: pcm,
        audioRelPath: audioRel,
        docsDir: tempDir,
      );
      final peaks = readPeaks(returned);

      // Every slice has plenty of cycles (16000/200 = 80 samples ≈
      // 1.8 cycles at 440 Hz), so each peak should approach 1.0.
      for (final v in peaks) {
        expect(v, greaterThan(0.9),
            reason: 'each slice spans ~1.8 cycles of a full-scale sine; '
                'the absolute max should be near 32767/32768 ≈ 0.9999');
      }
    });

    test(
        'half-scale constant PCM yields uniform peaks of ~0.5', () async {
      const audioRel = 'events/2026-05-08/half.opus';
      await writeStubAudio(audioRel);

      final pcm = Int16List(8000);
      for (var i = 0; i < pcm.length; i++) {
        pcm[i] = 16384;
      }

      final returned = await writeEventPeaks(
        pcm: pcm,
        audioRelPath: audioRel,
        docsDir: tempDir,
      );
      final peaks = readPeaks(returned);

      for (final v in peaks) {
        expect(v, closeTo(0.5, 1e-4),
            reason: '16384 / 32768 = 0.5 exactly');
      }
    });

    test('-32768 (int16 minimum) saturates to 1.0, not 1.000031...',
        () async {
      // The writer clamps; verify the clamp branch fires for the only
      // input that needs it.
      const audioRel = 'events/2026-05-08/saturate.opus';
      await writeStubAudio(audioRel);

      final pcm = Int16List(8000);
      for (var i = 0; i < pcm.length; i++) {
        pcm[i] = -32768;
      }

      final returned = await writeEventPeaks(
        pcm: pcm,
        audioRelPath: audioRel,
        docsDir: tempDir,
      );
      final peaks = readPeaks(returned);

      for (final v in peaks) {
        expect(v, 1.0,
            reason: '|−32768| / 32768 = 1.000030... must clamp to 1.0');
      }
    });
  });

  group('writeEventPeaks atomicity + IO', () {
    test('no .tmp file remains after a successful write', () async {
      const audioRel = 'events/2026-05-08/atom.opus';
      await writeStubAudio(audioRel);

      final pcm = Int16List(8000);

      final returned = await writeEventPeaks(
        pcm: pcm,
        audioRelPath: audioRel,
        docsDir: tempDir,
      );

      final tmp = File(p.join(
          tempDir.path, '$returned${PathsCfg.tmpSuffix}'));
      expect(await tmp.exists(), isFalse,
          reason: 'atomic rename must move <peaks>.tmp → <peaks>; the '
              '.tmp must not survive on the happy path');
      expect(
          await File(p.join(tempDir.path, returned)).exists(), isTrue);
    });

    test('overwrites a stale final peaks file via atomic rename',
        () async {
      const audioRel = 'events/2026-05-08/stale.opus';
      await writeStubAudio(audioRel);

      // Pre-seed a sentinel "old" peaks file so we can verify the
      // rename overwrote it.
      final peaksRel = p.setExtension(audioRel, PeaksCfg.peaksExtension);
      final stale = File(p.join(tempDir.path, peaksRel));
      await stale.parent.create(recursive: true);
      await stale.writeAsBytes(List<int>.filled(16, 0xAA));

      final pcm = Int16List(8000);
      final returned = await writeEventPeaks(
        pcm: pcm,
        audioRelPath: audioRel,
        docsDir: tempDir,
      );

      final size = await File(p.join(tempDir.path, returned)).length();
      expect(size, PeaksCfg.peakCount * 4,
          reason: 'rename overwrote the 16-byte stale file with the '
              'fresh ${PeaksCfg.peakCount * 4}-byte output');
    });
  });

  group('writeEventPeaks contract violations', () {
    test('audioRelPath without .opus trips the assert (debug builds)',
        () async {
      // The writer is best-effort about the *output* path, but the
      // *input* path must be canonical — anything else is a caller bug
      // we want loud, not a peaks file landing under a wrong extension.
      // `assert` only fires in debug; flutter_test always runs in debug.
      const audioRel = 'events/2026-05-08/wrong.wav';
      await writeStubAudio(audioRel);

      expect(
        () => writeEventPeaks(
          pcm: Int16List(8000),
          audioRelPath: audioRel,
          docsDir: tempDir,
        ),
        throwsA(isA<AssertionError>()),
        reason: 'a non-.opus audioRelPath must trip the assert rather '
            'than silently writing a .peaks under the wrong stem',
      );
    });
  });
}
