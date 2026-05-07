/// One-shot fixture generator for the classifier integration tests.
///
/// Writes three 3-second 16 kHz mono int16 WAV files into
/// `test/fixtures/classifier/`:
///
///   - `silence.wav`         — all zeros
///   - `broadband_noise.wav` — seeded uniform white noise, peak ~1/4 FS
///   - `tone_200hz.wav`      — pure 200 Hz cosine, peak ~1/4 FS
///
/// Run once, commit the output, do NOT run from the test suite. Tests read
/// the committed bytes — generating on the fly hides the data and slows
/// the runner.
///
/// Usage (from `did_i_snore/`):
///   dart run tool/gen_classifier_fixtures.dart
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

const int _sampleRateHz = 16000; // mirrors AudioCfg.sampleRateHz
const int _channels = 1;
const int _bitsPerSample = 16;
const int _seconds = 3;
const int _frames = _sampleRateHz * _seconds; // 48000

/// Reproducible seed for the broadband noise fixture. Pinned so the file
/// can be regenerated bit-for-bit if it's ever lost.
const int _noiseSeed = 0xDEC0DE;

/// Peak amplitude as a fraction of int16 full-scale. 0.25 = -12 dBFS,
/// keeps sine + noise out of clipping while still being loud enough that
/// YAMNet's input-range path is exercised.
const double _peakFrac = 0.25;

void main() {
  final outDir = Directory('test/fixtures/classifier');
  if (!outDir.existsSync()) outDir.createSync(recursive: true);

  _writeWav(
    File('${outDir.path}/silence.wav'),
    Int16List(_frames), // all zeros
  );

  _writeWav(
    File('${outDir.path}/broadband_noise.wav'),
    _whiteNoise(_noiseSeed, _frames, _peakFrac),
  );

  _writeWav(
    File('${outDir.path}/tone_200hz.wav'),
    _cosine(200.0, _frames, _peakFrac),
  );

  stdout.writeln('Wrote 3 fixtures to ${outDir.path}/');
}

Int16List _cosine(double freqHz, int n, double peak) {
  final out = Int16List(n);
  final twoPi = 2 * math.pi;
  final amp = (peak * 32767).round();
  for (var i = 0; i < n; i++) {
    out[i] = (amp * math.cos(twoPi * freqHz * i / _sampleRateHz)).round();
  }
  return out;
}

Int16List _whiteNoise(int seed, int n, double peak) {
  final rng = math.Random(seed);
  final out = Int16List(n);
  final amp = (peak * 32767).round();
  for (var i = 0; i < n; i++) {
    out[i] = (amp * (2.0 * rng.nextDouble() - 1.0)).round();
  }
  return out;
}

/// Write a 44-byte canonical PCM WAV file (RIFF/WAVE/fmt/data, no LIST or
/// FACT chunks). Format: 16-bit signed little-endian PCM.
void _writeWav(File f, Int16List samples) {
  final dataBytes = samples.lengthInBytes;
  final byteRate = _sampleRateHz * _channels * _bitsPerSample ~/ 8;
  final blockAlign = _channels * _bitsPerSample ~/ 8;
  final riffSize = 36 + dataBytes;

  final buf = BytesBuilder();
  buf.add(_ascii('RIFF'));
  buf.add(_u32le(riffSize));
  buf.add(_ascii('WAVE'));

  buf.add(_ascii('fmt '));
  buf.add(_u32le(16)); // PCM fmt chunk size
  buf.add(_u16le(1)); // audioFormat = 1 (PCM)
  buf.add(_u16le(_channels));
  buf.add(_u32le(_sampleRateHz));
  buf.add(_u32le(byteRate));
  buf.add(_u16le(blockAlign));
  buf.add(_u16le(_bitsPerSample));

  buf.add(_ascii('data'));
  buf.add(_u32le(dataBytes));
  buf.add(samples.buffer.asUint8List(
    samples.offsetInBytes,
    samples.lengthInBytes,
  ));

  f.writeAsBytesSync(buf.toBytes(), flush: true);
  stdout.writeln(
    '  ${f.path}  (${samples.length} samples, ${buf.length} bytes)',
  );
}

List<int> _ascii(String s) => s.codeUnits;

Uint8List _u16le(int v) {
  final b = ByteData(2)..setUint16(0, v, Endian.little);
  return b.buffer.asUint8List();
}

Uint8List _u32le(int v) {
  final b = ByteData(4)..setUint32(0, v, Endian.little);
  return b.buffer.asUint8List();
}
