/// Phase 7 — bounded encode queue with drop-oldest backpressure.
/// Spec §7.3 lines 850–872.
///
/// The recorder produces `ClassifiedEvent`s; Phase 6 writes a
/// `state='pending'` row (returning the event id); this queue takes
/// `(eventId, pcm, relPath, topLabel, labels)` and serializes the
/// encode + `markReady` flip. One encode in flight at a time.
///
/// **Backpressure:** drop-OLDEST on overflow. Spec §7.3 line 872:
/// "Drop-oldest is the right policy: newer events are more likely to
/// still be in-context for the user; the oldest is the easiest to lose."
/// When `submit` arrives at depth `>= EncoderCfg.encodeQueueMaxDepth`,
/// pop the head, log `encode_dropped_overflow` with the dropped row's
/// id, and call `repo.softDelete(droppedId)` so the timeline reflects
/// the loss rather than leaving a row stuck in `pending` until the
/// 60-second sweep catches it.
///
/// **Encode failure (ffmpeg returns non-zero, throws, etc.):** log
/// `encode_failed`, leave the row in `state='pending'`, do NOT
/// soft-delete. The pending sweep
/// (`lib/janitor/janitor.dart::sweepPending`) is the canonical recovery
/// path — it tears down the row and unlinks any `.tmp` after
/// `RetentionCfg.pendingGraceSeconds`. Soft-deleting on encode failure
/// would conflate "encoder died" with "queue overflow" in the audit
/// trail, and the orphan sweep would still have to clean up the same
/// `.tmp` regardless.
///
/// **Threading:** `FFmpegKit.execute` runs ffmpeg on a native platform
/// thread (the Dart-side `await` does not block the event loop), so
/// this queue can drain serially on the main isolate without stalling
/// the mic hot path. If device telemetry shows mic hiccups during
/// encode we'd `Isolate.spawn` this loop — but the spec's example uses
/// `await FFmpegKit.execute` directly, suggesting the same call-site
/// shape is expected here. See `lib/recorder/opus_encoder.dart` library
/// doc.
///
/// **Peaks generation (Phase 8 enabling):** between a successful encode
/// and `markReady`, the queue calls
/// `lib/recorder/peaks_writer.dart::writeEventPeaks` to produce the
/// `.peaks` sidecar. The peaks path stored on the row is
/// `events/YYYY-MM-DD/<ts>.peaks` — i.e. the audio path with the
/// extension swapped, NOT `<ts>.opus.peaks`. The player performs the
/// same conversion at read time so this is a single convention. Peaks
/// failure is **non-fatal**: the encoded `.opus` is already on disk, so
/// a missing sidecar is a lost convenience (player falls back to a flat
/// placeholder), not a broken event. The queue logs `peaks_failed`
/// with `{id, error}` and proceeds with `peaksPath=null`.
///
/// **Log events:** `encode_dropped_overflow`, `encode_failed`,
/// `encode_markready_missing`, `peaks_failed`.
///
/// **Constants discipline:** queue depth from
/// `EncoderCfg.encodeQueueMaxDepth`. No inline `8`. `onLog` injection
/// keeps the layer free of a real debug-log dependency until Phase 11
/// wires `DebugCfg`-backed logging.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

import '../config/constants.dart';
import '../data/event_repo.dart';
import 'opus_encoder.dart';
import 'peaks_writer.dart';

/// One unit of work for the encode queue. Constructed in
/// `RecorderService._emitEvent` after `repo.insertPending` resolves with
/// the new row id; submitted fire-and-forget via `EncodeQueue.submit`.
class EncodeJob {
  /// Row id from `EventRepo.insertPending`. The queue uses this to
  /// `markReady` on success or `softDelete` on overflow.
  final int eventId;

  /// PCM the classifier saw (int16 mono 16 kHz, matching `AudioCfg`).
  /// Held by reference until the encoder consumes it. The queue does
  /// NOT defensively copy — `RecorderService` constructs a fresh
  /// `Int16List` per event from `EventWindow.takePcm()` which already
  /// transfers ownership.
  final Int16List pcm;

  /// Canonical relative path the encoder writes to. Same string the
  /// `audioPath` column was inserted with in
  /// `EventRepo.insertPending` — must match exactly so the orphan sweep
  /// keeps the file alive.
  final String relPath;

  /// Top non-Other label, pre-computed in Phase 5
  /// (`ClassifiedEvent.topLabel`). Forwarded verbatim to `markReady`.
  final String topLabel;

  /// Curated label → confidence map from the classifier. Encoded to
  /// JSON via `EventRepo.encodeLabels` at `markReady` time.
  final Map<String, double> labels;

  const EncodeJob({
    required this.eventId,
    required this.pcm,
    required this.relPath,
    required this.topLabel,
    required this.labels,
  });
}

/// Logger seam. Phase 11 wires the real `DebugCfg`-backed log here; for
/// now production passes a no-op or a `print` shim. Kept as a positional-
/// callback typedef rather than an interface because the only call sites
/// are `_logOverflow` and `_logFailure` — an interface would be one
/// extra layer for two lines of code.
typedef EncodeLogger = void Function(String event, Map<String, Object?> fields);

/// Default no-op logger. Used when no `onLog` is injected (production
/// today; Phase 11 swaps this out at the construction site).
void _noopLogger(String event, Map<String, Object?> fields) {}

/// Bounded encode queue. One instance per recorder session; safe to
/// outlive the recorder (drain on `RecorderService.stop()` so we don't
/// lose in-flight encodes when the user taps Stop).
class EncodeQueue {
  final EventRepo _repo;
  final Directory _docsDir;
  final EncodeLogger _onLog;

  /// Encoder seam. Production calls `encodeEventToOpus`; tests inject a
  /// fake that synthesises an empty file or throws to exercise the
  /// failure path. Same nullable-injection pattern as
  /// `RecorderService.classifier` — typedef instead of an interface.
  final Future<File> Function({
    required Int16List pcm,
    required String relPath,
    required Directory docsDir,
  }) _encode;

  /// Peaks-writer seam. Production calls `writeEventPeaks`; tests inject
  /// a fake that throws to exercise the non-fatal failure path. Same
  /// pattern as the encoder seam above.
  final Future<String> Function({
    required Int16List pcm,
    required String audioRelPath,
    required Directory docsDir,
  }) _peaksWriter;

  /// FIFO of pending jobs. `Queue` (not `List`) so `removeFirst` is O(1)
  /// — the drop-oldest path runs on every submit, and we don't want it
  /// to be O(n) on a queue of `EncoderCfg.encodeQueueMaxDepth = 8` either.
  final Queue<EncodeJob> _queue = Queue<EncodeJob>();

  /// Depth cap. Defaults to `EncoderCfg.encodeQueueMaxDepth`; tests
  /// override to 2 or 3 to drive the overflow path with fewer fixtures.
  final int _maxDepth;

  /// `true` while `_drain` is awaiting an encode. Prevents two drain
  /// loops from running concurrently — `submit` only kicks off `_drain`
  /// when nothing is in flight.
  bool _draining = false;

  /// Resolved when `drain()` completes. Re-created each time the queue
  /// transitions from idle to busy so `drain()` callers always observe
  /// the current cycle, not a stale one. Null when idle.
  Completer<void>? _idleCompleter;

  EncodeQueue({
    required EventRepo repo,
    required Directory docsDir,
    EncodeLogger? onLog,
    int? maxDepth,
    Future<File> Function({
      required Int16List pcm,
      required String relPath,
      required Directory docsDir,
    })? encode,
    Future<String> Function({
      required Int16List pcm,
      required String audioRelPath,
      required Directory docsDir,
    })? peaksWriter,
  })  : _repo = repo,
        _docsDir = docsDir,
        _onLog = onLog ?? _noopLogger,
        _maxDepth = maxDepth ?? EncoderCfg.encodeQueueMaxDepth,
        _encode = encode ?? encodeEventToOpus,
        _peaksWriter = peaksWriter ?? writeEventPeaks;

  /// Number of jobs currently queued (not counting one in flight).
  /// Used by tests; not part of the production wire-up.
  int get pending => _queue.length;

  /// Submits a job. Fire-and-forget — no `Future` returned, because
  /// `RecorderService._emitEvent` is on the mic hot path and must not
  /// stall on disk I/O even for the time it takes to enqueue.
  ///
  /// On overflow (queue depth ≥ `_maxDepth` BEFORE this submit) the
  /// **oldest** queued job is dropped: pop the head, log
  /// `encode_dropped_overflow`, and soft-delete its event row. The new
  /// job is then enqueued. Spec §7.3.
  ///
  /// Note: an in-flight encode is NOT counted in the depth check —
  /// only the buffered tail is. This matches the spec's snippet
  /// (`if (_queue.length >= _maxDepth)`). Once `_drain` pulls a job off,
  /// the queue has a free slot again immediately.
  void submit(EncodeJob job) {
    if (_queue.length >= _maxDepth) {
      final oldest = _queue.removeFirst();
      _onLog('encode_dropped_overflow', {
        'id': oldest.eventId,
        'queueDepth': _queue.length + 1,
      });
      // Fire-and-forget soft-delete. The mic hot path must not block on
      // a DB write; if the soft-delete fails (DB closed, disk error)
      // the row stays in `pending` and the sweep handles it. We don't
      // even propagate the error to the logger because we'd be logging
      // a logger failure — the kind of recursion we don't want.
      // ignore: discarded_futures — fire-and-forget; see comment above.
      _repo.softDelete(oldest.eventId).catchError((_) {});
    }
    _queue.add(job);
    _kickDrain();
  }

  /// Returns when the queue is empty AND no encode is in flight.
  /// Resolves immediately when both conditions are already met, so it
  /// is safe to call from `RecorderService.stop()` even if no events
  /// were ever submitted.
  Future<void> drain() {
    if (!_draining && _queue.isEmpty) {
      return Future<void>.value();
    }
    return (_idleCompleter ??= Completer<void>()).future;
  }

  // ---- internals --------------------------------------------------------

  /// Starts `_drain` if it isn't already running. Idempotent — repeated
  /// calls during a busy drain do nothing.
  void _kickDrain() {
    if (_draining) return;
    if (_queue.isEmpty) return;
    _draining = true;
    _idleCompleter ??= Completer<void>();
    // Fire-and-forget — `_drain` owns the lifecycle of `_draining` and
    // `_idleCompleter`. The unawaited Future is intentional: `submit`
    // is fire-and-forget by contract, and `drain()` is the supported
    // way to wait.
    // ignore: discarded_futures — see comment above.
    _drain();
  }

  /// Serial drain loop. Pulls one job at a time, awaits the encode,
  /// then either calls `markReady` (success) or logs `encode_failed`
  /// (failure). One bad event does NOT poison the rest — the loop
  /// continues to the next job either way.
  Future<void> _drain() async {
    try {
      while (_queue.isNotEmpty) {
        final job = _queue.removeFirst();
        try {
          await _encode(
            pcm: job.pcm,
            relPath: job.relPath,
            docsDir: _docsDir,
          );
          // Encode + atomic rename succeeded. Generate the peaks
          // sidecar before flipping the row to `ready` so a successful
          // `markReady` always points at a valid (or null) peaks path.
          //
          // Peaks failure is **non-fatal**: the `.opus` is already on
          // disk, so a missing sidecar is a lost convenience (player
          // falls back to a placeholder), not a broken event. We log
          // `peaks_failed` and proceed with `peaksPath=null`.
          String? peaksPath;
          try {
            peaksPath = await _peaksWriter(
              pcm: job.pcm,
              audioRelPath: job.relPath,
              docsDir: _docsDir,
            );
          } catch (e) {
            _onLog('peaks_failed', {
              'id': job.eventId,
              'error': e.toString(),
            });
          }
          final ok = await _repo.markReady(
            id: job.eventId,
            topLabel: job.topLabel,
            labelsJson: EventRepo.encodeLabels(job.labels),
            peaksPath: peaksPath,
          );
          if (!ok) {
            // The row was already gone — almost certainly the pending
            // sweep tore it down because the encoder took longer than
            // `RetentionCfg.pendingGraceSeconds`. The encoded file is
            // now an orphan; the orphan sweep will collect it on the
            // next janitor cycle. Log so we can tell whether this is a
            // pathological pattern.
            _onLog('encode_markready_missing', {'id': job.eventId});
          }
        } catch (e) {
          // Encode failed (ffmpeg non-zero, scratch write failed, disk
          // full, etc.). Leave the row in `pending` — the pending sweep
          // is the canonical recovery path. Do NOT soft-delete here; we
          // reserve that for the queue-overflow case.
          _onLog('encode_failed', {
            'id': job.eventId,
            'error': e.toString(),
          });
        }
      }
    } finally {
      _draining = false;
      // Resolve the current cycle's completer (if any) so `drain()`
      // callers wake. Re-create on the next busy transition.
      final c = _idleCompleter;
      _idleCompleter = null;
      if (c != null && !c.isCompleted) c.complete();
    }
  }
}

