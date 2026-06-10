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

  /// Events stream channel — the service pushes small status maps here via
  /// `RecorderEventBus` (currently `interruption_began` / `interruption_ended`,
  /// each carrying an `atMs` epoch timestamp). Distinct from the PCM channel
  /// so the audio hot path stays byte-only. The Android equivalent of the
  /// iOS §10.2 interruption handling: `RecorderService` listens to it and
  /// writes `recording_gaps` rows.
  static const EventChannel _events =
      EventChannel('app.didisnorelastnight/recorder/events');

  // ---- record plugin (iOS + test host) ------------------------------------

  final AudioRecorder _recorder = AudioRecorder();

  /// Active subscription. On Android this is the `EventChannel` stream; on
  /// iOS/test it's the `record` plugin stream. Same field, same lifecycle.
  StreamSubscription<dynamic>? _sub;

  /// Active subscription to the native events `EventChannel`. Android only;
  /// null on iOS/test where there is no native event source.
  StreamSubscription<dynamic>? _eventsSub;

  final StreamController<Uint8List> _out =
      StreamController<Uint8List>.broadcast();

  /// Native recorder events (interruption began/ended). Broadcast so multiple
  /// listeners can observe without contending. Populated only on Android; on
  /// iOS/test it stays empty (no event source is wired), so `RecorderService`
  /// subscribes unconditionally and simply never fires on those platforms.
  final StreamController<Map<String, dynamic>> _eventsOut =
      StreamController<Map<String, dynamic>>.broadcast();

  /// Broadcast stream of raw PCM chunks. Subscribers see chunks exactly as
  /// the platform delivers them; framing is downstream.
  Stream<Uint8List> get pcm16 => _out.stream;

  /// Broadcast stream of native recorder status events. Each element is a map
  /// like `{'type': 'interruption_began', 'atMs': 1234567890}`. Empty on
  /// non-Android platforms (incl. the Dart-VM test host), so iOS and unit
  /// tests are unaffected — they get a stream that never emits.
  Stream<Map<String, dynamic>> get nativeEvents => _eventsOut.stream;

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

    // Subscribe to the native events channel too (interruption began/ended).
    // Same ordering rationale: register the sink before `start` so the
    // RecorderEventBus has somewhere to push the first transition. The
    // platform delivers each event as a `Map`; normalize to
    // `Map<String, dynamic>` for downstream type-safety.
    _eventsSub = _events.receiveBroadcastStream().listen((event) {
      if (event is Map) {
        _eventsOut.add(event.map((k, v) => MapEntry(k.toString(), v)));
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
      // Cancel the events subscription too — triggers `onCancel` on the
      // native side, clearing the RecorderEventBus sink.
      await _eventsSub?.cancel();
      _eventsSub = null;
    } else {
      await _sub?.cancel();
      _sub = null;
      await _recorder.stop();
    }
  }
}
