/// Contract tests for `Gate`.
///
/// The gate is the load-bearing transition between "we heard something" and
/// "we are recording an event". It costs nothing to fire when nothing real
/// is happening, but missing a real opening loses the user's data forever.
/// These tests pin the timing math (gateHoldMs to open, tailMs to close,
/// hysteresis between tLow and tHigh) frame-by-frame, with both `dbfs` and
/// `nowMs` synthesised so failures point at exactly which transition broke.
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:did_i_snore/config/constants.dart';
import 'package:did_i_snore/recorder/gate.dart';
import 'package:did_i_snore/recorder/ring_buffer.dart';

const double _tHigh = -40.0;
const double _tLow = -50.0;

Gate _gate(RingBuffer ring) =>
    Gate(ring: ring, tHighDbfs: _tHigh, tLowDbfs: _tLow);

void main() {
  group('Gate — closed-state transitions', () {
    test('single above-threshold frame, no event', () {
      // One frame above tHigh at t=0 then 50 frames well below tHigh.
      // gateHoldMs = 300 → 15 consecutive above-frames are required, so
      // a lone spike followed by silence must not trigger anything.
      final ring = RingBuffer(64000);
      final gate = _gate(ring);

      final emits = <GateEvent?>[];
      emits.add(gate.feed(_tHigh + 5.0, 0));
      for (var i = 1; i <= 50; i++) {
        emits.add(gate.feed(_tHigh - 20.0, i * AudioCfg.frameMs));
      }

      expect(emits.every((e) => e == null), isTrue,
          reason: 'a single above-threshold frame must not open the gate');
      expect(gate.isOpen, isFalse);
    });

    test('sustained above for exactly gateHoldMs opens once', () {
      // 15 frames at 20 ms cadence covers t=0..280 ms. The 15th feed (i=14,
      // nowMs = 280) is the first that satisfies `nowMs - _aboveSinceMs >=
      // gateHoldMs (300)` — wait, 280 - 0 = 280, that's < 300. The
      // canonical requirement is "sustained above for gateHoldMs". With
      // _aboveSinceMs set on the FIRST feed at t=0, the condition fires
      // when nowMs >= 300, i.e. the 16th feed at t=300. We test the
      // exact transition.
      final ring = RingBuffer(64000);
      final gate = _gate(ring);

      // Feed 15 frames at t=0,20,...,280 — none of these have crossed
      // gateHoldMs yet. The 16th frame is t=300 — that's the first time
      // nowMs - _aboveSinceMs == 300, satisfying the >= comparison.
      for (var i = 0; i < 15; i++) {
        final emit = gate.feed(_tHigh + 5.0, i * AudioCfg.frameMs);
        expect(emit, isNull,
            reason: 'frame $i (t=${i * AudioCfg.frameMs}) is still inside the '
                'gateHoldMs window');
      }

      // 16th feed at t=300 — the open boundary.
      final opening = gate.feed(_tHigh + 5.0, 15 * AudioCfg.frameMs);
      expect(opening, isA<GateOpened>());
      expect((opening! as GateOpened).startMs, 0,
          reason: 'eventStartMs should equal _aboveSinceMs (the first '
              'above-threshold frame), not the moment the hold elapsed');

      // 17th feed should not double-fire.
      final after = gate.feed(_tHigh + 5.0, 16 * AudioCfg.frameMs);
      expect(after, isNull, reason: 'one emit per transition');
      expect(gate.isOpen, isTrue);
    });

    test('sustained above for less than gateHoldMs does nothing', () {
      // 14 above-tHigh frames (covering t=0..260 ms) then a below-tHigh
      // frame at t=280 — still under gateHoldMs at all points.
      final ring = RingBuffer(64000);
      final gate = _gate(ring);

      for (var i = 0; i < 14; i++) {
        expect(gate.feed(_tHigh + 5.0, i * AudioCfg.frameMs), isNull);
      }
      // Drop below tHigh — _aboveSinceMs resets.
      expect(gate.feed(_tHigh - 20.0, 14 * AudioCfg.frameMs), isNull);
      expect(gate.isOpen, isFalse);

      // A NEW streak from t=300 should be measured against its own t0,
      // not the prior streak's. Drive 16 more above-tHigh frames at
      // t=300..600. The gate opens at the frame whose nowMs - 300 >= 300,
      // i.e. the 16th frame at t=600. Its startMs should be 300, not 0.
      GateEvent? opening;
      for (var i = 0; i < 16; i++) {
        final ms = (15 + i) * AudioCfg.frameMs; // 300, 320, ..., 600
        final emit = gate.feed(_tHigh + 5.0, ms);
        if (emit != null) {
          expect(opening, isNull, reason: 'only one open per streak');
          opening = emit;
        }
      }

      expect(opening, isA<GateOpened>());
      expect((opening! as GateOpened).startMs, 300,
          reason: 'second streak starts at t=300; prior streak must have '
              'been forgotten');
    });
  });

  group('Gate — open-state transitions', () {
    test('hysteresis: dropping between tLow and tHigh while open keeps it open',
        () {
      final ring = RingBuffer(64000);
      final gate = _gate(ring);

      // Open the gate.
      for (var i = 0; i < 15; i++) {
        gate.feed(_tHigh + 5.0, i * AudioCfg.frameMs);
      }
      final opening = gate.feed(_tHigh + 5.0, 15 * AudioCfg.frameMs);
      expect(opening, isA<GateOpened>());
      expect(gate.isOpen, isTrue);

      // 60 frames at the midpoint between tLow and tHigh — above tLow,
      // so _belowSinceMs should never become non-negative and tail should
      // never expire.
      final mid = (_tHigh + _tLow) / 2.0;
      for (var i = 0; i < 60; i++) {
        final ms = (16 + i) * AudioCfg.frameMs;
        expect(gate.feed(mid, ms), isNull,
            reason: 'frame at $ms dBFS=$mid is between tLow and tHigh — '
                'must not close');
      }

      expect(gate.isOpen, isTrue);
    });

    test('tail timing: tailMs below tLow closes once', () {
      final ring = RingBuffer(64000);
      final gate = _gate(ring);

      // Open at t=300.
      for (var i = 0; i < 16; i++) {
        gate.feed(_tHigh + 5.0, i * AudioCfg.frameMs);
      }
      expect(gate.isOpen, isTrue);

      // Now feed below-tLow frames starting at t=320. By symmetry with
      // open-side timing: _belowSinceMs is set on the first below-frame
      // (t=320). The close condition is `nowMs - _belowSinceMs >= tailMs
      // (1000)`, so it fires when nowMs >= 1320 → frame at 1320 ms (the
      // 51st below-frame, since 320 + 50*20 = 1320).
      GateEvent? closing;
      var emitsSeen = 0;
      for (var i = 0; i < 60; i++) {
        final ms = (16 + i) * AudioCfg.frameMs; // 320, 340, ..., 1500
        final emit = gate.feed(_tLow - 1.0, ms);
        if (emit != null) {
          emitsSeen++;
          closing = emit;
          // Stop driving after the first emit; subsequent frames must not
          // re-emit (we test that separately below).
          break;
        }
      }

      expect(emitsSeen, 1);
      expect(closing, isA<GateClosed>());
      final c = closing! as GateClosed;
      expect(c.startMs, 0,
          reason: 'GateClosed.startMs equals the original event start');
      expect(c.endMs, 1320,
          reason: 'first frame whose nowMs - belowSinceMs >= tailMs');
      expect(gate.isOpen, isFalse);

      // Subsequent feeds (still below tLow) must not re-emit.
      expect(gate.feed(_tLow - 1.0, 1340), isNull);
      expect(gate.feed(_tLow - 1.0, 1360), isNull);
    });

    test('brief dip below tLow does NOT close', () {
      final ring = RingBuffer(64000);
      final gate = _gate(ring);

      // Open the gate (16 above-frames → opens at t=300).
      for (var i = 0; i < 16; i++) {
        gate.feed(_tHigh + 5.0, i * AudioCfg.frameMs);
      }
      expect(gate.isOpen, isTrue);

      // 20 below-tLow frames (400 ms) — under tailMs.
      for (var i = 0; i < 20; i++) {
        final ms = (16 + i) * AudioCfg.frameMs;
        expect(gate.feed(_tLow - 1.0, ms), isNull);
      }
      // One frame above tHigh — _belowSinceMs resets.
      final reset = gate.feed(_tHigh + 5.0, (16 + 20) * AudioCfg.frameMs);
      expect(reset, isNull);
      expect(gate.isOpen, isTrue);

      // Another 20 below-tLow frames — also under tailMs because timing
      // restarted after the at-tHigh frame.
      for (var i = 0; i < 20; i++) {
        final ms = (16 + 21 + i) * AudioCfg.frameMs;
        expect(gate.feed(_tLow - 1.0, ms), isNull);
      }

      expect(gate.isOpen, isTrue,
          reason: 'two short dips with a high-frame between them must '
              'not close the gate');
    });

    test('GateOpened includes ring snapshot bytes', () {
      // Build a ring with a known pattern, drive the gate to open, and
      // assert preRoll equals what snapshot() produced at the open moment.
      final ring = RingBuffer(6400);
      final pattern = Uint8List.fromList(
        List<int>.generate(3200, (i) => i & 0xff, growable: false),
      );
      ring.write(pattern);
      final expectedPreRoll = ring.snapshot();
      expect(expectedPreRoll.length, 3200);

      final gate = _gate(ring);
      // 16 above-frames → opens at the 16th feed.
      GateEvent? opening;
      for (var i = 0; i < 16; i++) {
        final emit = gate.feed(_tHigh + 5.0, i * AudioCfg.frameMs);
        if (emit != null) opening = emit;
      }

      expect(opening, isA<GateOpened>());
      final preRoll = (opening! as GateOpened).preRoll;
      expect(preRoll.length, expectedPreRoll.length);
      expect(preRoll, orderedEquals(expectedPreRoll));
    });
  });

  group('Gate — reset and idempotency', () {
    test('reset() returns gate to closed and clears timing', () {
      final ring = RingBuffer(64000);
      final gate = _gate(ring);

      // Open the gate.
      for (var i = 0; i < 16; i++) {
        gate.feed(_tHigh + 5.0, i * AudioCfg.frameMs);
      }
      expect(gate.isOpen, isTrue);

      gate.reset();
      expect(gate.isOpen, isFalse);

      // 14 above-frames + a below-frame → would-be-streak should NOT open
      // because reset cleared _aboveSinceMs (so the new streak starts
      // counting from 0, not from a stale earlier-than-zero value).
      // Use timestamps far in the future to make stale state visible if
      // it leaked through reset.
      const t0 = 100000;
      for (var i = 0; i < 14; i++) {
        expect(gate.feed(_tHigh + 5.0, t0 + i * AudioCfg.frameMs), isNull);
      }
      // Drop below tHigh (resets the new streak).
      expect(gate.feed(_tHigh - 20.0, t0 + 14 * AudioCfg.frameMs), isNull);
      expect(gate.isOpen, isFalse,
          reason: 'reset must have cleared _aboveSinceMs so the new partial '
              'streak does not benefit from old timing');
    });

    test('same nowMs twice does not double-fire', () {
      // Contract: one emit per transition. If the same nowMs is fed twice
      // (unlikely in practice but possible at clock boundaries), the
      // second call should return null.
      final ring = RingBuffer(64000);
      final gate = _gate(ring);

      GateEvent? opening;
      for (var i = 0; i < 16; i++) {
        final emit = gate.feed(_tHigh + 5.0, i * AudioCfg.frameMs);
        if (emit != null) opening = emit;
      }
      expect(opening, isA<GateOpened>());
      final openingMs = (opening! as GateOpened).startMs;
      // The opening fired at nowMs=300; feeding another above-tHigh frame
      // at the SAME nowMs must not produce another GateOpened.
      final emit = gate.feed(_tHigh + 5.0, 300);
      expect(emit, isNull,
          reason: 'gate is already open; same nowMs must not re-emit');
      expect(openingMs, 0);
    });
  });
}
