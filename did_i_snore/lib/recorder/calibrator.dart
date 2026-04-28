/// Phase 3 calibration: median+MAD noise floor estimator, the interactive
/// session controller used by the calibration screen, and the runtime
/// downward refiner that may *only* lower `tHigh` mid-session.
///
/// This file is split into three layers, in order of strictness:
///
/// 1. [NoiseFloor] + [estimateFloor] + [RuntimeFloorRefiner] — pure Dart.
///    No Flutter, no I/O, no plugins. Trivially unit-testable.
/// 2. [CalibrationState] — pure value type emitted by the live stream.
/// 3. [Calibrator] — owns a [MicSource] + [PcmSlicer] and runs the
///    interactive 30-second session. This layer is Flutter-y because the
///    plugin under [MicSource] is, but the math above is not.
///
/// Persistence lives in `calibrator_store.dart` and is consumed here at
/// `save()` time. Riverpod glue lives in `calibrator_provider.dart` so the
/// class itself stays Riverpod-free.
library;

import 'dart:async';
import 'dart:typed_data';

import '../config/constants.dart';
import 'calibrator_store.dart';
import 'energy.dart';
import 'mic_source.dart';
import 'pcm_slicer.dart';

// ---------------------------------------------------------------------------
// 1. Pure math: NoiseFloor, estimateFloor, RuntimeFloorRefiner.
// ---------------------------------------------------------------------------

/// Immutable median+MAD noise floor with derived gate thresholds.
///
/// `tHigh = median + madK * MAD` — the level the input has to exceed (and
/// hold for `gateHoldMs`) to open the gate. `tLow = median + (madK-2) * MAD`
/// — the closing threshold; the 2 MAD-units gap is the hysteresis spec.
class NoiseFloor {
  final double medianDbfs;
  final double madDbfs;

  const NoiseFloor(this.medianDbfs, this.madDbfs);

  double get tHighDbfs => medianDbfs + GateCfg.madK * madDbfs;
  double get tLowDbfs => medianDbfs + (GateCfg.madK - 2.0) * madDbfs;

  @override
  String toString() =>
      'NoiseFloor(median=${medianDbfs.toStringAsFixed(2)} dBFS, '
      'mad=${madDbfs.toStringAsFixed(2)} dBFS, '
      'tHigh=${tHighDbfs.toStringAsFixed(2)}, '
      'tLow=${tLowDbfs.toStringAsFixed(2)})';

  @override
  bool operator ==(Object other) =>
      other is NoiseFloor &&
      other.medianDbfs == medianDbfs &&
      other.madDbfs == madDbfs;

  @override
  int get hashCode => Object.hash(medianDbfs, madDbfs);
}

/// Pure median+MAD over a list of frame-RMS dBFS values.
///
/// Median uses `length ~/ 2` (the lower middle on even-length inputs), not
/// the average of the two middle values. For ~1500 frames the difference
/// is below the precision MAD itself can resolve.
///
/// MAD is the median of absolute deviations from the median. When all
/// values are identical it is 0; downstream consumers must tolerate that
/// (no division by MAD anywhere in this module).
///
/// Throws [ArgumentError] on empty input — there is no sensible "noise
/// floor of nothing".
NoiseFloor estimateFloor(List<double> frameDbfs) {
  if (frameDbfs.isEmpty) {
    throw ArgumentError.value(frameDbfs, 'frameDbfs', 'must not be empty');
  }
  final sorted = List<double>.from(frameDbfs)..sort();
  final median = sorted[sorted.length ~/ 2];
  final deviations = List<double>.generate(
    sorted.length,
    (i) => (sorted[i] - median).abs(),
    growable: false,
  )..sort();
  final mad = deviations[deviations.length ~/ 2];
  return NoiseFloor(median, mad);
}

/// Runtime downward refinement of the noise floor.
///
/// Plugged into the recorder; fed median + MAD + variance over a 5-minute
/// rolling window of frame-RMS. This class is the spec's hard guarantee
/// against the failure mode "the user starts snoring at minute zero and
/// we silently raise `tHigh` until we miss the rest of the night":
///
///   - It NEVER raises `tHigh`. The current floor is a monotonic lower
///     bound on `tHigh` for the session.
///   - It only adopts a candidate when the window's variance is below
///     `GateCfg.maxRefinementVarianceDbfs2` — otherwise the window wasn't
///     really quiet and the candidate's median is misleading.
///
/// "Refinement" is therefore strictly downward and rare. Calibration
/// proper is the user's job.
class RuntimeFloorRefiner {
  final NoiseFloor initial;
  NoiseFloor _current;

  RuntimeFloorRefiner(this.initial) : _current = initial;

  NoiseFloor get current => _current;

  /// Considers a candidate computed over the last 5 minutes of frame-RMS.
  ///
  /// `windowVarianceDbfs2` is the population variance of the same window
  /// (units: dBFS^2). The "was the window actually quiet?" gate is just a
  /// stddev check spelled in variance to avoid a sqrt; threshold is
  /// 9.0 dBFS^2 = stddev 3 dB.
  void maybeRefine({
    required double windowMedianDbfs,
    required double windowMadDbfs,
    required double windowVarianceDbfs2,
  }) {
    if (windowVarianceDbfs2 > GateCfg.maxRefinementVarianceDbfs2) {
      return;
    }
    final candidate = NoiseFloor(windowMedianDbfs, windowMadDbfs);
    if (candidate.tHighDbfs >= _current.tHighDbfs) {
      return;
    }
    _current = candidate;
  }
}

// ---------------------------------------------------------------------------
// 2. CalibrationState — value type emitted to the UI at ~10 Hz.
// ---------------------------------------------------------------------------

/// Snapshot of the live calibration session for the UI to render.
///
/// `historyDbfs` is the last 30 seconds of 100 ms-smoothed RMS values
/// (length up to 300). `estimatedFloorDbfs` is the running median of
/// every frame-RMS collected so far this session — the UI uses it to
/// gate the Save button via `canSave`.
class CalibrationState {
  /// Latest 100 ms-smoothed RMS in dBFS.
  final double rmsDbfs;

  /// Sliding 30-second strip of 100 ms-smoothed values, oldest-first.
  /// Length up to 300 (30 s * 10 Hz).
  final List<double> historyDbfs;

  /// Running median of *all* frame-RMS values collected so far. Used as
  /// the "estimated quiet floor" the contiguous-quiet timer compares to.
  final double estimatedFloorDbfs;

  /// Milliseconds the smoothed RMS has stayed at or below
  /// `estimatedFloorDbfs` without interruption.
  final int contiguousQuietMs;

  /// True iff the user has met the "≥10 contiguous seconds quiet"
  /// requirement and a `save()` would not throw.
  final bool canSave;

  const CalibrationState({
    required this.rmsDbfs,
    required this.historyDbfs,
    required this.estimatedFloorDbfs,
    required this.contiguousQuietMs,
    required this.canSave,
  });
}

// ---------------------------------------------------------------------------
// 3. Calibrator — interactive session controller.
// ---------------------------------------------------------------------------

/// Minimum contiguous-quiet window (ms) required before [Calibrator.save]
/// will succeed. Spec §3.1.
const int _minContiguousQuietMs = 10000;

/// Number of 20 ms frames in a 100 ms smoothing window.
const int _smoothingFrames = 5;

/// Number of 100 ms ticks in a 30-second history strip.
const int _historyTicks = 300;

/// Initial capacity of the collected frame-RMS buffer. 30 s * 50 Hz = 1500
/// frames is the typical session length, but `Calibrator` lets the user
/// run longer if they want — buffer doubles when full.
const int _initialFrameRmsCapacity = 2048;

/// Owns a [MicSource] + [PcmSlicer] for a calibration session and emits a
/// `Stream<CalibrationState>` for the UI to render.
///
/// Lifecycle: `start()` -> stream emits at ~10 Hz -> user observes ->
/// `save()` (computes [NoiseFloor], persists via [CalibrationStore],
/// returns it) -> `stop()`. `reset()` zeros internal buffers without
/// stopping the mic — for the "Cancel and try again" link.
///
/// All math runs on the main isolate during this brief interactive flow.
/// The recorder isolate is a Phase 4+ concern; calibration is a foreground
/// user action that lasts seconds.
class Calibrator {
  final MicSource _mic;
  final PcmSlicer _slicer;
  final CalibrationStore _store;

  /// `late final` so subclassed test doubles can pass a stub mic; the
  /// owned mic is lazily started.
  Calibrator({
    MicSource? mic,
    PcmSlicer? slicer,
    CalibrationStore? store,
  })  : _mic = mic ?? MicSource(),
        _slicer = slicer ?? PcmSlicer(frameBytes: AudioCfg.frameBytes),
        _store = store ?? CalibrationStore();

  // --- Public stream ------------------------------------------------------

  final StreamController<CalibrationState> _stateOut =
      StreamController<CalibrationState>.broadcast();

  Stream<CalibrationState> get state => _stateOut.stream;

  // --- Smoothing + history ------------------------------------------------

  /// Ring of the last 5 mean-square values. Index `[_smoothIdx % 5]` is
  /// the slot to overwrite next; once `_smoothFilled == 5` we have a full
  /// window.
  final Float64List _smoothMs = Float64List(_smoothingFrames);
  int _smoothIdx = 0;
  int _smoothFilled = 0;

  /// Frame counter inside the current 100 ms tick. Emit a CalibrationState
  /// every 5 frames.
  int _framesSinceTick = 0;

  /// Sliding history of 100 ms-smoothed dBFS values, oldest-first.
  final List<double> _history = <double>[];

  // --- Collected frame-RMS for the final estimate -------------------------

  /// All frame-RMS dBFS values collected this session. Float32List grown
  /// in chunks; `List<double>` would box every value at 50 Hz.
  Float32List _frameDbfs = Float32List(_initialFrameRmsCapacity);
  int _frameDbfsLen = 0;

  // --- Quiet-streak tracker ----------------------------------------------

  int _contiguousQuietMs = 0;

  // --- Mic subscription ---------------------------------------------------

  StreamSubscription<Uint8List>? _sub;
  bool _running = false;

  /// Starts the mic and begins emitting `CalibrationState` events.
  /// Idempotent — calling twice is a no-op after the first.
  Future<void> start() async {
    if (_running) return;
    _running = true;
    _sub = _mic.pcm16.listen(_onChunk);
    await _mic.start();
  }

  /// Stops the mic and closes resources. Safe to call multiple times.
  Future<void> stop() async {
    _running = false;
    await _sub?.cancel();
    _sub = null;
    await _mic.stop();
  }

  /// Clears collected frames + history without stopping the mic. The
  /// stream keeps emitting; the UI sees the strip and counters reset.
  Future<void> reset() async {
    _frameDbfsLen = 0;
    _smoothIdx = 0;
    _smoothFilled = 0;
    _framesSinceTick = 0;
    _history.clear();
    _contiguousQuietMs = 0;
  }

  /// Estimates [NoiseFloor] from every collected frame-RMS this session,
  /// persists it via [CalibrationStore], and returns it.
  ///
  /// Throws [StateError] if the contiguous-quiet requirement has not yet
  /// been met. The UI should disable the Save button when `canSave` is
  /// false; this throw is a defensive check, not the primary gate.
  Future<NoiseFloor> save() async {
    if (_contiguousQuietMs < _minContiguousQuietMs) {
      throw StateError(
        'calibration not yet savable — contiguous quiet only '
        '$_contiguousQuietMs ms (need $_minContiguousQuietMs)',
      );
    }
    if (_frameDbfsLen == 0) {
      throw StateError('no frames collected');
    }
    // Copy the live region into a regular List<double> for estimateFloor.
    // estimateFloor sorts a defensive copy anyway, so the conversion is
    // not redundant work.
    final values = List<double>.generate(
      _frameDbfsLen,
      (i) => _frameDbfs[i],
      growable: false,
    );
    final floor = estimateFloor(values);
    await _store.save(floor);
    return floor;
  }

  /// Closes the broadcast stream. Call after [stop] when the calibrator
  /// is no longer needed.
  Future<void> dispose() async {
    await stop();
    await _stateOut.close();
  }

  // --- Internals ----------------------------------------------------------

  /// Mic chunk arrived. Re-frame to 20 ms frames, compute mean-square per
  /// frame, append to the rolling 5-frame smoothing ring, and on every
  /// 5th frame emit a CalibrationState.
  void _onChunk(Uint8List chunk) {
    for (final frame in _slicer.sliceChunk(chunk)) {
      _onFrame(frame);
    }
  }

  void _onFrame(Uint8List frame) {
    final ms = meanSquare(frame);
    final dbfs = rmsDbfs(ms);

    _appendFrameDbfs(dbfs);

    _smoothMs[_smoothIdx % _smoothingFrames] = ms;
    _smoothIdx++;
    if (_smoothFilled < _smoothingFrames) _smoothFilled++;

    _framesSinceTick++;
    if (_framesSinceTick >= _smoothingFrames) {
      _framesSinceTick = 0;
      _emitTick();
    }
  }

  void _appendFrameDbfs(double dbfs) {
    if (_frameDbfsLen == _frameDbfs.length) {
      final grown = Float32List(_frameDbfs.length * 2);
      grown.setRange(0, _frameDbfs.length, _frameDbfs);
      _frameDbfs = grown;
    }
    _frameDbfs[_frameDbfsLen++] = dbfs;
  }

  /// Compute the 100 ms-smoothed RMS, update history + quiet streak,
  /// and emit a CalibrationState. Called every 5 frames (every 100 ms).
  void _emitTick() {
    // 100 ms-smoothed: mean of the last 5 mean-square values, then to dBFS.
    var sumMs = 0.0;
    for (var i = 0; i < _smoothFilled; i++) {
      sumMs += _smoothMs[i];
    }
    final smoothedMs = sumMs / _smoothFilled;
    final smoothedDbfs = rmsDbfs(smoothedMs);

    _history.add(smoothedDbfs);
    if (_history.length > _historyTicks) {
      _history.removeAt(0);
    }

    // Running median over collected frame-RMS. Re-sorting once per UI
    // tick (10 Hz) over <=1500-3000 doubles is fine; doing it per frame
    // (50 Hz) wouldn't be. The final save() does its own sort.
    final estimatedFloor = _runningMedianDbfs();

    if (smoothedDbfs <= estimatedFloor) {
      _contiguousQuietMs += AudioCfg.frameMs * _smoothingFrames;
    } else {
      _contiguousQuietMs = 0;
    }

    if (!_stateOut.isClosed) {
      _stateOut.add(CalibrationState(
        rmsDbfs: smoothedDbfs,
        historyDbfs: List<double>.unmodifiable(_history),
        estimatedFloorDbfs: estimatedFloor,
        contiguousQuietMs: _contiguousQuietMs,
        canSave: _contiguousQuietMs >= _minContiguousQuietMs,
      ));
    }
  }

  /// Median of all collected frame-RMS dBFS values so far. Returns
  /// `double.negativeInfinity` if no frames have been collected yet, so
  /// the very first tick's `smoothedDbfs <= estimatedFloor` check is
  /// false (no quiet credit before we know the floor).
  double _runningMedianDbfs() {
    if (_frameDbfsLen == 0) return double.negativeInfinity;
    final copy = Float32List(_frameDbfsLen);
    copy.setRange(0, _frameDbfsLen, _frameDbfs);
    // Float32List has no in-place sort. Float64List does, but the
    // collection itself is on the order of a few thousand doubles after
    // 30 seconds; sorting via a List<double> view is cheap.
    final list = List<double>.generate(
      _frameDbfsLen,
      (i) => copy[i],
      growable: false,
    )..sort();
    return list[list.length ~/ 2];
  }
}
