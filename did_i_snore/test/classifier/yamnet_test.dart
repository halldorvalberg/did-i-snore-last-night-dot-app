/// Integration tests for the YAMNet classifier.
///
/// These tests need the real `tflite_flutter` runtime + the bundled model
/// asset; they cannot use channel stubs the way the recorder tests do.
/// On Linux desktop in CI the native library is typically not available,
/// so the whole group skips with a reason. On a host with the runtime, the
/// tests actually exercise inference end-to-end.
///
/// We do NOT assert "snore_clean.wav classifies as Snoring at confidence
/// > 0.7" anywhere — that's a model-quality assertion, not a wiring test,
/// and the synthetic fixtures here are by design acoustically nothing
/// like real snores. The point is to pin: the model loads, padding works,
/// the precision floor doesn't latch on a tone, and the output map only
/// contains curated bucket names (no raw AudioSet leakage).
///
/// Fixture provenance: `test/fixtures/classifier/*.wav` are committed
/// static files generated once by `tool/gen_classifier_fixtures.dart`.
/// Do not regenerate them from inside the test suite — generated-on-the-fly
/// data hides failure modes you can only see by opening the file in a
/// waveform viewer. The noise fixture's RNG seed is documented in that
/// generator (search for `_noiseSeed`).
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:did_i_snore/classifier/label_map.dart';
import 'package:did_i_snore/classifier/yamnet.dart';

const String _fixtureDir = 'test/fixtures/classifier';

/// The 11 curated buckets plus the `Other` catch-all. If `classify`'s
/// output ever contains a key outside this set, a raw AudioSet display
/// name has leaked through aggregation.
const Set<String> _allowedBuckets = {
  'Snoring',
  'Speech',
  'Whisper',
  'Cough',
  'Sneeze',
  'Throat clearing',
  'Belch',
  'Fart',
  'Hiccup',
  'Cat',
  'Dog',
  'Other',
};

/// Read the int16 PCM samples out of a 16 kHz mono WAV at [path].
///
/// Assumes the canonical 44-byte RIFF/WAVE/fmt/data layout that
/// `tool/gen_classifier_fixtures.dart` writes. We don't bother parsing
/// arbitrary WAVs (LIST chunks, FACT chunks, 24-bit, stereo) because the
/// test fixtures are tightly controlled.
Int16List _readMono16WavSamples(String path) {
  final bytes = File(path).readAsBytesSync();
  // Header is 44 bytes. Samples start at offset 44, little-endian int16.
  final view = ByteData.sublistView(bytes, 44);
  final n = view.lengthInBytes ~/ 2;
  final samples = Int16List(n);
  for (var i = 0; i < n; i++) {
    samples[i] = view.getInt16(i * 2, Endian.little);
  }
  return samples;
}

void main() {
  // Try to load the model once; if the native lib isn't available on this
  // platform, mark each test as skipped with a reason. We can't probe
  // more cheaply than this — `Interpreter.fromAsset` is what actually
  // loads the .so/.dylib.
  //
  // The skip is checked at the start of each test body (NOT via the
  // `test(..., skip: ...)` parameter): that parameter is captured when
  // `test()` is called, before `setUpAll` has run, so it always sees the
  // initial null. Running `markTestSkipped` from inside the body is the
  // documented escape hatch for runtime-determined skips.
  late final Yamnet yamnet;
  String? skipReason;

  /// Returns `true` if the test should bail out because the model isn't
  /// loaded. Callers must `return` immediately on `true` — `markTestSkipped`
  /// only records the skip, it does not abort the test body.
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
    yamnet = Yamnet();
    try {
      await yamnet.load();
    } catch (e, st) {
      skipReason = 'Yamnet.load() failed (likely tflite_flutter native lib '
          'not available on this platform): $e';
      // Print stack so a real failure during local runs is visible —
      // a skipped suite that's actually broken is the worst outcome.
      // ignore: avoid_print
      print('[yamnet_test] $skipReason\n$st');
    }
  });

  tearDownAll(() {
    if (skipReason == null) yamnet.close();
  });

  group('Yamnet — integration', () {
    test('load() completes and reports isLoaded', () {
      if (shouldSkip()) return;
      // Trivial smoke. Pinned because past flutter_tflite + asset-path
      // upgrades have silently broken model loading without surfacing
      // an exception until classify() is called.
      expect(yamnet.isLoaded, isTrue);
    });

    test('silence produces no high-confidence curated false-positives', () {
      if (shouldSkip()) return;
      final pcm = _readMono16WavSamples('$_fixtureDir/silence.wav');
      final result = yamnet.classify(pcm);

      // Every key must be a known bucket. No AudioSet leakage.
      for (final k in result.keys) {
        expect(_allowedBuckets.contains(k), isTrue,
            reason: 'unexpected key in classify() output: $k');
      }
      // No curated label may exceed 0.5 on pure silence. We can't pin
      // the result more tightly because the precision floor may zero
      // everything (yielding an empty map) or leave Other at some
      // non-zero value — either is fine, just no curated false-positive.
      for (final entry in result.entries) {
        if (entry.key == 'Other') continue;
        expect(entry.value, lessThan(0.5),
            reason: 'silence produced curated false-positive '
                '${entry.key}=${entry.value}');
      }
    });

    test('broadband noise classifies without crashing and returns finite scores',
        () {
      if (shouldSkip()) return;
      final pcm = _readMono16WavSamples('$_fixtureDir/broadband_noise.wav');
      final result = yamnet.classify(pcm);

      expect(result, isNotNull);
      // Different YAMNet variants yield different results on white noise,
      // so we don't assert specific labels — just structure and finiteness.
      for (final entry in result.entries) {
        expect(_allowedBuckets.contains(entry.key), isTrue,
            reason: 'unexpected key: ${entry.key}');
        expect(entry.value.isFinite, isTrue,
            reason: 'non-finite score for ${entry.key}: ${entry.value}');
        expect(entry.value, inInclusiveRange(0.0, 1.0),
            reason: '${entry.key} score out of [0,1]: ${entry.value}');
      }
    });

    test('200 Hz pure tone is not classified as Snoring above the keep threshold',
        () {
      if (shouldSkip()) return;
      // A pure tone at 200 Hz lives inside the 50–500 Hz snore band but
      // is acoustically nothing like a snore (no breath, no formants, no
      // harmonic stack). The precision floor + max-over-frames pipeline
      // should NOT produce a strong Snoring verdict — that would mean
      // YAMNet is latching on tonal energy alone.
      //
      // We assert the strongest practically meaningful claim: the recorder's
      // keep policy (LabelCfg.minTopCuratedForKeep = 0.3) shouldn't see
      // Snoring as the winning label with score > 0.3 on this fixture.
      final pcm = _readMono16WavSamples('$_fixtureDir/tone_200hz.wav');
      final result = yamnet.classify(pcm);

      final top = LabelMap.topLabel(result);

      final snoringScore = result['Snoring'] ?? 0.0;
      // Soft assertion: the pure-tone Snoring score should not pass the
      // keep threshold AND be the top label simultaneously.
      final isLatching = top.label == 'Snoring' && top.score >= 0.3;
      expect(isLatching, isFalse,
          reason: 'classifier latched Snoring on a pure 200 Hz tone: '
              'top=$top, snoringScore=$snoringScore, full=$result');
    });

    test('output map only contains curated bucket names — no raw AudioSet leakage',
        () {
      if (shouldSkip()) return;
      // Classify any fixture; the assertion is on the shape of the result.
      // If `aggregate()` ever stops folding unmapped classes into Other,
      // raw names like 'Snort' or 'Bark' would leak through here.
      final pcm = _readMono16WavSamples('$_fixtureDir/broadband_noise.wav');
      final result = yamnet.classify(pcm);

      for (final k in result.keys) {
        expect(_allowedBuckets.contains(k), isTrue,
            reason: 'classify() emitted non-curated key "$k" — likely a '
                'regression in LabelMap.aggregate or the curated bucket set');
      }
      // Specifically, the bucket-source names that should have been
      // folded must NOT appear at the top level.
      for (final raw in const ['Snort', 'Bark', 'Meow', 'Conversation']) {
        expect(result.containsKey(raw), isFalse,
            reason: 'raw AudioSet name "$raw" leaked through aggregate');
      }
    });

    test('empty PCM input is safely zero-padded, no exceptions', () {
      if (shouldSkip()) return;
      // The implementation pads to 15600 samples (0.975 s) before running
      // inference. Pure-zero input must not crash the model and must not
      // produce a high-confidence curated label.
      final result = yamnet.classify(Int16List(0));

      for (final entry in result.entries) {
        expect(_allowedBuckets.contains(entry.key), isTrue);
        expect(entry.value, inInclusiveRange(0.0, 1.0));
        if (entry.key != 'Other') {
          expect(entry.value, lessThan(0.5),
              reason: 'empty/padded input produced curated false-positive '
                  '${entry.key}=${entry.value}');
        }
      }
    });

    test('classify is repeatable: same input yields same output', () {
      if (shouldSkip()) return;
      // Pin determinism — the int8 dequantization path could harbour a
      // shared mutable buffer that breaks idempotence under repeated
      // calls. (`Interpreter.run` writes into a buffer we allocate per
      // call, but a future refactor that reuses one across calls without
      // clearing it would land here first.)
      final pcm = _readMono16WavSamples('$_fixtureDir/tone_200hz.wav');

      final r1 = yamnet.classify(pcm);
      final r2 = yamnet.classify(pcm);

      expect(r1.keys.toSet(), r2.keys.toSet(),
          reason: 'key set differs between identical classify() calls');
      for (final k in r1.keys) {
        expect(r2[k], r1[k],
            reason: 'score for $k changed between identical calls: '
                '${r1[k]} vs ${r2[k]}');
      }
    });
  });
}
