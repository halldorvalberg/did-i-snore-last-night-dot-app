/// Phase 4 gate: two-state hysteresis with sustained-above hold and a
/// trailing tail. Spec §4.1.
///
/// Inputs are per-frame (20 ms) RMS dBFS plus a monotonic clock. Outputs
/// are exactly one [GateEvent] per state transition: [GateOpened] on the
/// open transition, [GateClosed] on the close transition, otherwise
/// `null`. The recorder loop calls [feed] every 20 ms; everything else
/// (event-window plumbing, ring writes, spectral filter) is downstream of
/// these events.
///
/// Design constraints (locked, see `docs/IMPLEMENTATION.md` §4.1):
///
/// - **Hysteresis.** Open at `tHigh`, close at `tLow`. While the gate is
///   open, dipping below `tHigh` but staying above `tLow` does NOT close
///   it — that's what keeps the gate stable on snores with natural
///   amplitude wobble (a 100 ms intra-snore dip should not be a new event).
/// - **Hold to open.** A single noisy frame is not enough; the input has
///   to stay at or above `tHigh` for `AudioCfg.gateHoldMs` (= 300 ms,
///   15 frames @ 20 ms) before we open. Defends against creaks, clicks,
///   and brief impulse noise.
/// - **Tail to close.** Symmetric: stay below `tLow` for
///   `AudioCfg.tailMs` (= 1000 ms) before we close. Defends against
///   inter-snore breath gaps that would otherwise fragment a single event.
/// - **Pre-roll.** On open, snapshot the ring buffer — that's the
///   `preRollMs` of audio leading up to the trigger. The recorder owns
///   the ring; the gate just calls `ring.snapshot()`.
///
/// Hot-path discipline: this method runs at 50 Hz forever. No allocations
/// in the no-event path; the only allocation on transition is the pre-roll
/// snapshot, which the ring owns. Branchy, but the branches are
/// predictable on real input (mostly closed, mostly silent).
library;

import 'dart:typed_data';

import '../config/constants.dart';
import 'ring_buffer.dart';

/// Base type for gate state transitions. `sealed` so an exhaustive switch
/// on `GateEvent` in the recorder loop is checked at compile time.
sealed class GateEvent {
  /// Wall-clock millisecond at which the event began (for both
  /// [GateOpened] and [GateClosed], `startMs` refers to the event's open
  /// time so the close emit can be correlated to the open without state
  /// outside the gate).
  final int startMs;

  const GateEvent(this.startMs);
}

/// Emitted exactly once when the gate opens. `preRoll` is the ring
/// snapshot at the moment of open — everything currently in the ring, in
/// chronological order. The recorder builds the `EventWindow` from this.
class GateOpened extends GateEvent {
  /// Ring-buffer snapshot at the open instant. Owned by the receiver;
  /// the gate retains no reference.
  final Uint8List preRoll;

  const GateOpened(super.startMs, this.preRoll);
}

/// Emitted exactly once when the gate closes. `endMs` is the close
/// instant; together with `startMs` this gives the event's duration
/// for the `minEventDurationMs` filter downstream.
class GateClosed extends GateEvent {
  final int endMs;

  const GateClosed(super.startMs, this.endMs);
}

/// Two-state hysteresis gate with sustained-above hold and a trailing
/// tail. Stateful; one instance per recorder session.
///
/// Thresholds are mutable to support the runtime downward refiner from
/// Phase 3 — the recorder may lower `tHigh` mid-session when the room
/// gets quieter than calibration assumed. Raising is **never** allowed
/// at this layer; that policy is enforced by `RuntimeFloorRefiner`, not
/// by us. We just consume whatever pair the recorder hands us.
class Gate {
  /// Ring buffer the gate snapshots on open. Owned by the recorder.
  final RingBuffer ring;

  /// Open threshold (dBFS). The input has to stay at or above this for
  /// [AudioCfg.gateHoldMs] before the gate opens.
  double tHighDbfs;

  /// Close threshold (dBFS). The input has to stay strictly below this
  /// for [AudioCfg.tailMs] before the gate closes. `tLow < tHigh` is
  /// the hysteresis gap.
  double tLowDbfs;

  Gate({
    required this.ring,
    required this.tHighDbfs,
    required this.tLowDbfs,
  });

  bool _open = false;

  /// Wall-clock ms of the first above-`tHigh` frame in the current
  /// candidate hold. `-1` when not currently holding above.
  int _aboveSinceMs = -1;

  /// Wall-clock ms of the first below-`tLow` frame in the current
  /// candidate tail. `-1` when not currently in a tail.
  int _belowSinceMs = -1;

  /// Wall-clock ms at which the open event began. Set on open transition
  /// (= `_aboveSinceMs` at that instant); reused as `startMs` of the
  /// matching [GateClosed].
  int _eventStartMs = 0;

  /// Whether the gate is currently in the open state.
  bool get isOpen => _open;

  /// Feeds one frame's RMS dBFS at `nowMs`. Returns at most one
  /// [GateEvent] per call; `null` otherwise.
  ///
  /// Contract: exactly one emit per state transition. Re-calling with the
  /// same `nowMs` (clock didn't advance) does not double-fire — the timer
  /// math uses `>=` against the recorded reference, so a duplicate
  /// timestamp at exactly the transition boundary fires once and then the
  /// `_open` flip prevents a second.
  GateEvent? feed(double dbfs, int nowMs) {
    if (!_open) {
      // CLOSED state: watch for a sustained run above tHigh.
      if (dbfs >= tHighDbfs) {
        if (_aboveSinceMs == -1) _aboveSinceMs = nowMs;
        // 300 ms hold = AudioCfg.gateHoldMs / AudioCfg.frameMs = 15
        // consecutive above-threshold frames at 20 ms cadence.
        if (nowMs - _aboveSinceMs >= AudioCfg.gateHoldMs) {
          _open = true;
          _eventStartMs = _aboveSinceMs;
          // The hold window is over; no longer tracking it.
          _aboveSinceMs = -1;
          return GateOpened(_eventStartMs, ring.snapshot());
        }
      } else {
        // Dipped before the hold completed; reset the candidate.
        _aboveSinceMs = -1;
      }
    } else {
      // OPEN state: watch for a sustained run below tLow. Anywhere
      // between tLow (inclusive) and tHigh is "still in the event" —
      // that's the hysteresis band that keeps real snores from
      // fragmenting on intra-cycle dips.
      if (dbfs < tLowDbfs) {
        if (_belowSinceMs == -1) _belowSinceMs = nowMs;
        if (nowMs - _belowSinceMs >= AudioCfg.tailMs) {
          _open = false;
          final closedEventStart = _eventStartMs;
          _aboveSinceMs = -1;
          _belowSinceMs = -1;
          return GateClosed(closedEventStart, nowMs);
        }
      } else {
        // Came back up out of the tail; cancel close candidate.
        _belowSinceMs = -1;
      }
    }
    return null;
  }

  /// Clears all timing state and returns the gate to closed. Used by
  /// tests and at runtime when the calibration thresholds change — the
  /// hold/tail counters from one threshold pair are not meaningful under
  /// another.
  void reset() {
    _open = false;
    _aboveSinceMs = -1;
    _belowSinceMs = -1;
    _eventStartMs = 0;
  }
}
