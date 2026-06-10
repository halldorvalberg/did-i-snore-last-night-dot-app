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

import '../classifier/label_map.dart';
import '../config/constants.dart';
import '../data/event_repo.dart';
import 'calibrator.dart';
import 'crash_heartbeat.dart';
import 'encode_queue.dart';
import 'energy.dart';
import 'event_window.dart';
import 'gate.dart';
import 'mic_source.dart';
import 'pcm_slicer.dart';
import 'ring_buffer.dart';
import 'spectral.dart';

/// Classifier seam — Phase 5 wire-up. Production passes
/// `yamnet.classify`; tests pass any function returning a fixed label →
/// confidence map. Typedef instead of an interface keeps the recorder free
/// of polymorphism it doesn't need (the only call site is `_onClose`).
typedef Classifier = Map<String, double> Function(Int16List pcm);

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
  static const String lowConfidence = 'low_confidence';

  /// Classifier threw during inference (interpreter not loaded, native-side
  /// failure, unsupported model output dtype). The event is dropped rather
  /// than emitted with empty labels because we want field reports to call
  /// out classifier health explicitly — silent fallback to `Other` would
  /// hide a broken model.
  static const String classifierError = 'classifier_error';
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

/// Phase 5 output: an accepted event together with its YAMNet labels and
/// pre-computed top label. Surfaced on the `events` stream; consumed by
/// the Phase 6 persistence layer (and any future encoder).
///
/// `pcm` carries the consumed PCM that was handed to the classifier — we
/// went with option (b) from the §5.3 wire-up brief because `EventWindow`
/// has no non-destructive int16 accessor, only `firstSamplesAsFloat32`
/// (used earlier by the spectral probe) and the single-use `takePcm`. Once
/// we consume `takePcm()` for classification, the window itself is sealed,
/// so the int16 data lives here on `ClassifiedEvent` instead.
class ClassifiedEvent {
  final EventWindow window;

  /// PCM consumed from `window.takePcm()` and reinterpreted as int16. The
  /// downstream encoder reads from here, not from the (now-sealed)
  /// `window`.
  final Int16List pcm;

  /// Curated label → confidence. Empty when classification was skipped
  /// (null `classifier`) or the precision floor zeroed every class.
  final Map<String, double> labels;

  /// Top non-`Other` label, falling back to `('Other', otherScore)` when
  /// no curated class survived. Pre-computed so the storage layer doesn't
  /// have to re-derive it.
  final String topLabel;
  final double topScore;

  const ClassifiedEvent({
    required this.window,
    required this.pcm,
    required this.labels,
    required this.topLabel,
    required this.topScore,
  });

  @override
  String toString() =>
      'ClassifiedEvent(start=${window.startMs}, '
      'duration=${window.durationMs}ms, '
      'topLabel=$topLabel, topScore=${topScore.toStringAsFixed(3)})';
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

  /// Optional classifier callback. When null, classification is skipped
  /// and accepted events are emitted with empty labels and `('Other',
  /// 0.0)` as the top label. Production wires this to `yamnet.classify`;
  /// the null path keeps unit tests free of native-tflite dependencies.
  final Classifier? _classifier;

  /// Optional persistence sink. When non-null, every accepted
  /// `ClassifiedEvent` triggers an `insertPending` row write before the
  /// event is added to the public `events` stream.
  ///
  /// Approach (a) from the Phase 6 brief: constructor injection on the
  /// recorder. Chosen over (b) — a separate side-effect listener — to
  /// keep the wire-up colocated with the producer. The downside is
  /// `RecorderService` now imports `data/`; in exchange, the call site
  /// is one line and the order-of-effects (DB write before stream emit)
  /// is impossible to get wrong.
  ///
  /// Null in unit tests so the existing harness keeps running without a
  /// `path_provider` plugin shim.
  final EventRepo? _repo;

  /// Optional encode queue. When non-null AND `_repo` is also non-null,
  /// every accepted event flows through `insertPending` → queue submit
  /// → encode → `markReady`. When null, the recorder stops at
  /// `insertPending` and the row stays `pending` forever (or until the
  /// 60-second sweep tears it down).
  ///
  /// Same nullable-injection pattern as `_repo`: tests pass null to
  /// keep the encoder out of scope, production constructs both
  /// together. The queue is NOT created internally because its
  /// `Directory docsDir` argument requires `getApplicationDocumentsDirectory()`
  /// which only works inside a Flutter binding — pushing the
  /// construction up to the caller (`main.dart` or the controller in
  /// Phase 8) keeps the recorder testable in pure Dart.
  final EncodeQueue? _encodeQueue;

  /// Whether the spectral pre-filter is enabled for this session.
  /// Decided once at construction from `noiseFloor.madDbfs`. Per spec
  /// §4.2 the filter is a fan-rejector that fails in noisy ambients, so
  /// noisy sessions skip it entirely and rely on YAMNet alone.
  final bool _filterEnabled;

  /// When true, `start()` writes the `session_started_at` marker and a
  /// periodic `last_heartbeat_at` to `shared_preferences`, and `stop()`
  /// flips to `last_clean_shutdown_at`. Tests that don't want to wire
  /// the `shared_preferences` mock pass `false`. Production wires
  /// `true` from the controller.
  final bool _crashHeartbeatEnabled;

  RecorderService._({
    required NoiseFloor noiseFloor,
    required MicSource mic,
    required PcmSlicer slicer,
    required RingBuffer ring,
    required Gate gate,
    required SpectralProbe probe,
    required Classifier? classifier,
    required EventRepo? repo,
    required EncodeQueue? encodeQueue,
    required bool crashHeartbeatEnabled,
  })  : _noiseFloor = noiseFloor,
        _mic = mic,
        _slicer = slicer,
        _ring = ring,
        _gate = gate,
        _probe = probe,
        _classifier = classifier,
        _repo = repo,
        _encodeQueue = encodeQueue,
        _crashHeartbeatEnabled = crashHeartbeatEnabled,
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
  ///
  /// `classifier` is optional. Production wires it to `yamnet.classify`
  /// (after `Yamnet.load()` completes). When null, the §5.3 reject policy
  /// is skipped; accepted events flow through with empty labels.
  factory RecorderService({
    required NoiseFloor noiseFloor,
    MicSource? mic,
    PcmSlicer? slicer,
    RingBuffer? ring,
    Gate? gate,
    SpectralProbe? probe,
    Classifier? classifier,
    EventRepo? repo,
    EncodeQueue? encodeQueue,
    bool crashHeartbeatEnabled = false,
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
      classifier: classifier,
      repo: repo,
      encodeQueue: encodeQueue,
      crashHeartbeatEnabled: crashHeartbeatEnabled,
    );
  }

  // ---- public streams ---------------------------------------------------

  final StreamController<ClassifiedEvent> _eventsOut =
      StreamController<ClassifiedEvent>.broadcast();
  final StreamController<RejectedEvent> _rejectionsOut =
      StreamController<RejectedEvent>.broadcast();

  /// One entry per accepted event (passed pre-filter and the YAMNet
  /// reject policy, ≥ minEventDurationMs). The element carries the
  /// `EventWindow` for context, the consumed PCM that the classifier saw,
  /// the curated label → confidence map, and the pre-computed top label.
  Stream<ClassifiedEvent> get events => _eventsOut.stream;

  /// Diagnostic stream of rejections. Not persisted.
  Stream<RejectedEvent> get rejections => _rejectionsOut.stream;

  /// Whether the spectral pre-filter will be applied this session. False
  /// when ambient was too noisy at calibration to make the filter
  /// reliable (see `SpectralCfg.maxAmbientMadForFilter`).
  bool get filterEnabled => _filterEnabled;

  // ---- lifecycle --------------------------------------------------------

  StreamSubscription<Uint8List>? _sub;
  bool _running = false;

  /// Periodic heartbeat timer — writes `last_heartbeat_at` every
  /// `RetentionCfg.heartbeatIntervalSeconds`. Started in `start()`,
  /// cancelled in `stop()`. Null when crash heartbeat is disabled or
  /// the recorder is idle.
  Timer? _heartbeatTimer;

  /// Outstanding `insertPending → submit` chains kicked off in
  /// `_emitEvent`. Each future removes itself via `whenComplete` once it
  /// resolves; `stop()` awaits `Future.wait(this set)` BEFORE draining the
  /// encode queue so a gate-close that fired ~ms before stop() can't slip
  /// past the drain barrier and leave its event in `pending` forever.
  /// Without this, the unawaited insertPending could resolve AFTER drain()
  /// has already returned (queue empty at the time it was checked).
  final Set<Future<void>> _pendingInserts = <Future<void>>{};

  /// True between `start()` and `stop()`.
  bool get isRunning => _running;

  /// Begins recording. Idempotent — a second call while running is a
  /// no-op.
  Future<void> start() async {
    if (_running) return;
    _running = true;
    _sub = _mic.pcm16.listen(_onChunk);
    await _mic.start();
    if (_crashHeartbeatEnabled) {
      // Mark the session-start anchor BEFORE the first heartbeat
      // fires so a crash within the first `heartbeatIntervalSeconds`
      // still has a `session_started_at` to recover from.
      // Fire-and-forget: the mic loop is already running and we don't
      // want to block on a SharedPreferences write.
      // ignore: discarded_futures — see comment above.
      CrashHeartbeat.markSessionStarted();
      _heartbeatTimer = Timer.periodic(
        const Duration(
          seconds: RetentionCfg.heartbeatIntervalSeconds,
        ),
        (_) {
          // Fire-and-forget: heartbeat writes are fast and best-effort.
          // ignore: discarded_futures — see comment above.
          CrashHeartbeat.writeHeartbeat();
        },
      );
    }
  }

  /// Stops recording, drops any in-flight event window, drains the
  /// encode queue, and closes the output streams. After `stop()` the
  /// service is not reusable.
  ///
  /// **Order matters:** mic stops first (no new chunks → no new
  /// gate-opens → no new `_emitEvent`), then we drain the queue so
  /// already-accepted events finish encoding before we close the output
  /// streams. Closing streams first would race a final emit against a
  /// listener cancellation; draining first would race the mic against
  /// a closed event sink.
  Future<void> stop() async {
    if (!_running) return;
    _running = false;
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    await _sub?.cancel();
    _sub = null;
    await _mic.stop();
    _probe.dispose();
    // An in-flight event window at stop time is by definition
    // incomplete — we can't apply duration/spectral filters because the
    // tail never closed. Drop it. Per spec §"Failure modes": "App
    // crashes mid-event → In-flight EventWindow is lost."
    _current = null;
    // Drain the encode queue so events already accepted before stop()
    // finish encoding rather than getting stuck in `pending` and waiting
    // for the 60-second sweep. `drain()` resolves immediately if no
    // queue was injected or the queue is already idle.
    //
    // Order: await any in-flight `insertPending → submit` chains FIRST
    // so the queue actually sees the late submits before we drain. A
    // gate-close that fires within ~ms of stop() leaves `_emitEvent`
    // mid-future; without this barrier, the queue would be empty at
    // drain time and the late submit would land on a queue nothing is
    // waiting on. The encode would still run (FFmpegKit is independent
    // of Dart lifecycle), but the docstring's "drain before close"
    // contract would be silently weakened.
    if (_pendingInserts.isNotEmpty) {
      await Future.wait(_pendingInserts.toList());
    }
    await _encodeQueue?.drain();
    if (!_eventsOut.isClosed) await _eventsOut.close();
    if (!_rejectionsOut.isClosed) await _rejectionsOut.close();
    if (_crashHeartbeatEnabled) {
      // Flip to "clean shutdown" so the next launch's crash detector
      // sees no orphaned session. Awaited (unlike start()) because
      // stop() is the slow path anyway — if shared_preferences hangs
      // for some reason, we'd rather see a bug report than have the
      // marker race the next start().
      await CrashHeartbeat.markCleanShutdown();
    }
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
      _classifyAndEmit(win, ev);
      return;
    }

    final samples = win.firstSamplesAsFloat32(_classifierSamples);
    if (samples.length < _classifierSamples) {
      // Not enough post-pre-roll audio for a stable spectral
      // measurement. Pass it through; the duration filter already
      // ensured ≥ minEventDurationMs of total audio, and YAMNet is
      // tolerant of 500 ms inputs (it pads internally).
      _classifyAndEmit(win, ev);
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

    _classifyAndEmit(win, ev);
  }

  /// Run the §5.3 reject policy and emit the surviving event. Called from
  /// `_onClose` after duration and (optional) spectral filters pass.
  ///
  /// When `_classifier` is null, classification is skipped and the event
  /// is emitted with an empty label map and `('Other', 0.0)` as the top
  /// label. This is the path taken in unit tests that don't want to drag
  /// the native tflite library into the harness.
  void _classifyAndEmit(EventWindow win, GateClosed ev) {
    // Consume the event window's PCM exactly once. We need int16 for the
    // classifier, and `EventWindow` only exposes Uint8 via `takePcm()` —
    // see option (b) in the §5.3 wire-up brief / `ClassifiedEvent` doc.
    //
    // `BytesBuilder.takeBytes()` returns a freshly allocated `Uint8List`
    // backed by a `ByteBuffer` at offset 0, so a zero-copy `Int16List.view`
    // is safe here (no alignment surprises like `firstSamplesAsFloat32`
    // hits when slicing a sub-view at an odd offset). Length is aligned
    // down to an even byte count defensively — odd byte counts would
    // mean a half-sample at the tail, which we discard.
    final bytes = win.takePcm();
    final samples = bytes.length >> 1;
    final pcm = Int16List.view(bytes.buffer, bytes.offsetInBytes, samples);

    final classifier = _classifier;
    if (classifier == null) {
      _emitEvent(ClassifiedEvent(
        window: win,
        pcm: pcm,
        labels: const {},
        topLabel: 'Other',
        topScore: 0.0,
      ));
      return;
    }

    // Classifier failures (interpreter not loaded, native-side error,
    // unsupported output dtype) must surface as a rejection rather than
    // silently degrading to `Other` — a broken model should be loud in
    // field reports, not invisible. The mic loop continues regardless;
    // the next event gets a fresh attempt.
    final Map<String, double> labels;
    try {
      labels = classifier(pcm);
    } catch (_) {
      _emitRejection(RejectedEvent(
        ev.startMs,
        ev.endMs,
        RejectionReason.classifierError,
        null,
      ));
      return;
    }
    final top = LabelMap.topLabel(labels);
    // `top.score` is already a non-Other score by `topLabel`'s contract
    // (`Other` is excluded from the contest, only used as the fallback
    // when no curated class survived). So if the returned label is
    // anything but 'Other', `maxCurated == top.score`; otherwise no
    // curated class scored above zero.
    final maxCurated = top.label == 'Other' ? 0.0 : top.score;
    final otherScore = labels['Other'] ?? 0.0;
    if (maxCurated < LabelCfg.minTopCuratedForKeep &&
        otherScore > LabelCfg.maxOtherForKeep) {
      _emitRejection(RejectedEvent(
        ev.startMs,
        ev.endMs,
        RejectionReason.lowConfidence,
        null,
      ));
      return;
    }

    _emitEvent(ClassifiedEvent(
      window: win,
      pcm: pcm,
      labels: labels,
      topLabel: top.label,
      topScore: top.score,
    ));
  }

  void _emitEvent(ClassifiedEvent ev) {
    // Phase 5 → Phase 6 bridge: write the `state='pending'` row before
    // surfacing the event on the stream. The insert is fire-and-forget
    // (no `await`) because the mic loop must not stall on disk I/O — a
    // slow DB write would back-pressure mic chunks and we'd start
    // dropping audio. Insert errors are swallowed; if they become a
    // real failure mode we'll surface them via debug telemetry in a
    // later phase.
    //
    // The `audioPath` here is the canonical layout from spec §6.3:
    // `events/YYYY-MM-DD/<startedAt>.opus`. Phase 7's encoder writes
    // the actual file at this path (via `<final>.tmp` → rename).
    //
    // Phase 7 wire-up: when `_encodeQueue` is non-null, chain the queue
    // submit off the insert future so the queue sees a row id that
    // already exists. Order matters: submitting before the row is
    // committed could (in principle) race a `markReady` against an
    // un-inserted row. The chain here keeps the mic hot path
    // non-blocking — `insertPending` resolves on a microtask, then
    // `submit` is a synchronous enqueue, then control returns. No
    // `await` on the mic side.
    final repo = _repo;
    if (repo != null) {
      final relPath = _audioRelPathForEvent(ev);
      final queue = _encodeQueue;
      // The chain is registered in `_pendingInserts` so `stop()` can
      // await it before draining the encode queue. Fire-and-forget on
      // the mic hot path (the chain awaits nothing on the producer side)
      // but tracked at the lifecycle level.
      late final Future<void> chain;
      chain = repo
          .insertPending(
            startedAt: ev.window.startMs,
            endedAt: ev.window.startMs + ev.window.durationMs,
            durationMs: ev.window.durationMs,
            audioPath: relPath,
          )
          .then((id) {
            if (queue != null && id > 0) {
              queue.submit(EncodeJob(
                eventId: id,
                pcm: ev.pcm,
                relPath: relPath,
                topLabel: ev.topLabel,
                labels: ev.labels,
              ));
            }
          })
          .catchError((_) {})
          .whenComplete(() => _pendingInserts.remove(chain));
      _pendingInserts.add(chain);
    }
    if (!_eventsOut.isClosed) _eventsOut.add(ev);
  }

  /// Canonical relative `audioPath` for a `ClassifiedEvent`, matching
  /// the layout in spec §6.3:
  /// `events/YYYY-MM-DD/<startedAt>.opus`.
  ///
  /// `YYYY-MM-DD` derives from `startedAt` in **local** time so the
  /// partition aligns with the local-day window the timeline query
  /// uses. (Spec §8 line 901 day-boundary policy.) UTC partitioning
  /// would mean a 19:00 PT event lands in tomorrow's folder for users
  /// west of UTC.
  static String _audioRelPathForEvent(ClassifiedEvent ev) {
    final dt = DateTime.fromMillisecondsSinceEpoch(ev.window.startMs);
    final y = dt.year.toString().padLeft(4, '0');
    final m = dt.month.toString().padLeft(2, '0');
    final d = dt.day.toString().padLeft(2, '0');
    return '${PathsCfg.eventsDir}/$y-$m-$d/'
        '${ev.window.startMs}${PathsCfg.audioExtension}';
  }

  void _emitRejection(RejectedEvent rej) {
    if (!_rejectionsOut.isClosed) _rejectionsOut.add(rej);
  }

  /// Suppress the unused-field analyzer warning for the noiseFloor
  /// reference. Future phases (the runtime downward refiner wiring) will
  /// use this; for now we keep the value reachable for diagnostics.
  NoiseFloor get noiseFloor => _noiseFloor;
}
