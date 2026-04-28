/// Mic capture source. Wraps `record` 6.x streaming PCM into a broadcast
/// stream of raw int16 mono 16 kHz bytes.
///
/// Hot-path discipline: this code runs all night on battery. No widgets, no
/// `setState`, no per-byte allocations. Chunks pass through as-is to the
/// downstream slicer + ring buffer.
///
/// `record` 6.2.0 API note: matches the IMPLEMENTATION.md 2.1 sketch
/// (`AudioRecorder`, `RecordConfig`, `startStream`, `hasPermission`). The
/// only addition is `androidConfig: AndroidRecordConfig(audioSource:
/// AndroidAudioSource.unprocessed)` to disable OS-level AGC / NS that would
/// distort calibration thresholds. The enum is `AndroidAudioSource`, not
/// `AudioSource`, in this version of `record_platform_interface`.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:record/record.dart';

import '../config/constants.dart';

/// Streams raw 16-bit mono PCM at `AudioCfg.sampleRateHz` from the device
/// microphone.
///
/// Chunk sizes are non-deterministic — the platform may deliver anywhere
/// from a few hundred bytes to several KB per event. Downstream stages
/// (`PcmSlicer`) re-frame to fixed `AudioCfg.frameMs` boundaries.
class MicSource {
  final AudioRecorder _recorder = AudioRecorder();
  StreamSubscription<Uint8List>? _sub;
  final StreamController<Uint8List> _out =
      StreamController<Uint8List>.broadcast();

  /// Broadcast stream of raw PCM chunks. Subscribers see chunks exactly as
  /// the platform delivers them; framing is downstream.
  Stream<Uint8List> get pcm16 => _out.stream;

  /// Begins streaming. Throws `StateError` if mic permission is denied —
  /// the consent flow in Phase 0 must have already granted it.
  Future<void> start() async {
    if (!await _recorder.hasPermission()) {
      throw StateError('mic permission denied');
    }
    final stream = await _recorder.startStream(
      const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: AudioCfg.sampleRateHz,
        numChannels: AudioCfg.channels,
        // unprocessed disables platform AGC + NS so calibration thresholds
        // reflect real ambient energy, not OS-massaged levels.
        // API 24+; falls back to default on older devices server-side.
        androidConfig: AndroidRecordConfig(
          audioSource: AndroidAudioSource.unprocessed,
        ),
      ),
    );
    _sub = stream.listen(_out.add);
  }

  /// Stops streaming. Safe to call multiple times.
  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
    await _recorder.stop();
  }
}
