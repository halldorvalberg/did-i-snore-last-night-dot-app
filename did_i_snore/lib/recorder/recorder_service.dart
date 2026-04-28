/// Phase 4 wire-up: mic → slicer → ring → gate → event window → spectral
/// pre-filter → events stream. Pure Dart orchestration.
///
/// **This is NOT the production Android recorder.** Phase 1.4 locked in a
/// native Kotlin foreground service that owns `AudioRecord` directly; on
/// Android, this Dart `RecorderService` only runs in the dev test harness
/// (driving the same Dart-side pipeline against a `MicSource` that wraps
/// the `record` plugin). On iOS, this IS the recorder — iOS doesn't have
/// the FGS-promotion timer or the plugin-driven listener race that forced
/// Android native. Future contributor reading this file: do not wire this
/// into the Android FGS path. See `docs/IMPLEMENTATION.md` §1.4.
///
/// Loop, per 20 ms frame:
///
///   1. Compute mean-square → dBFS.
///   2. Push raw bytes into `ring` (always; the next gate-open will
///      snapshot the ring as pre-roll).
///   3. If an `EventWindow` is open, also append the live bytes.
///   4. Feed `(dbfs, nowMs)` to `gate`. On `GateOpened` we open a
///      window seeded with the ring snapshot. On `GateClosed` we
///      finalize: duration filter → (optional) spectral filter → emit
///      on `events` or `rejections`.
///
/// Backpressure: `events` and `rejections` are **broadcast** controllers.
/// The recorder must not stall the mic loop on a slow consumer; broadcast
/// is the cheapest way to guarantee that. Listeners that drop messages
/// just lose telemetry; the mic keeps running.
library;

import 'dart:async';
import 'dart:typed_data';

import '../config/constants.dart';
import 'calibrator.dart';
import 'energy.dart';
import 'event_window.dart';
import 'gate.dart';
import 'mic_source.dart';
import 'pcm_slicer.dart';
import 'ring_buffer.dart';
import 'spectral.dart';

/// Pre-roll capacity in bytes. Derived once from `AudioCfg`.
const int _ringBytes = AudioCfg.sampleRateHz * 2 * AudioCfg.preRollMs ~/ 1000;

/// Number of int16 samples in one classifier frame (= 960 ms × 16 kHz).
/// Used to slice the spectral-probe input out of the event window.
const int _classifierSamples =
    AudioCfg.classifierFrameMs * AudioCfg.sampleRateHz ~/ 1000;

/// Reasons a closed gate-event was dropped before it became a persisted
/// event. Plain string constants instead of an enum so the values can be
/// logged as-is in `debug.log` and grepped for in field reports.
class RejectionReason {
  static const String minDuration = 'min_duration';
  static const String spectralBand = 'spectral_band';
  static const String spectralFlatness = 'spectral_flatness';
}

/// Diagnostic record for a rejected event. Not persisted — surfaced only
/// on the `rejections` stream for the debug log and tuning UI.
class RejectedEvent {
  final int startMs;
  final int endMs;
  final String reason;
  final SpectralReading? reading;

  const RejectedEvent(this.startMs, this.endMs, this.reason, this.reading);

  int get durationMs => endMs - startMs;

  @override
  String toString() =>
      'RejectedEvent(start=$startMs, end=$endMs, reason=$reason, '
      'reading=$reading)';
}

/// Orchestrates the Phase 4 pipeline. One instance per session; not
/// reusable after `stop()` (broadcast controllers are closed).
class RecorderService {
  final NoiseFloor _noiseFloor;
  final MicSource _mic;
  final PcmSlicer _slicer;
  final RingBuffer _ring;
  final Gate _gate;
  final SpectralProbe _probe;

  /// Whether the spectral pre-filter is enabled for this session.
  /// Decided once at construction from `noiseFloor.madDbfs`. Per spec
  /// §4.2 the filter is a fan-rejector that fails in noisy ambients, so
  /// noisy sessions skip it entirely and rely on YAMNet alone.
  final bool _filterEnabled;

  RecorderService._({
    required NoiseFloor noiseFloor,
    required MicSource mic,
    required PcmSlicer slicer,
    required RingBuffer ring,
    required Gate gate,
    required SpectralProbe probe,
  })  : _noiseFloor = noiseFloor,
        _mic = mic,
        _slicer = slicer,
        _ring = ring,
        _gate = gate,
        _probe = probe,
        _filterEnabled =
            noiseFloor.madDbfs <= SpectralCfg.maxAmbientMadForFilter {
    // The gate's ring MUST be the same instance as the recorder's ring,
    // or the open-time snapshot would be out of sync with the bytes the
    // recorder is feeding it. Asserting here catches misconfiguration in
    // dev; in production it's a constructor invariant.
    assert(
      identical(_gate.ring, _ring),
      'Gate must share the same RingBuffer as the RecorderService',
    );
  }

  /// Construct with sensible defaults. Pass overrides for testing.
  factory RecorderService({
    required NoiseFloor noiseFloor,
    MicSource? mic,
    PcmSlicer? slicer,
    RingBuffer? ring,
    Gate? gate,
    SpectralProbe? probe,
  }) {
    final r = ring ?? RingBuffer(_ringBytes);
    final g = gate ??
        Gate(
          ring: r,
          tHighDbfs: noiseFloor.tHighDbfs,
          tLowDbfs: noiseFloor.tLowDbfs,
        );
    return RecorderService._(
      noiseFloor: noiseFloor,
      mic: mic ?? MicSource(),
      slicer: slicer ?? PcmSlicer(frameBytes: AudioCfg.frameBytes),
      ring: r,
      gate: g,
      probe: probe ?? SpectralProbe(),
    );
  }

  // ---- public streams ---------------------------------------------------

  final StreamController<EventWindow> _eventsOut =
      StreamController<EventWindow>.broadcast();
  final StreamController<RejectedEvent> _rejectionsOut =
      StreamController<RejectedEvent>.broadcast();

  /// One entry per accepted event (passed pre-filter, ≥ minEventDurationMs).
  /// PCM is included so downstream (encoder, classifier, EventRepo) does
  /// not have to consult the ring.
  Stream<EventWindow> get events => _eventsOut.stream;

  /// Diagnostic stream of rejections. Not persisted.
  Stream<RejectedEvent> get rejections => _rejectionsOut.stream;

  /// Whether the spectral pre-filter will be applied this session. False
  /// when ambient was too noisy at calibration to make the filter
  /// reliable (see `SpectralCfg.maxAmbientMadForFilter`).
  bool get filterEnabled => _filterEnabled;

  // ---- lifecycle --------------------------------------------------------

  StreamSubscription<Uint8List>? _sub;
  bool _running = false;

  /// True between `start()` and `stop()`.
  bool get isRunning => _running;

  /// Begins recording. Idempotent — a second call while running is a
  /// no-op.
  Future<void> start() async {
    if (_running) return;
    _running = true;
    _sub = _mic.pcm16.listen(_onChunk);
    await _mic.start();
  }

  /// Stops recording, drops any in-flight event window, and closes the
  /// output streams. After `stop()` the service is not reusable.
  Future<void> stop() async {
    if (!_running) return;
    _running = false;
    await _sub?.cancel();
    _sub = null;
    await _mic.stop();
    _probe.dispose();
    // An in-flight event window at stop time is by definition
    // incomplete — we can't apply duration/spectral filters because the
    // tail never closed. Drop it. Per spec §"Failure modes": "App
    // crashes mid-event → In-flight EventWindow is lost."
    _current = null;
    if (!_eventsOut.isClosed) await _eventsOut.close();
    if (!_rejectionsOut.isClosed) await _rejectionsOut.close();
  }

  // ---- hot path ---------------------------------------------------------

  /// In-flight event window, set on `GateOpened`, cleared on
  /// `GateClosed` (or on `stop()`).
  EventWindow? _current;

  /// Process one mic chunk. Called from the broadcast stream listener;
  /// must be allocation-light (the only allocations on the no-event path
  /// are slicer-internal copies on chunk-stitch boundaries).
  void _onChunk(Uint8List chunk) {
    // 1. Push to the ring first so the next gate-open's snapshot
    //    includes everything up to and including this chunk.
    _ring.write(chunk);

    // 2. Append to the in-flight window if one is open. We append the
    //    raw chunk, not per-frame, so we don't lose the sub-frame
    //    bytes the slicer holds in its tail. This makes the window's
    //    PCM exactly the bytes the mic produced between open and close,
    //    aside from the pre-roll prefix.
    _current?.appendChunk(chunk);

    // 3. Re-frame to 20 ms frames and feed the gate.
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    for (final frame in _slicer.sliceChunk(chunk)) {
      final ms = meanSquare(frame);
      final dbfs = rmsDbfs(ms);
      final ev = _gate.feed(dbfs, nowMs);
      if (ev is GateOpened) {
        _current = EventWindow(ev.startMs, ev.preRoll);
      } else if (ev is GateClosed) {
        _onClose(ev);
      }
    }
  }

  /// Finalize a closed event: duration filter → optional spectral filter →
  /// emit. Called from the slicer loop the moment `gate.feed` reports
  /// `GateClosed`. There is exactly one in-flight window.
  void _onClose(GateClosed ev) {
    final win = _current;
    _current = null;
    if (win == null) {
      // Defensive: shouldn't happen under the gate's contract (one open
      // before each close), but if it does, log nothing — the event
      // didn't exist.
      return;
    }

    final durationMs = win.durationMs;
    if (durationMs < AudioCfg.minEventDurationMs) {
      _emitRejection(RejectedEvent(
        ev.startMs,
        ev.endMs,
        RejectionReason.minDuration,
        null,
      ));
      return;
    }

    if (!_filterEnabled) {
      // Noisy-ambient session: skip the spectral pre-filter, defer to
      // YAMNet downstream. Spec §4.2.
      _emitEvent(win);
      return;
    }

    final samples = win.firstSamplesAsFloat32(_classifierSamples);
    if (samples.length < _classifierSamples) {
      // Not enough post-pre-roll audio for a stable spectral
      // measurement. Pass it through; the duration filter already
      // ensured ≥ minEventDurationMs of total audio, and YAMNet is
      // tolerant of 500 ms inputs (it pads internally).
      _emitEvent(win);
      return;
    }

    final reading = _probe.analyze(samples);
    if (reading.snoreBandFraction < SpectralCfg.minSnoreBandFraction) {
      _emitRejection(RejectedEvent(
        ev.startMs,
        ev.endMs,
        RejectionReason.spectralBand,
        reading,
      ));
      return;
    }
    if (reading.flatness > SpectralCfg.maxFlatness) {
      _emitRejection(RejectedEvent(
        ev.startMs,
        ev.endMs,
        RejectionReason.spectralFlatness,
        reading,
      ));
      return;
    }

    _emitEvent(win);
  }

  void _emitEvent(EventWindow win) {
    if (!_eventsOut.isClosed) _eventsOut.add(win);
  }

  void _emitRejection(RejectedEvent rej) {
    if (!_rejectionsOut.isClosed) _rejectionsOut.add(rej);
  }

  /// Suppress the unused-field analyzer warning for the noiseFloor
  /// reference. Future phases (the runtime downward refiner wiring) will
  /// use this; for now we keep the value reachable for diagnostics.
  NoiseFloor get noiseFloor => _noiseFloor;
}
