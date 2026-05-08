/// Integration tests for `encodeEventToOpus` — Phase 7 §7.1.
///
/// These tests need the native `ffmpeg_kit_flutter_new_audio` plugin
/// loaded, which doesn't happen on Linux desktop CI. Mirrors the
/// skip-on-host pattern from `test/classifier/yamnet_test.dart`: each
/// test starts with `if (shouldSkip()) return;` so a device run picks
/// them up while the host run cleanly skips.
///
/// We do NOT assert acoustic fidelity (e.g. "decoded sine round-trips
/// with PSNR > X") — that's a codec-quality test, and the codec is the
/// reference implementation. The point of this file is to pin the
/// wiring: the file lands at the canonical relative path, the .tmp
/// suffix is gone after success, the scratch .pcm in systemTemp is
/// cleaned up, and the day-partition directory is created on demand.
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ffmpeg_kit_flutter_new_audio/ffmpeg_kit.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:did_i_snore/config/constants.dart';
import 'package:did_i_snore/recorder/opus_encoder.dart';

/// Ogg page magic. Spec: every Opus-in-Ogg file starts with `OggS`.
const List<int> _oggMagic = [0x4F, 0x67, 0x67, 0x53];

/// Synthesizes [seconds] seconds of a [freqHz] sine at peak amplitude
/// [peak] (int16), at `AudioCfg.sampleRateHz`. Used as a deterministic
/// non-silent input — silent input is fine for ffmpeg but harder to
/// distinguish from a degenerate empty-input bug.
Int16List _synthSine({
  required double freqHz,
  required double seconds,
  int peak = 8000,
}) {
  final n = (AudioCfg.sampleRateHz * seconds).round();
  final out = Int16List(n);
  final twoPi = 2 * math.pi;
  for (var i = 0; i < n; i++) {
    final t = i / AudioCfg.sampleRateHz;
    out[i] = (peak * math.sin(twoPi * freqHz * t)).round();
  }
  return out;
}

/// Snapshots the count of `dis_encode_*` files in `Directory.systemTemp`.
/// Filtered to that prefix so other tests' temp files don't bias the
/// before/after diff. Matches the prefix the encoder uses in
/// `lib/recorder/opus_encoder.dart`.
int _countScratchPcm() {
  final tmp = Directory.systemTemp;
  if (!tmp.existsSync()) return 0;
  return tmp
      .listSync(followLinks: false)
      .whereType<File>()
      .where((f) => p.basename(f.path).startsWith('dis_encode_'))
      .length;
}

void main() {
  // Skip the whole file when ffmpeg's native side isn't available
  // (Linux CI). On device this passes through and the tests run.
  String? skipReason;

  bool shouldSkip() {
    final reason = skipReason;
    if (reason != null) {
      markTestSkipped(reason);
      return true;
    }
    return false;
  }

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    try {
      // Cheapest possible probe: ask ffmpeg for its version. If the
      // plugin's native channel is missing (Linux host) this throws a
      // MissingPluginException; on a real device it returns success
      // and we proceed.
      await FFmpegKit.execute('-version');
    } catch (e, st) {
      skipReason = 'FFmpegKit not available on this platform '
          '(likely Linux host without the native plugin): $e';
      // ignore: avoid_print
      print('[opus_encoder_test] $skipReason\n$st');
    }
  });

  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('snore_opus_test_');
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  group('encodeEventToOpus — integration', () {
    test('encodes a 1-second 200 Hz sine to a valid opus file', () async {
      if (shouldSkip()) return;
      final pcm = _synthSine(freqHz: 200.0, seconds: 1.0);
      final out = await encodeEventToOpus(
        pcm: pcm,
        relPath: 'events/2026-05-08/test1.opus',
        docsDir: tempDir,
      );

      expect(await out.exists(), isTrue,
          reason: 'encoder must return a File pointing at an existing path');

      final size = await out.length();
      // Opus voip @ 24 kbps for 1 s → ~3 KB. Loose bounds protect against
      // a regression that writes the raw PCM (32 KB) or a 0-byte file.
      expect(size, greaterThan(100),
          reason: '0-byte output suggests the rename ran on an empty .tmp');
      expect(size, lessThan(10000),
          reason: 'output is suspiciously large for 1 s of voip @ 24 kbps');

      // Ogg magic — first 4 bytes must be `OggS`.
      final head = await out.openRead(0, 4).expand((c) => c).toList();
      expect(head, _oggMagic,
          reason: 'opus-in-ogg files must start with OggS magic; got $head');
    });

    test('atomic rename: .tmp file is gone after a successful encode',
        () async {
      if (shouldSkip()) return;
      final pcm = _synthSine(freqHz: 200.0, seconds: 1.0);
      const relPath = 'events/2026-05-08/test_atomic.opus';
      await encodeEventToOpus(pcm: pcm, relPath: relPath, docsDir: tempDir);

      final tmp = File(p.join(tempDir.path, '$relPath${PathsCfg.tmpSuffix}'));
      expect(await tmp.exists(), isFalse,
          reason: 'after successful encode the .tmp file must have been '
              'renamed away — leaving it behind would confuse the orphan '
              'sweep');
    });

    test('scratch .pcm cleanup on success: systemTemp count unchanged',
        () async {
      if (shouldSkip()) return;
      final before = _countScratchPcm();
      final pcm = _synthSine(freqHz: 200.0, seconds: 0.5);
      await encodeEventToOpus(
        pcm: pcm,
        relPath: 'events/2026-05-08/test_cleanup.opus',
        docsDir: tempDir,
      );
      final after = _countScratchPcm();
      expect(after, before,
          reason: 'finally-block cleanup must remove the dis_encode_*.pcm '
              'scratch file; leaks here will eventually fill /tmp');
    });

    test('scratch .pcm cleanup on failure: systemTemp count unchanged',
        () async {
      if (shouldSkip()) return;
      final before = _countScratchPcm();

      // Two strategies for forcing a failure; we try empty PCM first
      // (some ffmpeg builds error on zero-byte input) and fall back to
      // an unwritable output path if that doesn't trigger. The cleanup
      // assertion fires regardless of which trigger fired.
      var failureSeen = false;
      try {
        await encodeEventToOpus(
          pcm: Int16List(0),
          relPath: 'events/2026-05-08/empty.opus',
          docsDir: tempDir,
        );
      } on StateError {
        failureSeen = true;
      }

      if (!failureSeen) {
        // Empty input was tolerated — fall back to a path the OS won't
        // let us write. ffmpeg will fail on the output side; our cleanup
        // guarantee is what we're after either way.
        try {
          await encodeEventToOpus(
            pcm: _synthSine(freqHz: 200.0, seconds: 0.1),
            // Nested .. trick gets us out of tempDir into a likely-
            // unwritable area. If the host is permissive this still
            // exercises the failure path because the rename target is
            // inside a non-existent root.
            relPath: '../../../nonexistent/cannot_write.opus',
            docsDir: Directory('/proc/self/cannot_write'),
          );
        } on Object {
          failureSeen = true;
        }
      }

      expect(failureSeen, isTrue,
          reason: 'expected at least one of empty-input / unwritable-path '
              'to surface a failure for the cleanup assertion to be '
              'meaningful');

      final after = _countScratchPcm();
      expect(after, before,
          reason: 'finally-block cleanup must run on the failure path too');
    });

    test('creates the day-partition directory if missing', () async {
      if (shouldSkip()) return;
      // 2099 ensures the directory really doesn't pre-exist in tempDir.
      const relPath = 'events/2099-12-31/foo.opus';
      final dayDir = Directory(p.join(tempDir.path, 'events', '2099-12-31'));
      expect(dayDir.existsSync(), isFalse,
          reason: 'precondition: day partition must not exist before encode');

      final pcm = _synthSine(freqHz: 200.0, seconds: 0.5);
      await encodeEventToOpus(pcm: pcm, relPath: relPath, docsDir: tempDir);

      expect(dayDir.existsSync(), isTrue,
          reason: 'encoder must mkdir -p the day partition on demand; '
              'this is what the recorder relies on for the very first '
              'event of a new day');
    });

    test(
        'overwrites an existing .tmp from a prior crashed run; final file '
        'is valid Ogg, not the corrupt content',
        () async {
      if (shouldSkip()) return;
      const relPath = 'events/2026-05-08/test_overwrite.opus';
      final outPath = p.join(tempDir.path, relPath);
      final tmpPath = '$outPath${PathsCfg.tmpSuffix}';

      // Pre-create the day directory + a junk .tmp simulating a process
      // that died between ffmpeg-write and rename.
      await Directory(p.dirname(outPath)).create(recursive: true);
      await File(tmpPath).writeAsBytes('corrupt'.codeUnits);
      expect(await File(tmpPath).exists(), isTrue,
          reason: 'precondition: the junk .tmp must exist before encode');

      final pcm = _synthSine(freqHz: 200.0, seconds: 0.5);
      await encodeEventToOpus(pcm: pcm, relPath: relPath, docsDir: tempDir);

      final finalFile = File(outPath);
      expect(await finalFile.exists(), isTrue);

      // Final file is real Ogg, not the literal "corrupt" string.
      final head = await finalFile.openRead(0, 4).expand((c) => c).toList();
      expect(head, _oggMagic,
          reason: 'a stale .tmp from a prior crash must be overwritten by '
              'the new encode; final file must be valid Ogg');

      // And the .tmp is gone (rename consumed it).
      expect(await File(tmpPath).exists(), isFalse);
    });
  });
}
