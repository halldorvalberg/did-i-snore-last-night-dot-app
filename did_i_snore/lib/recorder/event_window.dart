/// Phase 4 event window: pre-roll + live + tail PCM, captured between a
/// [GateOpened] and the matching [GateClosed]. Spec §4.3.
///
/// One [EventWindow] per gate-open. Pre-roll bytes seed the buffer at
/// construction (from `ring.snapshot()`), live frames are appended as the
/// recorder loop receives them, and the tail (the last `AudioCfg.tailMs`
/// of below-threshold audio that the gate waited through before closing)
/// is implicitly already in the buffer when [GateClosed] fires — the
/// recorder kept appending all the way to the close.
///
/// **No event merging here.** Two gate events ≤ `eventMergeGapMs` apart
/// become two separate [EventWindow]s. Merging them at the audio layer
/// would require zero-padding the gap (audible silence in playback) or
/// keeping the recorder logically open across the gap (which obscures
/// real interruptions). Merging is a Phase 6 data-layer concern, applied
/// to timeline rows, not to PCM.
///
/// **No zero-padding to a minimum length.** Events shorter than
/// `AudioCfg.minEventDurationMs` are *rejected* by the recorder, not
/// padded — padding produces audible silence and lies about duration.
/// This class therefore has no `padTo` method, on purpose.
library;

import 'dart:typed_data';

import '../config/constants.dart';

/// Bytes per millisecond at the canonical sample format
/// (`AudioCfg.sampleRateHz` × 2 bytes per int16 sample, mono / 1000).
/// Computed once and reused for the durationMs / firstSamples math.
const int _bytesPerMs = AudioCfg.sampleRateHz * 2 ~/ 1000;

/// Pre-roll size in bytes — derived from `AudioCfg.preRollMs` so the
/// `firstSamplesAsFloat32` slice can locate "post pre-roll" without
/// re-deriving the constant locally.
const int _preRollBytes = AudioCfg.preRollMs * _bytesPerMs;

/// Single-event PCM accumulator. Owned by the recorder for the duration
/// of one gate-open / gate-close cycle. Single-use: [takePcm] returns the
/// underlying bytes once and then the window is sealed.
class EventWindow {
  /// Wall-clock ms at which the gate opened. Same value as
  /// `GateOpened.startMs`; persisted so the recorder can correlate this
  /// window to the gate event after the fact.
  final int startMs;

  /// `BytesBuilder(copy: false)` keeps appended chunks in a list of refs
  /// and only allocates the contiguous output at `takeBytes()`. That
  /// matches our access pattern: many appends, exactly one take.
  ///
  /// Caveat: with `copy: false` the builder retains references to the
  /// caller's `Uint8List`s. Callers must not mutate the chunks they
  /// passed in — the recorder calls slicer-output frames here, and the
  /// slicer's tail buffer is the one mutable thing it owns; that case is
  /// handled by the slicer copying on stitch (see `pcm_slicer.dart`).
  final BytesBuilder _bytes = BytesBuilder(copy: false);

  /// `takePcm` empties the builder; we record total bytes separately so
  /// `durationMs` keeps working after the take if the caller asks (it
  /// shouldn't; the contract is single-use, but defensive accounting is
  /// cheap).
  int _totalBytes = 0;

  bool _taken = false;

  /// Constructs a window seeded with the pre-roll snapshot from the ring
  /// buffer. `preRoll.length` is whatever the ring had at open time —
  /// less than `AudioCfg.preRollMs * 32` only during the first
  /// `preRollMs` of a session, after which the ring is full.
  EventWindow(this.startMs, Uint8List preRoll) {
    _bytes.add(preRoll);
    _totalBytes = preRoll.length;
  }

  /// Appends a chunk of live audio. The recorder calls this for every
  /// chunk delivered between [GateOpened] and the [GateClosed].
  ///
  /// We record bytes at chunk granularity, not frame granularity —
  /// trimming to exact frame boundaries inside the window would discard
  /// up to `frameBytes - 1` bytes per close, and the encoder downstream
  /// doesn't need framed input.
  void appendChunk(Uint8List chunk) {
    if (_taken) {
      throw StateError('EventWindow.appendChunk after takePcm');
    }
    _bytes.add(chunk);
    _totalBytes += chunk.length;
  }

  /// Total bytes currently in the window (pre-roll + appended chunks).
  int get totalBytes => _totalBytes;

  /// Duration in milliseconds, derived from byte count.
  /// `_bytesPerMs` = 32 at 16 kHz mono int16. Integer-divides; a
  /// non-multiple-of-32 byte count rounds toward zero.
  int get durationMs => _totalBytes ~/ _bytesPerMs;

  /// Returns the accumulated PCM bytes in chronological order. Single
  /// use — subsequent calls throw. The caller (encoder, classifier,
  /// EventRepo) takes ownership of the returned `Uint8List`.
  Uint8List takePcm() {
    if (_taken) {
      throw StateError('EventWindow.takePcm called twice');
    }
    _taken = true;
    return _bytes.takeBytes();
  }

  /// Returns `sampleCount` int16 samples starting after the pre-roll, as
  /// float32 normalized to `[-1, 1]`. For the spectral probe this is
  /// `AudioCfg.classifierFrameMs * 16` samples = 15360 at 960 ms / 16 kHz.
  ///
  /// If fewer than `sampleCount` post-pre-roll samples are available
  /// (event shorter than `preRoll + classifierFrameMs`), returns whatever
  /// is available. The recorder, not this class, decides whether the
  /// available length is enough to bother running the spectral probe.
  ///
  /// **Important:** this method is read-only — it does NOT consume the
  /// underlying buffer. It can be called freely before [takePcm].
  Float32List firstSamplesAsFloat32(int sampleCount) {
    if (_taken) {
      // After takeBytes the BytesBuilder is empty; we can't reconstruct.
      // The recorder is expected to call this before takePcm.
      throw StateError('EventWindow.firstSamplesAsFloat32 after takePcm');
    }
    // `BytesBuilder.toBytes()` returns a fresh Uint8List but does NOT
    // reset the builder. Single allocation, no consumption.
    final all = _bytes.toBytes();
    if (all.length <= _preRollBytes) {
      // No post-pre-roll bytes yet (impossible if gate opened normally,
      // since gate-open requires gateHoldMs of above-threshold which is
      // already past pre-roll, but defensive).
      return Float32List(0);
    }
    final available = all.length - _preRollBytes;
    final wantBytes = sampleCount * 2;
    final takeBytes = wantBytes < available ? wantBytes : available;
    // takeBytes may be odd if the event is mid-sample; align down to
    // an even count so the int16 view is well-formed.
    final alignedBytes = takeBytes & ~1;
    final view = ByteData.sublistView(all, _preRollBytes, _preRollBytes + alignedBytes);
    final samples = alignedBytes >> 1;
    final out = Float32List(samples);
    for (var i = 0; i < samples; i++) {
      // `getInt16` is alignment-agnostic — pre-roll byte count is always
      // even (even byte count per ms), but the view itself has an odd
      // offsetInBytes after a stitched sublistView, and Int16List.view
      // would throw. ByteData reads cleanly.
      out[i] = view.getInt16(i << 1, Endian.little) / 32768.0;
    }
    return out;
  }
}
