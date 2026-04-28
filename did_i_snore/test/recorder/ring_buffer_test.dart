/// Contract tests for `RingBuffer`.
///
/// The pre-roll snapshot has to be chronological — oldest retained byte
/// first, newest byte last — even after the write pointer has wrapped one
/// or more times. These tests pin that down with byte-level fixtures small
/// enough to read by hand.
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:did_i_snore/recorder/ring_buffer.dart';

Uint8List _seq(int from, int len) {
  final out = Uint8List(len);
  for (var i = 0; i < len; i++) {
    out[i] = (from + i) & 0xff;
  }
  return out;
}

void main() {
  group('RingBuffer', () {
    test('capacity returns what was constructed', () {
      final rb = RingBuffer(64);
      expect(rb.capacity, 64);
      // Writes do not change capacity.
      rb.write(_seq(0, 200));
      expect(rb.capacity, 64);
    });

    test('empty snapshot has length 0', () {
      final rb = RingBuffer(64);
      final snap = rb.snapshot();
      expect(snap, isA<Uint8List>());
      expect(snap.length, 0);
      expect(rb.filled, 0);
    });

    test('write less than capacity → snapshot returns exactly what was written',
        () {
      final rb = RingBuffer(64);
      final input = _seq(10, 30);
      rb.write(input);

      expect(rb.filled, 30);
      final snap = rb.snapshot();
      expect(snap.length, 30);
      expect(snap, orderedEquals(input));
    });

    test('write exactly capacity → snapshot is the full buffer in order', () {
      final rb = RingBuffer(64);
      final input = _seq(0, 64);
      rb.write(input);

      expect(rb.filled, 64);
      expect(rb.snapshot(), orderedEquals(input));
    });

    test(
        'single write larger than capacity → snapshot is the most recent '
        '`capacity` bytes', () {
      final rb = RingBuffer(64);
      // 100 bytes of 0..99. The ring should retain the last 64 bytes:
      // values 36..99.
      final input = _seq(0, 100);
      rb.write(input);

      expect(rb.filled, 64);
      final snap = rb.snapshot();
      expect(snap.length, 64);
      expect(snap, orderedEquals(_seq(36, 64)));
    });

    test('multi-write wrap: 50 then 50 into capacity 64 → newest 64 chronological',
        () {
      // 0..49 fits without wrap; the next 50..99 wraps after byte 13.
      // Final retained bytes (most recent 64): 36..99.
      final rb = RingBuffer(64);
      rb.write(_seq(0, 50));
      expect(rb.filled, 50);

      rb.write(_seq(50, 50));
      expect(rb.filled, 64);

      expect(rb.snapshot(), orderedEquals(_seq(36, 64)));
    });

    test('cross-wrap snapshot ordering: writeIdx mid-buffer', () {
      // Force the write index to land mid-buffer after a wrap, so the
      // snapshot has to stitch [writeIdx..end) + [0..writeIdx).
      final rb = RingBuffer(10);

      rb.write(_seq(0, 10)); // fills exactly: writeIdx wraps to 0
      rb.write(_seq(10, 3)); // writeIdx now at 3; buffer holds 3..12

      final snap = rb.snapshot();
      expect(snap.length, 10);
      expect(snap, orderedEquals(_seq(3, 10)),
          reason: 'snapshot must be chronological from oldest retained');
    });

    test('setRange split: write straddles the wrap boundary in one call', () {
      // Capacity 10. First write 7 bytes: writeIdx = 7, capacity-writeIdx = 3.
      // Then a single 8-byte write splits as 3 + 5.
      final rb = RingBuffer(10);
      rb.write(_seq(0, 7));
      rb.write(_seq(7, 8)); // 8 bytes; first 3 fill [7..10), then wrap [0..5)

      // Most recent 10 bytes after these writes: 5..14.
      expect(rb.filled, 10);
      expect(rb.snapshot(), orderedEquals(_seq(5, 10)));
    });

    test('snapshot is a fresh allocation that the caller owns', () {
      // Mutating the returned snapshot must not affect future snapshots.
      final rb = RingBuffer(8);
      rb.write(_seq(0, 8));

      final snap1 = rb.snapshot();
      for (var i = 0; i < snap1.length; i++) {
        snap1[i] = 0xAA;
      }
      final snap2 = rb.snapshot();
      expect(snap2, orderedEquals(_seq(0, 8)),
          reason: 'snapshot 2 should reflect the original ring contents');
    });

    test('filled saturates at capacity across many wraps', () {
      final rb = RingBuffer(16);
      // Total 5 wraps' worth of writes.
      for (var w = 0; w < 5; w++) {
        rb.write(_seq(w * 16, 16));
      }
      expect(rb.filled, 16);
      // Last 16 bytes written are values (4*16) .. (4*16 + 15) = 64..79.
      expect(rb.snapshot(), orderedEquals(_seq(64, 16)));
    });

    test('zero-length write is a no-op', () {
      final rb = RingBuffer(8);
      rb.write(_seq(0, 4));
      rb.write(Uint8List(0));
      expect(rb.filled, 4);
      expect(rb.snapshot(), orderedEquals(_seq(0, 4)));
    });
  });
}
