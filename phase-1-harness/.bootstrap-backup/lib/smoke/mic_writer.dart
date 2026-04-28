// THROWAWAY HARNESS - Phase 2 will rebuild this properly with the constants
// from lib/config/constants.dart.
//
// MicWriter
//
// - Captures int16 PCM @ 16 kHz mono via `record` 5.x startStream + pcm16bits.
// - Writes 30-second segments to:
//     <applicationDocumentsDirectory>/smoke/YYYY-MM-DD/HH-MM-SS.pcm
// - Counts bytes carefully so the heartbeat invariant
//     1,920,000 bytes/min ± 5%
//   reflects mic aliveness, not writer aliveness.
//
// Counting policy: bytes are added to `_totalBytesWritten` only AFTER they have
// been written to the segment file successfully. If `record` silently stops
// delivering bytes (suspended audio session, HAL stall), the counter freezes
// and the heartbeat will report zero bytes since the last sample — which is
// the silent-mic failure we're trying to catch.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import 'heartbeat.dart';

class MicWriter {
  MicWriter({required this.heartbeat});

  // 16 kHz mono int16 -> exactly 32,000 bytes/second.
  static const int sampleRateHz = 16000;
  static const int numChannels = 1;
  static const int bytesPerSample = 2;
  static const int bytesPerSecond =
      sampleRateHz * numChannels * bytesPerSample;

  // 30-second segments.
  static const Duration segmentDuration = Duration(seconds: 30);
  static const int segmentBytes = bytesPerSecond * 30; // 960,000 bytes

  final HeartbeatWriter heartbeat;
  final AudioRecorder _recorder = AudioRecorder();

  StreamSubscription<Uint8List>? _sub;
  IOSink? _segmentSink;
  File? _currentSegmentFile;
  int _currentSegmentBytes = 0;

  int _totalBytesWritten = 0;

  bool _running = false;
  bool get isRunning => _running;
  int get totalBytesWritten => _totalBytesWritten;
  String get currentSegmentFile => _currentSegmentFile?.path ?? '';

  /// Start streaming. The caller must already hold mic permission.
  Future<void> start() async {
    if (_running) return;

    final hasPerm = await _recorder.hasPermission();
    if (!hasPerm) {
      throw StateError('Microphone permission not granted');
    }

    // Open the first segment before subscribing so we never lose initial bytes.
    await _rotateSegment();

    final stream = await _recorder.startStream(
      const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: sampleRateHz,
        numChannels: numChannels,
        // record 5.x: autoGain / echoCancel / noiseSuppress default to false,
        // which is what we want for a measurement harness.
      ),
    );

    _running = true;
    _sub = stream.listen(
      _onChunk,
      onError: (Object e, StackTrace st) {
        // Surface but do not crash the isolate. The heartbeat will reveal
        // the silence; the GAP marker is written by the interruption handler.
        // ignore: avoid_print
        print('mic stream error: $e');
      },
      onDone: () {
        // Stream ended unexpectedly. Mark a service-kill style gap; the
        // recorder coordinator will decide whether to restart.
        // ignore: avoid_print
        print('mic stream closed');
      },
      cancelOnError: false,
    );

    // Wire up the heartbeat once the writer state exists.
    heartbeat.bind(
      totalBytesProvider: () => _totalBytesWritten,
      currentSegmentFileProvider: () => currentSegmentFile,
    );
  }

  Future<void> stop() async {
    if (!_running) return;
    _running = false;
    await _sub?.cancel();
    _sub = null;
    try {
      await _recorder.stop();
    } catch (_) {
      // best-effort
    }
    await _closeCurrentSegment();
  }

  Future<void> _onChunk(Uint8List chunk) async {
    if (!_running) return;
    if (chunk.isEmpty) return;

    var offset = 0;
    while (offset < chunk.length) {
      final remaining = chunk.length - offset;
      final spaceInSegment = segmentBytes - _currentSegmentBytes;

      if (spaceInSegment <= 0) {
        await _rotateSegment();
        continue;
      }

      final take = remaining < spaceInSegment ? remaining : spaceInSegment;
      final view =
          Uint8List.sublistView(chunk, offset, offset + take);

      // Write first; only count bytes once they are in the file.
      _segmentSink!.add(view);
      _currentSegmentBytes += take;
      _totalBytesWritten += take;
      offset += take;
    }
  }

  Future<void> _rotateSegment() async {
    await _closeCurrentSegment();

    final now = DateTime.now();
    final dir = await getApplicationDocumentsDirectory();
    final dayDir = Directory(p.join(
      dir.path,
      'smoke',
      _ymd(now),
    ));
    if (!await dayDir.exists()) {
      await dayDir.create(recursive: true);
    }

    final file = File(p.join(dayDir.path, '${_hms(now)}.pcm'));
    _currentSegmentFile = file;
    _currentSegmentBytes = 0;
    _segmentSink = file.openWrite(mode: FileMode.write);
  }

  Future<void> _closeCurrentSegment() async {
    final sink = _segmentSink;
    _segmentSink = null;
    if (sink == null) return;
    try {
      await sink.flush();
      await sink.close();
    } catch (_) {
      // best-effort
    }
  }

  // ---- helpers ----

  static String _ymd(DateTime dt) {
    final y = dt.year.toString().padLeft(4, '0');
    final m = dt.month.toString().padLeft(2, '0');
    final d = dt.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }

  static String _hms(DateTime dt) {
    final h = dt.hour.toString().padLeft(2, '0');
    final m = dt.minute.toString().padLeft(2, '0');
    final s = dt.second.toString().padLeft(2, '0');
    return '$h-$m-$s';
  }
}
