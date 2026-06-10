/// Riverpod controller for the recorder lifecycle.
///
/// Spec: `docs/IMPLEMENTATION.md` §8 line 881 — the `recorderControllerProvider`
/// owns `isRecording`, `start()`, and `stop()`. The home screen's big
/// button reads `isRecording` and dispatches the calls; the controller
/// shells the work into `RecorderService` and the encode queue.
///
/// **Why a `StateNotifierProvider`, not a Riverpod 3 `Notifier`:** the
/// project pins `flutter_riverpod ^2.5.1` (see `pubspec.yaml`).
/// Riverpod 2.x's `StateNotifierProvider` is the idiomatic shape for
/// mutable state with imperative lifecycle methods; switching to the
/// 3.x `Notifier` syntax later is a mechanical migration. Don't
/// pre-migrate just because the 3.x docs are easier to find.
///
/// **The recorder is NOT a long-lived singleton.** A new
/// `RecorderService` is constructed on every `start()` and disposed on
/// `stop()`. `RecorderService.stop()` closes its broadcast streams,
/// making the instance non-reusable; the controller honors that by
/// nulling the field after stop.
///
/// **Yamnet load on first start.** The 4.1 MB tflite model is loaded
/// lazily via `yamnetProvider`. On a cold first record-button tap the
/// `await` here adds ~1 s before the mic actually opens; the home
/// screen surfaces this with a spinner while the controller is in the
/// "starting" transient. Subsequent starts in the same process get a
/// cached classifier for free.
///
/// **`errorMessage` is one-shot.** The home screen listens via
/// `ref.listen(recorderControllerProvider)` and pops a SnackBar on
/// non-null error transitions; the controller does NOT clear the field
/// itself because the listener and the next `start()` both write to
/// state, and clearing would risk double-emission. The home screen
/// clears it back to null after surfacing.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../janitor/quota.dart';
import '../janitor/scheduler.dart';
import '../ui/providers.dart';
import 'calibrator_provider.dart';
import 'encode_queue.dart';
import 'recorder_service.dart';

/// Snapshot consumed by the home screen. Immutable; new instances on
/// every transition so Riverpod's identity-based change detection fires
/// reliably.
class RecorderState {
  /// True between `start()` resolving successfully and `stop()` being
  /// called.
  final bool isRecording;

  /// Local-time wall clock at which `start()` resolved. The home screen
  /// formats `(now - startedAt)` as `hh:mm:ss` for the elapsed display.
  /// Null when `isRecording == false`.
  final DateTime? startedAt;

  /// One-shot error from the most recent `start()`/`stop()`. The home
  /// screen surfaces it via SnackBar then clears it back to null. Null
  /// at all other times.
  final String? errorMessage;

  const RecorderState({
    required this.isRecording,
    required this.startedAt,
    required this.errorMessage,
  });

  /// Initial state — not recording, no error.
  factory RecorderState.idle() => const RecorderState(
        isRecording: false,
        startedAt: null,
        errorMessage: null,
      );

  RecorderState copyWith({
    bool? isRecording,
    DateTime? startedAt,
    Object? errorMessage = _sentinel,
  }) {
    return RecorderState(
      isRecording: isRecording ?? this.isRecording,
      startedAt: startedAt ?? this.startedAt,
      errorMessage: identical(errorMessage, _sentinel)
          ? this.errorMessage
          : errorMessage as String?,
    );
  }

  static const Object _sentinel = Object();
}

/// Owns one `RecorderService` at a time. Construction is cheap — heavy
/// work (mic open, classifier load) happens in `start()`.
class RecorderController extends StateNotifier<RecorderState> {
  RecorderController(this._ref) : super(RecorderState.idle());

  final Ref _ref;
  RecorderService? _service;

  /// Open the mic and begin a session. Idempotent — a second call while
  /// recording is a no-op (matching `RecorderService.start`).
  ///
  /// Order:
  ///   1. Read the persisted noise floor; bail with an error message
  ///      if calibration hasn't been run.
  ///   2. Resolve docs dir + classifier (both may take a microtask;
  ///      classifier load may take ~1 s on first run).
  ///   3. Construct the encode queue + recorder service against the
  ///      persisted floor.
  ///   4. Call `service.start()` and flip state to `isRecording: true`.
  ///
  /// Any thrown exception in steps 2–4 surfaces as `errorMessage` and
  /// leaves the state at `idle`. The service is left null so a retry
  /// constructs a fresh instance.
  Future<void> start() async {
    if (state.isRecording) return;

    final floor = _ref.read(persistedNoiseFloorProvider).valueOrNull;
    if (floor == null) {
      state = state.copyWith(
        errorMessage: 'Calibrate this room before recording.',
      );
      return;
    }

    try {
      final db = _ref.read(appDbProvider);
      final repo = _ref.read(eventRepoProvider);
      final docsDir = await _ref.read(docsDirProvider.future);

      // Phase 9 quota gate: refuse to start if free disk is below
      // `RetentionCfg.minFreeDiskMb` AND we can't free enough by
      // pruning unstarred events. The check also surfaces the pruned
      // count to telemetry; the UI reads `quotaResultProvider` for the
      // banner text.
      final quota = await checkQuota(db, docsDir);
      if (!quota.canRecord) {
        state = state.copyWith(
          errorMessage: quota.blockReason ??
              'Low storage — recording disabled.',
        );
        return;
      }

      final yamnet = await _ref.read(yamnetProvider.future);

      final queue = EncodeQueue(repo: repo, docsDir: docsDir);
      final service = RecorderService(
        noiseFloor: floor,
        repo: repo,
        encodeQueue: queue,
        classifier: yamnet.classify,
        crashHeartbeatEnabled: true,
      );
      await service.start();
      _service = service;
      state = RecorderState(
        isRecording: true,
        startedAt: DateTime.now(),
        errorMessage: null,
      );
    } catch (e) {
      _service = null;
      state = state.copyWith(errorMessage: 'Failed to start: $e');
    }
  }

  /// Close the mic and drain pending encodes. Idempotent.
  ///
  /// `RecorderService.stop()` blocks on the encode-queue drain so
  /// already-accepted events finish encoding before this future
  /// resolves. UI callers should show the button in a "stopping"
  /// indeterminate state while this is in flight; we don't model that
  /// in `RecorderState` because the drain is typically <100 ms and
  /// the button just disabling itself is enough.
  Future<void> stop() async {
    if (!state.isRecording) {
      return;
    }
    try {
      await _service?.stop();
    } catch (e) {
      state = state.copyWith(errorMessage: 'Failed to stop cleanly: $e');
    } finally {
      _service = null;
      // Always return to idle, even if stop() threw — the worst case
      // is a leaked native handle, and leaving the UI stuck in
      // "recording" is worse than the leak.
      state = RecorderState.idle().copyWith(
        errorMessage: state.errorMessage,
      );
    }
    // Phase 9 iOS-stop hook: kick a janitor cycle off the back of
    // every clean stop. The helper is a no-op on Android (WorkManager
    // owns cadence there). Fire-and-forget; we don't block the UI on
    // a janitor cycle.
    final db = _ref.read(appDbProvider);
    final docsDir = await _ref.read(docsDirProvider.future);
    // ignore: discarded_futures — fire-and-forget by design.
    runOnRecorderStop(db: db, docsDir: docsDir);
  }

  /// Clear the one-shot error message after the UI surfaced it. See
  /// the file header for why the controller doesn't clear it itself.
  void clearError() {
    if (state.errorMessage != null) {
      state = state.copyWith(errorMessage: null);
    }
  }

  @override
  void dispose() {
    // Not awaited — Riverpod disposal is sync. If the user navigates
    // away mid-recording the service finalises in the background; the
    // mic loop's broadcast streams are closed and the encode queue
    // drains independently of the controller.
    final svc = _service;
    _service = null;
    if (svc != null) {
      // ignore: discarded_futures — see comment above.
      svc.stop();
    }
    super.dispose();
  }
}

/// Singleton-per-scope controller. `StateNotifierProvider` (Riverpod
/// 2.x) — not the 3.x `NotifierProvider`; see file header.
final recorderControllerProvider =
    StateNotifierProvider<RecorderController, RecorderState>(
  (ref) => RecorderController(ref),
);
