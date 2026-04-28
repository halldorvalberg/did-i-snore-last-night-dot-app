/// Fixed-capacity byte ring buffer for the pre-roll snapshot.
///
/// Hot-path discipline: every write uses `setRange` (memmove under the
/// hood), never a hand-rolled byte loop. This module sees every PCM byte
/// the device produces, all night, on battery.
library;

import 'dart:typed_data';

/// Append-only ring buffer over a single `Uint8List`. Writes wrap; older
/// bytes are overwritten. `snapshot()` returns the most recent `_filled`
/// bytes in chronological order.
class RingBuffer {
  final Uint8List _buf;
  int _writeIdx = 0;
  int _filled = 0;

  /// Allocates `byteCapacity` bytes. For 2 s of int16 mono 16 kHz pre-roll
  /// pass `AudioCfg.sampleRateHz * 2 * AudioCfg.preRollMs ~/ 1000 = 64000`.
  RingBuffer(int byteCapacity) : _buf = Uint8List(byteCapacity);

  /// Capacity in bytes.
  int get capacity => _buf.length;

  /// How many bytes are currently retrievable via `snapshot()`. Saturates
  /// at `capacity` once the buffer has been fully populated.
  int get filled => _filled;

  /// Writes `chunk` into the ring. Splits at the wrap boundary so that
  /// each `setRange` is a single memmove.
  void write(Uint8List chunk) {
    var src = 0;
    var remaining = chunk.length;
    while (remaining > 0) {
      final canFit = _buf.length - _writeIdx;
      final take = remaining < canFit ? remaining : canFit;
      _buf.setRange(_writeIdx, _writeIdx + take, chunk, src);
      _writeIdx = (_writeIdx + take) % _buf.length;
      if (_filled < _buf.length) {
        final next = _filled + take;
        _filled = next > _buf.length ? _buf.length : next;
      }
      src += take;
      remaining -= take;
    }
  }

  /// Returns the most recent `filled` bytes in chronological order. Always
  /// allocates a fresh `Uint8List`; the caller owns it.
  ///
  /// While the buffer is not yet full, the data lives at `[0, _filled)` in
  /// chronological order. Once it has wrapped, the oldest byte is at
  /// `_writeIdx` and we stitch `[writeIdx..end] + [0..writeIdx)`.
  Uint8List snapshot() {
    final out = Uint8List(_filled);
    if (_filled < _buf.length) {
      out.setRange(0, _filled, _buf);
    } else {
      final headLen = _buf.length - _writeIdx;
      out.setRange(0, headLen, _buf, _writeIdx);
      out.setRange(headLen, _buf.length, _buf, 0);
    }
    return out;
  }
}
