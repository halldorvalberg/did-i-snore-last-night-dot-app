/// PCM frame slicer. Re-frames arbitrary-sized PCM chunks into fixed
/// `frameBytes`-sized frames using a typed tail buffer.
///
/// Hot-path discipline: tail is a `Uint8List` of length `frameBytes`,
/// allocated once and reused. `_tailLen` tracks how much of it is valid
/// without ever resizing. `List<int>` would box every byte; we never use it.
library;

import 'dart:typed_data';

/// Slices an unbounded stream of PCM `Uint8List` chunks into frames of
/// exactly `frameBytes` bytes.
///
/// Usage:
/// ```dart
/// final s = PcmSlicer(frameBytes: AudioCfg.frameBytes);
/// for (final chunk in micStream) {
///   for (final frame in s.sliceChunk(chunk)) {
///     // frame.length == frameBytes
///   }
/// }
/// ```
class PcmSlicer {
  /// Frame size in bytes. For 20 ms @ 16 kHz int16 mono = 640.
  final int frameBytes;

  /// Reusable carry-over buffer for the partial frame at the end of a
  /// chunk. Always allocated to exactly `frameBytes`; never grows.
  final Uint8List _tail;

  /// How many bytes at the start of `_tail` are valid leftover data.
  int _tailLen = 0;

  PcmSlicer({required this.frameBytes}) : _tail = Uint8List(frameBytes);

  /// Splits `chunk` into zero or more frames of exactly `frameBytes`
  /// bytes. Any tail remainder is held internally for the next call.
  ///
  /// Yielded frames within a single call may be views over `chunk`; copy
  /// them if you need to retain the bytes past the next call. The first
  /// frame (when stitched from the previous tail) is always copied.
  Iterable<Uint8List> sliceChunk(Uint8List chunk) sync* {
    var i = 0;

    // 1. Stitch tail-from-previous-call with the head of this chunk if we
    //    have a partial frame held over.
    if (_tailLen > 0) {
      final need = frameBytes - _tailLen;
      if (chunk.length >= need) {
        _tail.setRange(_tailLen, frameBytes, chunk);
        // Copy: `_tail` is reused, so we must not yield a view over it.
        yield Uint8List.fromList(_tail);
        _tailLen = 0;
        i = need;
      } else {
        // Not enough yet; absorb the whole chunk into the tail.
        _tail.setRange(_tailLen, _tailLen + chunk.length, chunk);
        _tailLen += chunk.length;
        return;
      }
    }

    // 2. Emit as many full frames as fit. These are views over `chunk` —
    //    cheap, no allocation. Caller is expected to consume synchronously
    //    or copy.
    while (chunk.length - i >= frameBytes) {
      yield Uint8List.sublistView(chunk, i, i + frameBytes);
      i += frameBytes;
    }

    // 3. Stash any sub-frame remainder for the next call.
    final remainder = chunk.length - i;
    if (remainder > 0) {
      _tail.setRange(0, remainder, chunk, i);
      _tailLen = remainder;
    }
  }
}
