/// Mic capture source. Produces a broadcast stream of raw int16 mono 16 kHz
/// PCM bytes for the downstream slicer + ring buffer.
///
/// Platform split (docs/IMPLEMENTATION.md §1.4 / §2.1):
///
///   - **Android**: capture is owned by a native Kotlin foreground `Service`
///     (`RecorderService`) that holds `AudioRecord` directly. The Dart
///     `record` plugin is NOT viable on Android 14+ — it failed Phase 1 with
///     the FGS-promotion SIGKILL (bug A) and the isolate listener race
///     (bug B). Here `MicSource` is a thin client: it starts/stops the
///     service over a `MethodChannel` and receives PCM chunks over an
///     `EventChannel`, forwarding them onto the same `_out` controller.
///
///   - **iOS / everything else** (incl. the Dart-VM test host, where
///     `Platform.isAndroid` is false): the original `record` 6.x streaming
///     path, unchanged. iOS has no FGS-promotion timer; the Swift
///     `AVAudioSession` config in §1.2 handles background survival there.
///
/// Crash detection is Dart-side (`CrashHeartbeat` over `shared_preferences`),
/// NOT a heartbeat file — the native service deliberately writes no heartbeat.
///
/// Hot-path discipline: this code runs all night on battery. No widgets, no
/// `setState`, no per-byte allocations. Chunks pass through as-is to the
/// downstream slicer + ring buffer.
///
/// `record` 6.2.0 API note: matches the IMPLEMENTATION.md 2.1 sketch
/// (`AudioRecorder`, `RecordConfig`, `startStream`, `hasPermission`). The
/// only addition is `androidConfig: AndroidRecordConfig(audioSource:
/// AndroidAudioSource.unprocessed)` to disable OS-level AGC / NS that would
/// distort calibration thresholds. (That config is unused on the native
/// Android path, which sets `UNPROCESSED` itself in Kotlin.)
library;

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';

import '../config/constants.dart';

/// Streams raw 16-bit mono PCM at `AudioCfg.sampleRateHz` from the device
/// microphone.
///
/// Chunk sizes are non-deterministic — the platform may deliver anywhere
/// from a few hundred bytes to several KB per event. Downstream stages
/// (`PcmSlicer`) re-frame to fixed `AudioCfg.frameMs` boundaries. (The native
/// Android service delivers fixed ~100 ms / 3200-byte chunks, but the slicer
/// makes no assumption about that.)
class MicSource {
  // ---- channels (Android native recorder) --------------------------------

  /// Control channel — `start`/`stop` the native foreground service. Must
  /// match the names registered in `MainActivity.kt`.
  static const MethodChannel _method =
      MethodChannel('app.didisnorelastnight/recorder');

  /// PCM stream channel — the service worker thread pushes 16-bit PCM chunks
  /// here via `PcmBus`.
  static const EventChannel _pcm =
      EventChannel('app.didisnorelastnight/recorder/pcm');

  // ---- record plugin (iOS + test host) ------------------------------------

  final AudioRecorder _recorder = AudioRecorder();

  /// Active subscription. On Android this is the `EventChannel` stream; on
  /// iOS/test it's the `record` plugin stream. Same field, same lifecycle.
  StreamSubscription<dynamic>? _sub;

  final StreamController<Uint8List> _out =
      StreamController<Uint8List>.broadcast();

  /// Broadcast stream of raw PCM chunks. Subscribers see chunks exactly as
  /// the platform delivers them; framing is downstream.
  Stream<Uint8List> get pcm16 => _out.stream;

  /// Begins streaming. Throws `StateError` if mic permission is denied —
  /// the consent flow in Phase 0 must have already granted it.
  Future<void> start() async {
    if (Platform.isAndroid) {
      await _startAndroid();
    } else {
      await _startRecord();
    }
  }

  /// Native Android path: the recorder lives in `RecorderService` (§1.4).
  Future<void> _startAndroid() async {
    // The native service opens `AudioRecord` directly, so the `record`
    // plugin's `hasPermission()` doesn't gate it — check RECORD_AUDIO via
    // `permission_handler` ourselves. The consent flow should already have
    // granted it; this guards against starting a service that would
    // immediately SecurityException in Kotlin.
    if (!await Permission.microphone.isGranted) {
      throw StateError('mic permission denied');
    }

    // Best-effort POST_NOTIFICATIONS request. The FGS runs without it, but
    // the ongoing recording notification (and thus the mic indicator) is
    // suppressed on Android 13+ if it's denied. Don't block recording on the
    // result — a missing notification is a degraded UX, not a failure.
    if (!await Permission.notification.isGranted) {
      await Permission.notification.request();
    }

    // Subscribe BEFORE invoking `start` so the EventChannel sink is
    // registered (PcmBus has a sink) by the time the worker thread begins
    // reading — no dropped leading chunks.
    _sub = _pcm.receiveBroadcastStream().listen((event) {
      // Platform delivers a `Uint8List` for byte payloads. Forward as-is;
      // wrap defensively in case the platform hands back a plain List<int>.
      if (event is Uint8List) {
        _out.add(event);
      } else if (event is List<int>) {
        _out.add(Uint8List.fromList(event));
      }
    });

    await _method.invokeMethod<void>('start');
  }

  /// iOS + test-host path: the original `record` 6.x streaming code, verbatim.
  Future<void> _startRecord() async {
    if (!await _recorder.hasPermission()) {
      throw StateError('mic permission denied');
    }
    final stream = await _recorder.startStream(
      const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: AudioCfg.sampleRateHz,
        numChannels: AudioCfg.channels,
        // unprocessed disables platform AGC + NS so calibration thresholds
        // reflect real ambient energy, not OS-massaged levels.
        // API 24+; falls back to default on older devices server-side.
        androidConfig: AndroidRecordConfig(
          audioSource: AndroidAudioSource.unprocessed,
        ),
      ),
    );
    _sub = stream.listen(_out.add);
  }

  /// Stops streaming. Safe to call multiple times.
  Future<void> stop() async {
    if (Platform.isAndroid) {
      // Tell the service to drain + release `AudioRecord`, then drop our
      // subscription. Order: stop the service first so no late chunk races
      // the cancel; then cancel the EventChannel subscription (which also
      // triggers `onCancel` → PcmBus sink cleared on the native side).
      await _method.invokeMethod<void>('stop');
      await _sub?.cancel();
      _sub = null;
    } else {
      await _sub?.cancel();
      _sub = null;
      await _recorder.stop();
    }
  }
}
