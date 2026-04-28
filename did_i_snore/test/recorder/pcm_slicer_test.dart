/// Contract tests for `PcmSlicer`.
///
/// Locks in the chunk-boundary invariants the audio pipeline depends on:
/// every byte the mic produces must end up in exactly one frame, in order,
/// with no gaps and no duplicates. Frame views must be cheap (no allocation
/// for mid-chunk frames) and stitched frames must be copies (the internal
/// tail buffer is reused and would alias otherwise).
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:did_i_snore/config/constants.dart';
import 'package:did_i_snore/recorder/pcm_slicer.dart';

void main() {
  group('PcmSlicer', () {
    test('canonical chunk-boundary: 73 + 12000 byte sequence', () {
      // Headline contract from IMPLEMENTATION.md 2.2: feed 73 bytes, then
      // 12000 bytes. 73 + 12000 = 12073; 12073 - 18*640 = 553-byte tail.
      final slicer = PcmSlicer(frameBytes: AudioCfg.frameBytes);

      final framesA = slicer.sliceChunk(Uint8List(73)).toList();
      expect(framesA, isEmpty,
          reason: '73 bytes is less than one ${AudioCfg.frameBytes}-byte frame');

      final framesB = slicer.sliceChunk(Uint8List(12000)).toList();
      expect(framesB.length, 18);
      for (final f in framesB) {
        expect(f.length, AudioCfg.frameBytes);
      }

      // Feed `frameBytes - 553 = 87` more bytes; tail (553) + 87 = 640 → one frame.
      final framesC = slicer.sliceChunk(Uint8List(AudioCfg.frameBytes - 553)).toList();
      expect(framesC.length, 1, reason: '553 + 87 should fill exactly one frame');
      expect(framesC.first.length, AudioCfg.frameBytes);

      final framesD = slicer.sliceChunk(Uint8List(AudioCfg.frameBytes - 1)).toList();
      expect(framesD, isEmpty);
    });

    test('empty chunk yields nothing and does not change tail state', () {
      final slicer = PcmSlicer(frameBytes: AudioCfg.frameBytes);

      // Seed a partial tail so we can detect any state mutation.
      final framesA = slicer.sliceChunk(Uint8List(100)).toList();
      expect(framesA, isEmpty);

      final framesB = slicer.sliceChunk(Uint8List(0)).toList();
      expect(framesB, isEmpty);

      // Confirm tail is still 100 bytes by feeding exactly the bytes needed
      // to complete a frame.
      final framesC =
          slicer.sliceChunk(Uint8List(AudioCfg.frameBytes - 100)).toList();
      expect(framesC.length, 1);
    });

    test('chunk smaller than frameBytes yields nothing, tail grows', () {
      final slicer = PcmSlicer(frameBytes: AudioCfg.frameBytes);

      final framesA = slicer.sliceChunk(Uint8List(200)).toList();
      expect(framesA, isEmpty);

      // Tail is 200; we need 440 more to complete a frame.
      final framesB =
          slicer.sliceChunk(Uint8List(AudioCfg.frameBytes - 201)).toList();
      expect(framesB, isEmpty);

      // One more byte completes the frame.
      final framesC = slicer.sliceChunk(Uint8List(1)).toList();
      expect(framesC.length, 1);
      expect(framesC.first.length, AudioCfg.frameBytes);
    });

    test('multiple sub-frame chunks accumulate to exactly one frame', () {
      final slicer = PcmSlicer(frameBytes: AudioCfg.frameBytes);

      // Feed 4 chunks of 160 bytes each = 640.
      const partSize = 160;
      expect(partSize * 4, AudioCfg.frameBytes);

      expect(slicer.sliceChunk(Uint8List(partSize)).toList(), isEmpty);
      expect(slicer.sliceChunk(Uint8List(partSize)).toList(), isEmpty);
      expect(slicer.sliceChunk(Uint8List(partSize)).toList(), isEmpty);
      final last = slicer.sliceChunk(Uint8List(partSize)).toList();
      expect(last.length, 1);
      expect(last.first.length, AudioCfg.frameBytes);

      // Tail must now be empty: the next sub-frame chunk yields nothing.
      expect(slicer.sliceChunk(Uint8List(1)).toList(), isEmpty);
    });

    test('mid-chunk frames are views over the input buffer (no copy)', () {
      // `identical(frame.buffer, chunk.buffer)` is unreliable in Dart —
      // accessing `.buffer` on a typed-data view returns a fresh
      // `_ByteBuffer` wrapper each call. Instead, we detect view-aliasing
      // behaviorally: mutate the source after slicing and assert the
      // frame sees the mutation.
      final slicer = PcmSlicer(frameBytes: AudioCfg.frameBytes);

      final chunk = Uint8List(AudioCfg.frameBytes * 3);
      for (var i = 0; i < chunk.length; i++) {
        chunk[i] = i & 0xff;
      }

      final frames = slicer.sliceChunk(chunk).toList();
      expect(frames.length, 3);
      for (final f in frames) {
        expect(f.length, AudioCfg.frameBytes);
      }

      // Frame 1 covers bytes [640, 1280). Mutating chunk[700] should be
      // visible at frames[1][60]. Same for frames[2] at 1280..1920.
      chunk[700] = 0xCC;
      chunk[1300] = 0xDD;
      expect(frames[1][60], 0xCC,
          reason: 'mid-chunk frame must be a view that aliases chunk memory');
      expect(frames[2][20], 0xDD,
          reason: 'mid-chunk frame must be a view that aliases chunk memory');

      // Offsets verify "no copy" structurally too: each successive frame
      // starts frameBytes after the previous, sharing the same underlying
      // memory.
      expect(frames[0].offsetInBytes, chunk.offsetInBytes);
      expect(frames[1].offsetInBytes, chunk.offsetInBytes + AudioCfg.frameBytes);
      expect(frames[2].offsetInBytes,
          chunk.offsetInBytes + 2 * AudioCfg.frameBytes);
    });

    test('stitched frame (after a tail fill) is a copy, not a view', () {
      final slicer = PcmSlicer(frameBytes: AudioCfg.frameBytes);

      // Seed tail with 100 bytes. Use unique values so we can recognise
      // the bytes inside the stitched frame later.
      final seed = Uint8List(100);
      for (var i = 0; i < 100; i++) {
        seed[i] = (i + 1) & 0xff;
      }
      slicer.sliceChunk(seed).toList();

      // Feed a chunk that completes the tail and contains one extra full
      // frame. The first yielded frame is stitched; the second is a view.
      final chunk = Uint8List(AudioCfg.frameBytes + (AudioCfg.frameBytes - 100));
      for (var i = 0; i < chunk.length; i++) {
        chunk[i] = (i + 200) & 0xff;
      }

      final frames = slicer.sliceChunk(chunk).toList();
      expect(frames.length, 2);

      // The stitched frame must NOT alias `chunk`. Mutate chunk and assert
      // the stitched frame's bytes are unchanged. Pick an index that fell
      // into the chunk-sourced portion of the stitched frame (anything
      // >= 100 in the stitched frame came from chunk[0..539]).
      final stitched = frames[0];
      final preMutation = stitched[150];
      chunk[50] = chunk[50] ^ 0xFF;
      expect(stitched[150], preMutation,
          reason: 'stitched frame must be a copy; tail buffer is reused');

      // The second yielded frame should still alias `chunk` memory.
      // Frame 1 covers chunk bytes [540, 1180). Mutate chunk[600] (offset
      // 60 in that frame) and observe.
      chunk[600] = 0xAB;
      expect(frames[1][60], 0xAB,
          reason: 'mid-chunk frame after a stitch is still a view');
    });

    test('sequential bytes preserved across stitch + multiple frames', () {
      // The strongest contract: every input byte appears in exactly one
      // output frame (or in the tail), in order, with no duplicates.
      final slicer = PcmSlicer(frameBytes: AudioCfg.frameBytes);

      // Build a chunk with sequential byte values mod 256.
      final n = AudioCfg.frameBytes * 5 + 73;
      final input = Uint8List(n);
      for (var i = 0; i < n; i++) {
        input[i] = i & 0xff;
      }

      final frames = slicer.sliceChunk(input).toList();
      expect(frames.length, 5);

      // Concatenate yielded frames + (logical) tail and compare to input.
      final reassembled = BytesBuilder(copy: false);
      for (final f in frames) {
        reassembled.add(f);
      }
      // Tail length is 73; feed exactly that many extra bytes via a second
      // chunk to flush the tail through one more frame.
      final follow = Uint8List(AudioCfg.frameBytes - 73);
      for (var i = 0; i < follow.length; i++) {
        follow[i] = (n + i) & 0xff;
      }
      final framesB = slicer.sliceChunk(follow).toList();
      expect(framesB.length, 1);
      reassembled.add(framesB.first);

      // The reassembled bytes should equal `input + follow`.
      final expected = Uint8List(input.length + follow.length);
      expected.setRange(0, input.length, input);
      expected.setRange(input.length, expected.length, follow);

      expect(reassembled.toBytes(), orderedEquals(expected));
    });

    test('frame boundaries that align with chunk boundaries skip the stitch path',
        () {
      // When tail is empty AND chunk.length is a multiple of frameBytes,
      // every frame is a view; no copy of `_tail` happens. Verify by
      // mutating the source and observing the frames' bytes change.
      final slicer = PcmSlicer(frameBytes: AudioCfg.frameBytes);

      final chunk = Uint8List(AudioCfg.frameBytes * 2);
      for (var i = 0; i < chunk.length; i++) {
        chunk[i] = (i * 3) & 0xff;
      }

      final frames = slicer.sliceChunk(chunk).toList();
      expect(frames.length, 2);

      // Frame 0 covers bytes [0, 640); frame 1 covers [640, 1280).
      chunk[0] = 0x11;
      chunk[700] = 0x22;
      expect(frames[0][0], 0x11);
      expect(frames[1][60], 0x22);

      expect(frames[0].offsetInBytes, chunk.offsetInBytes);
      expect(frames[1].offsetInBytes, chunk.offsetInBytes + AudioCfg.frameBytes);
    });
  });
}
