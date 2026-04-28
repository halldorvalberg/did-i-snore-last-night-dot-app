# Implementation Guide

A staged build plan for v1, ordered by risk. The riskiest assumption — that we can keep a microphone alive for 8 hours with the screen locked on iOS and Android — is verified before any detection logic is written. Everything downstream depends on that, so we don't get to defer it.

This guide assumes the design in `README.md` is locked. Revisit it before coding if you want to change event-merge semantics, retention, or the label set.

## Definition of done for v1

You install on Pixel and partner's iPhone. Tap "Start." Sleep. In the morning, you see a list of events with timestamps and labels, can play any clip, can star or delete, with no audio leaving the device. 14-day-old unstarred events have auto-cleaned. The recorder survived an overnight on both phones, including a phone-call interruption, with gaps marked clearly in the timeline.

That's v1. Multi-night stats, custom labels, and auto-stop are v2+.

## Prerequisites

- **Flutter SDK** stable channel ≥ 3.22.
- **Xcode** + a paid Apple Developer account. TestFlight requires it; Xcode personal-team sideload works for self but expires every 7 days.
- **Android Studio** + Android SDK Platform 34+.
- **Two physical devices.** Emulators have fake mics and unreliable background-audio behavior. Plan to test on a real Android phone and real iPhone from day one.
- **A second Android phone for OEM testing**, ideally Samsung or Xiaomi, since stock Pixels behave very differently from the rest of the ecosystem on background services. Borrow if needed.
- **Headphones** — playing back recorded snores at full speaker volume gets old quickly.

## Phase 0 — Bootstrap

### 0.1 Project + folder layout

```bash
flutter create --org app.didisnorelastnight --platforms=android,ios did_i_snore
cd did_i_snore
```

`--org` becomes the iOS bundle ID and Android application ID — pick what you'll keep.

```
lib/
  main.dart
  app.dart
  config/constants.dart
  consent/                       # first-launch consent flow
  recorder/
    recorder_service.dart        # owns the mic, runs in background isolate
    mic_source.dart              # wraps `record`
    pcm_slicer.dart              # chunk → fixed-size frames
    ring_buffer.dart
    energy.dart                  # RMS + dBFS helpers
    spectral.dart                # snore-band energy + flatness
    gate.dart                    # hysteresis + hold + tail
    calibrator.dart              # median + MAD noise-floor estimator
    event_window.dart
    opus_encoder.dart            # ffmpeg or libopus FFI
  classifier/
    yamnet.dart
    label_map.dart
  data/
    db.dart
    events_table.dart
    event_repo.dart
  janitor/
    janitor.dart
  diag/
    debug_log.dart               # on-device circular log file
  ui/
    home/home_screen.dart
    timeline/timeline_screen.dart
    timeline/event_tile.dart
    timeline/gap_tile.dart       # for recording gaps
    player/player_screen.dart
    setup/calibration_screen.dart
    setup/oem_onboarding.dart
test/
assets/models/
  yamnet.tflite                  # quantized int8
  yamnet_class_map.csv
```

### 0.2 Dependencies

`pubspec.yaml` (pin actual versions when running `flutter pub add`):

```yaml
dependencies:
  flutter: { sdk: flutter }
  record: ^5.1.0                       # mic capture
  tflite_flutter: ^0.10.4              # YAMNet inference
  drift: ^2.18.0
  drift_flutter: ^0.2.0
  sqlite3_flutter_libs: ^0.5.20
  path_provider: ^2.1.3
  path: ^1.9.0
  flutter_riverpod: ^2.5.1
  flutter_local_notifications: ^17.0.0
  permission_handler: ^11.3.0
  flutter_background_service: ^5.0.0   # foreground service helper (Android)
  workmanager: ^0.5.2                  # periodic janitor (Android)
  fftea: ^1.5.0                        # FFT for spectral pre-filter
  device_info_plus: ^10.0.0            # OEM detection
  shared_preferences: ^2.2.0           # calibration persistence

dev_dependencies:
  flutter_test: { sdk: flutter }
  drift_dev: ^2.18.0
  build_runner: ^2.4.9
```

### 0.3 Constants

`lib/config/constants.dart`:

```dart
class AudioCfg {
  static const int sampleRateHz = 16000;
  static const int channels = 1;
  static const int frameMs = 20;
  static const int preRollMs = 2000;
  static const int tailMs = 1000;
  static const int gateHoldMs = 300;
  static const int eventMergeGapMs = 4000;          // applied at data layer
  static const int classifierFrameMs = 960;         // YAMNet
  static const int minEventDurationMs = 500;        // shorter → drop
  static const int calibrationSeconds = 30;
}

class GateCfg {
  static const double tHighMargin = 9.0;            // dB above noise floor
  static const double tLowMargin  = 5.0;            // (close threshold)
  static const double madK = 5.0;                   // tHigh = median + k*MAD
}

class SpectralCfg {
  static const double minSnoreBandFraction = 0.18;  // 50–500 Hz / total
  static const double maxFlatness = 0.65;           // > this = pure noise
  // Spectral filter only applies when ambient was quiet at calibration.
  // Noisy-ambient events skip the filter and rely on YAMNet alone.
  static const double maxAmbientMadForFilter = 4.0; // dB
}

class LabelCfg {
  static const double minDisplayConfidence = 0.4;
  // Post-YAMNet reject: drop event if the best curated class is weak AND
  // YAMNet thinks it's mostly Other.
  static const double minTopCuratedForKeep = 0.3;
  static const double maxOtherForKeep = 0.5;
  // Precision floor on max-over-frames: a class is only eligible to be
  // the top label if it appears confidently in enough of the event.
  static const double frameFloorConfidence = 0.3;
  static const double minFrameFractionAboveFloor = 0.25;
}

class RetentionCfg {
  static const int defaultDays = 14;
  static const int minFreeDiskMb = 200;             // emergency-prune below this
}
```

When tuning, change these. Never sprinkle literals.

### 0.4 First-launch consent flow

Before the OS permission prompt, show a screen that explains:

1. What the app records (sounds while you sleep).
2. Where the data goes (this device, nowhere else).
3. What's not collected (no account, no analytics, no cloud).
4. What the user will see during recording (orange dot on iOS, persistent notification on Android).
5. A "Continue" button that *then* triggers the OS permission prompt.

The OS-level permission dialog gives the user a binary choice without context. If they say no there, you can't re-prompt without sending them to settings. Earning informed consent before the dialog matters, especially for the partner's device.

## Phase 1 — Background-survival smoke test

This phase is the gate to all other phases. Don't move on until it passes on both platforms. The whole product depends on the answer.

### 1.1 Goal

Prove the app can hold the mic open for 8 hours on a locked, plugged-in phone, surviving:

- Screen lock and OS Doze (Android).
- App moving to background (iOS).
- An incoming phone call (interruption + resume).
- A Bluetooth route change (AirPods connect/disconnect).
- A POST_NOTIFICATIONS interaction (someone messages you).

### 1.2 What to build

A throwaway harness, not a feature. Single screen, "Start" button:

- On start: kick off the foreground service (Android) / activate `AVAudioSession` (iOS) and begin writing 30-second PCM segments to disk, named `<docs>/smoke/YYYY-MM-DD/HH-MM-SS.pcm`.
- Every 60 seconds: append to `<docs>/smoke/heartbeat.log` a line with `epoch_ms, total_bytes_written, current_file`. This is your forensic record.
- On Android, the recorder must be a **native Kotlin foreground `Service` that owns `AudioRecord` directly** — see 1.4 for the architecture lock-in and the bugs that forced this decision. `flutter_background_service` + the `record` plugin are not viable on Android 14+.
- On iOS, configure `AVAudioSession`:

```swift
let session = AVAudioSession.sharedInstance()
try session.setCategory(
    .playAndRecord,
    mode: .measurement,                            // disables AGC
    options: [.mixWithOthers, .allowBluetooth]
)
try session.setActive(true)
```

`.measurement` mode disables iOS's automatic gain control, which would silently mess with thresholds. `.mixWithOthers` keeps the user's white-noise app running at full volume — no `.duckOthers`, since a passive recorder shouldn't announce itself by lowering other audio. `.allowBluetooth` (HFP) lets AirPods serve as a mic if the user wants.

**AirPods edge case to verify in 1.3:** AirPods Pro can be in A2DP-only mode (output, no mic) or HFP mode (input + output). With `.allowBluetooth` set, iOS may route input from the built-in mic while routing output to AirPods, or fall back to AirPods HFP and silently degrade to 8 kHz mono. The partner-with-AirPods-Pro-falling-asleep case is real — exercise it before moving past Phase 1.

Subscribe to `interruptionNotification` and `routeChangeNotification` and re-activate the session on resume.

When an interruption ends, write a `GAP` line to the heartbeat log with the duration of the interruption. This is how the production app will mark missing audio in the timeline; we want to see whether interruptions are happening overnight and how long they last.

**Critical: heartbeat alone proves nothing about the mic.** The heartbeat is written by the same Dart isolate that consumes mic chunks; it'll keep firing even if `record` has silently stopped delivering bytes (suspended audio session, HAL stall). Each heartbeat must include `bytes_since_last_heartbeat`, and the smoke-test verifier asserts:

```
expected_bytes = 60 s × 16000 Hz × 2 bytes/sample × 1 channel = 1,920,000
actual_bytes ∈ [expected × 0.95, expected × 1.05]
```

Anything outside that band means the mic died but the loop didn't — which is exactly the silent failure we're trying to catch.

### 1.3 Tests

Pass criterion across all rows: **zero unexplained gaps** (every gap traces to an explicit interruption you logged). "≤ N gaps" tolerates platform misbehavior; we want to know about every one.

| Test | Pass criterion |
| --- | --- |
| 8-hour overnight, locked, plugged in, Pixel | 480 heartbeats, every `bytes_since_last_heartbeat` in band, no unexplained gaps |
| Same, on iPhone | same |
| Same, **unplugged** on Pixel from 80% battery | same, plus phone is still alive in the morning |
| Phone call mid-recording (15 s call) | gap line covering call duration, recording resumes within 2 s of `.ended` |
| AirPods (any model) connect → recording resumes from new route | route change logged, bytes-per-heartbeat back in band after route settles |
| AirPods Pro asleep mode (A2DP-only) → start recording | input device explicitly logged; if iOS silently downsamples input to 8 kHz, we know now |
| Notification arrives mid-recording | no death, no gap |
| Battery saver / Doze (Android) — `adb shell dumpsys deviceidle force-idle` | foreground service survives, bytes still flowing |
| OEM kill simulation — `adb shell am stopservice <pkg>/.RecorderService` | next app launch detects gap (`now - last_heartbeat > threshold`) and logs it |
| Samsung One UI overnight (real device) | same as Pixel overnight |

If any test fails, you have a foundational platform problem. Do not start the gate, do not start YAMNet, do not pass go. Diagnose and fix.

This phase produces no feature value. Its output is a heartbeat log and confidence to keep building. Worth every hour spent.

### 1.4 Architecture lock-in: native Kotlin recorder service (Android)

The throwaway harness lived up to its job — it caught two fatal bugs in the `flutter_background_service` + `record` stack on Android 14+ before they had a chance to bite the production app. They are documented here so Phase 2 doesn't relitigate them and so a future contributor reading the recorder code understands why it's native.

**Bug A — `ForegroundServiceDidNotStartInTimeException`.** When `flutter_background_service` v5 starts its `BackgroundService` from Dart, the Dart isolate's flutter engine boots asynchronously. On a cold start, the native side does not call `Service.startForeground()` until well after `Context.startForegroundService()`. Android's FGS-promotion timer (5–30 seconds depending on the OEM/version) fires while the engine is still booting, and the OS throws `ForegroundServiceDidNotStartInTimeException`, which **kills the entire process with SIGKILL** — taking the recorder, the heartbeat log writer, and the FGS notification with it. Observed signature in logcat:

```
E AndroidRuntime: android.app.RemoteServiceException$ForegroundServiceDidNotStartInTimeException:
    Context.startForegroundService() did not then call Service.startForeground():
    ServiceRecord{... id.flutter.flutter_background_service.BackgroundService ...}
I Zygote: Process <pid> exited due to signal 9 (Killed)
```

**Bug B — UI ↔ service-isolate listener race.** The harness UI calls `svc.startService()` (which boots the service isolate) and then immediately `svc.invoke('start')` to push the start command across. The plugin does not buffer events between `startService()` and the moment the service isolate's `service.on('start').listen(...)` handler is registered. On a cold start, those few hundred milliseconds of isolate init drop the start message on the floor, and the recorder never starts. The FGS notification still appears (the OS shell is up), but no audio is captured and no heartbeat fires.

A symptom of bug A often showed up alongside bug B: the FGS shell is up for ~30 s with no audio, then the OS kills it with the timer exception, and the user sees a "still going" notification because the system respawns a zombie service shell that has no FGS privilege (`startForegroundCount=0`).

**Decision: own `AudioRecord` from Kotlin, never from Dart.**

The reference implementation lives at `phase-1-harness/android/app/src/main/kotlin/.../RecorderService.kt`. Properties Phase 2 must preserve:

- `Service.onStartCommand()` calls `startForeground(notifId, notif, FOREGROUND_SERVICE_TYPE_MICROPHONE)` **synchronously, before any other work**. No Dart roundtrip on this path. This is what defeats bug A.
- `AudioRecord` is constructed and read from a Kotlin worker thread in the same process. There is no second isolate, so there is no listener race — bug B is structurally absent.
- The PCM source is `MediaRecorder.AudioSource.UNPROCESSED` on API 24+. The `minSdk = 24` decision (see 2.1) is what lets us assume this source is available; below 24 the platform falls back to `VOICE_RECOGNITION` and we don't ship there.
- The notification channel uses `IMPORTANCE_LOW` and the notification carries `ONGOING|NO_CLEAR|FOREGROUND_SERVICE` flags. Foreground service type **must** be `microphone`, declared both in `<service android:foregroundServiceType="microphone">` in the manifest and in the `startForeground()` flags argument.
- Segment files and the heartbeat log are written under `dataDir/app_flutter/smoke/` so the path matches `path_provider.getApplicationDocumentsDirectory()` from the Dart side. (Don't use `filesDir` — that's `dataDir/files`, a sibling, and the verifier won't find the data.)
- Stop semantics are "stop the recorder, then `stopForeground()` and `stopSelf()`". The Dart UI must never call `stopSelf()` on the service while the recorder is still running.

**What the harness validated** (Nothing Phone 3a, Android 14, OneOS, 2026-04-28):

| Check | Result |
| --- | --- |
| 20-minute continuous recording, app backgrounded | 20 heartbeats, every one in the [1,824,000, 2,016,000] byte band, all within 100.0–100.2 % of expected |
| FGS survival across app switches and screen lock | `isForeground=true types=0x80` for full 20m53s, `startForegroundCount=1`, no respawn |
| `AudioSource.UNPROCESSED` actually delivered | logcat shows `inputSource 9, sampleRate 16000, format 0x1` and steady `allowCapture=1` |
| `App op 27 missing, silencing record` | did not occur once on the native build |
| `ForegroundServiceDidNotStartInTimeException` | did not occur once on the native build |

The 8-hour overnight test in 1.3 is still the formal pass criterion. The 20-minute run is the smoke that says the architecture is right; the overnight is the soak that says the implementation has no slow leaks. Run it before declaring Phase 1 fully closed.

**iOS.** iOS does not have the FGS-promotion timer or the `App op 27 missing` failure mode; the equivalent risk is `AVAudioSession` losing activation on backgrounding, which the current Swift configuration in 1.2 handles. The iOS harness can stay Dart-driven. We did not exercise the iOS path in this Phase 1 pass — it is still on the to-do list before declaring v1 cross-platform.

## Phase 2 — Mic capture, ring buffer, frame slicer

With the platform foundation proven, now we wire the actual data path: PCM into a ring buffer + an explicit frame slicer that yields 20 ms frames regardless of incoming chunk size.

### 2.1 Mic source

**Android: native Kotlin only — see 1.4.** The Dart `MicSource` below is the iOS code path; on Android, the Kotlin `RecorderService` publishes PCM chunks to Dart via an `EventChannel` and the rest of the pipeline (slicer, ring buffer, gate) consumes that stream the same way it would consume the Dart `record` stream. The Dart-facing API is identical (`Stream<Uint8List> get pcm16`); only the implementation behind it differs by platform. Do not call `AudioRecorder()` from Dart on Android — that is the configuration that failed Phase 1.

`lib/recorder/mic_source.dart`:

```dart
class MicSource {
  final _recorder = AudioRecorder();
  StreamSubscription<Uint8List>? _sub;
  final _out = StreamController<Uint8List>.broadcast();

  Stream<Uint8List> get pcm16 => _out.stream;

  Future<void> start() async {
    if (!await _recorder.hasPermission()) {
      throw StateError('mic permission denied');
    }
    final stream = await _recorder.startStream(const RecordConfig(
      encoder: AudioEncoder.pcm16bits,
      sampleRate: AudioCfg.sampleRateHz,
      numChannels: AudioCfg.channels,
      androidConfig: AndroidRecordConfig(
        audioSource: AndroidAudioSource.unprocessed,
      ),
    ));
    _sub = stream.listen(_out.add);
  }

  Future<void> stop() async {
    await _sub?.cancel();
    await _recorder.stop();
  }
}
```

`record` chunk sizes are non-deterministic — anywhere from a few hundred bytes to several KB depending on platform and buffering.

**Why `AndroidAudioSource.unprocessed`.** Android's default mic sources (`MIC`, `VOICE_COMMUNICATION`) apply platform-level AGC, noise suppression, and echo cancellation by default. AGC silently compresses the mic's dynamic range; NS removes the very low-frequency content where snoring lives. Both make calibration meaningless because the noise floor we measure no longer reflects the actual mic energy — the OS is editing the signal between mic and us. `unprocessed` is the explicit "give me the raw input stream" source. iOS is handled separately via `AVAudioSession.setMode(.measurement)` (Phase 1.2 / Phase 10.2) which has the same effect.

**Fallback policy.** `unprocessed` requires API 24 (Android 7.0). On older devices the platform silently falls back to `VOICE_RECOGNITION` and calibration would drift. We refuse to ship there: `android/app/build.gradle.kts` pins `minSdk = 24`. On heavily-customised OEM ROMs (a few Samsung / Xiaomi / Huawei builds) `unprocessed` is reportedly ignored at the HAL level — the OS accepts the source but re-engages AGC anyway. We have no way to detect this from app code; the symptom is calibration that "should be quiet" but isn't. The OEM onboarding flow (Phase 10) surfaces a one-line "if recordings sound auto-gained, your device may not honour the unprocessed source — file an issue" note.

### 2.2 PCM frame slicer

The gate operates on fixed 20 ms frames, but `record` delivers arbitrary-sized chunks. The slicer holds a tail buffer across chunk boundaries so frames are emitted at exactly `frameMs` granularity.

`lib/recorder/pcm_slicer.dart`:

```dart
class PcmSlicer {
  final int frameBytes;    // = sampleRate * (frameMs / 1000) * 2 (int16 mono)
  final Uint8List _tail;   // typed buffer, never grows past frameBytes
  int _tailLen = 0;

  PcmSlicer({required this.frameBytes}) : _tail = Uint8List(frameBytes);

  Iterable<Uint8List> sliceChunk(Uint8List chunk) sync* {
    var i = 0;
    if (_tailLen > 0) {
      final need = frameBytes - _tailLen;
      if (chunk.length >= need) {
        _tail.setRange(_tailLen, frameBytes, chunk);
        yield Uint8List.fromList(_tail.sublist(0, frameBytes));
        _tailLen = 0;
        i = need;
      } else {
        _tail.setRange(_tailLen, _tailLen + chunk.length, chunk);
        _tailLen += chunk.length;
        return;
      }
    }
    while (chunk.length - i >= frameBytes) {
      yield Uint8List.sublistView(chunk, i, i + frameBytes);
      i += frameBytes;
    }
    final remainder = chunk.length - i;
    if (remainder > 0) {
      _tail.setRange(0, remainder, chunk, i);
      _tailLen = remainder;
    }
  }
}
```

`Uint8List` instead of `List<int>` avoids per-byte boxing; the tail is at most one frame's worth of data and is reused, not reallocated.

**Test it explicitly.** This is exactly the kind of code that hides off-by-one bugs:

```dart
test('slicer handles partial-frame remainder across chunks', () {
  final s = PcmSlicer(frameBytes: 640);  // 20ms @ 16kHz × 2 bytes
  final out1 = s.sliceChunk(Uint8List(73)).toList();
  expect(out1, isEmpty);
  final out2 = s.sliceChunk(Uint8List(12000)).toList();
  expect(out2.length, 18);   // (73 + 12000) / 640 = 18 frames + 553 byte tail
  for (final f in out2) expect(f.length, 640);
});
```

### 2.3 Ring buffer

`lib/recorder/ring_buffer.dart`:

```dart
class RingBuffer {
  final Uint8List _buf;
  int _writeIdx = 0;
  int _filled = 0;

  RingBuffer(int byteCapacity) : _buf = Uint8List(byteCapacity);

  void write(Uint8List chunk) {
    var src = 0;
    var remaining = chunk.length;
    while (remaining > 0) {
      final canFit = _buf.length - _writeIdx;
      final take = remaining < canFit ? remaining : canFit;
      _buf.setRange(_writeIdx, _writeIdx + take, chunk, src);
      _writeIdx = (_writeIdx + take) % _buf.length;
      if (_filled < _buf.length) {
        _filled = (_filled + take).clamp(0, _buf.length);
      }
      src += take;
      remaining -= take;
    }
  }

  Uint8List snapshot() {
    final out = Uint8List(_filled);
    if (_filled < _buf.length) {
      out.setRange(0, _filled, _buf);
    } else {
      final headLen = _buf.length - _writeIdx;
      out.setRange(0, headLen, _buf, _writeIdx);
      out.setRange(headLen, _buf.length, _buf, 0);
    }
    return out;
  }
}
```

Capacity for 2 s of 16-bit mono 16 kHz: `16000 × 2 × 2 = 64,000` bytes.

`setRange` over a hand-rolled byte loop matters here — this code consumes every chunk all night on battery. Test the wraparound case (write a buffer larger than capacity, snapshot, verify chronological order).

## Phase 3 — Calibration

Threshold has to come from the room, not from a constant. The gate is built on top of this — calibrate first.

### 3.1 Calibration UI (visualization, not a timer)

A passive 30-second timer is hostile UX. Replace with:

- A live RMS-dBFS bar updating ~10 Hz.
- A 30-second sliding history strip showing recent levels.
- Status text: `Listening…` → `Looking quiet — keep going` → `Quiet enough — you can save`.
- A "Save calibration" button enabled only after **≥10 contiguous seconds below an estimated quiet floor**.
- A "Cancel and try again" link, always present.

This makes "is the room quiet enough?" something the user can see, not a black box.

### 3.2 Robust noise floor estimation

p95-of-frame-RMS is too sensitive to brief loud frames. Use median + MAD instead:

```dart
class NoiseFloor {
  final double medianDbfs;
  final double madDbfs;
  double get tHighDbfs => medianDbfs + GateCfg.madK * madDbfs;
  double get tLowDbfs  => medianDbfs + (GateCfg.madK - 2.0) * madDbfs;
  NoiseFloor(this.medianDbfs, this.madDbfs);
}

NoiseFloor estimateFloor(List<double> frameDbfs) {
  final sorted = [...frameDbfs]..sort();
  final median = sorted[sorted.length ~/ 2];
  final deviations = sorted.map((d) => (d - median).abs()).toList()..sort();
  final mad = deviations[deviations.length ~/ 2];
  return NoiseFloor(median, mad);
}
```

`madK = 5.0` is the starting margin — tune empirically. The closing threshold is two MAD-units below the opening threshold (the hysteresis gap).

### 3.3 No silent runtime recalibration

The previous draft had "refine the threshold during the first 60 seconds of every recording." That silently fails if the user is already snoring during those 60 seconds — the threshold gets pushed up and real events get missed for the rest of the night.

Replacement policy:

- Calibration is an explicit step (initial, and "Recalibrate" in settings).
- During recording, the calibrator may *reduce* `tHigh` (room got quieter than expected) but never raise it. This handles "the AC turned off mid-night" without the failure mode of "the user started snoring immediately."
- Reduction only fires when the variance over a 5-minute window is below a threshold (i.e., the window was actually quiet).

Persist the calibration per-device in `shared_preferences` keyed by `deviceId`.

## Phase 4 — Gate, event window, spectral pre-filter

### 4.1 Gate state machine

Two states: `closed` and `open`. Hysteresis + sustained-above hold:

```dart
class Gate {
  final RingBuffer ring;
  double tHighDbfs;
  double tLowDbfs;
  bool _open = false;
  int _aboveSinceMs = -1;
  int _belowSinceMs = -1;
  int _eventStartMs = 0;

  Gate({required this.ring, required this.tHighDbfs, required this.tLowDbfs});

  GateEvent? feed(double dbfs, int nowMs) {
    if (!_open) {
      if (dbfs >= tHighDbfs) {
        if (_aboveSinceMs == -1) _aboveSinceMs = nowMs;
        if (nowMs - _aboveSinceMs >= AudioCfg.gateHoldMs) {
          _open = true;
          _eventStartMs = _aboveSinceMs;
          return GateOpened(_eventStartMs, ring.snapshot());
        }
      } else {
        _aboveSinceMs = -1;
      }
    } else {
      if (dbfs < tLowDbfs) {
        if (_belowSinceMs == -1) _belowSinceMs = nowMs;
        if (nowMs - _belowSinceMs >= AudioCfg.tailMs) {
          _open = false;
          _aboveSinceMs = _belowSinceMs = -1;
          return GateClosed(_eventStartMs, nowMs);
        }
      } else {
        _belowSinceMs = -1;
      }
    }
    return null;
  }
}
```

### 4.2 Spectral pre-filter (cheap reject before YAMNet)

A pure RMS gate fires on HVAC, fridges, traffic, charging-coil whine, sheet rustle. Most of these have either no harmonic structure or no energy in the 50–500 Hz snore band. Reject them before paying YAMNet's cost.

`lib/recorder/spectral.dart`:

```dart
class SpectralProbe {
  final FFT _fft;
  SpectralProbe(int n) : _fft = FFT(n);

  ({double snoreBandFraction, double flatness}) analyze(Float32List window) {
    final mags = _fft.realFft(window).discardConjugates().magnitudes();
    final df = AudioCfg.sampleRateHz / window.length;
    var inBand = 0.0, total = 0.0;
    for (var i = 0; i < mags.length; i++) {
      final f = i * df;
      total += mags[i];
      if (f >= 50 && f <= 500) inBand += mags[i];
    }
    // Geometric mean / arithmetic mean = spectral flatness
    var logSum = 0.0;
    for (final m in mags) logSum += math.log(m + 1e-10);
    final flatness = math.exp(logSum / mags.length) / (total / mags.length);
    return (snoreBandFraction: inBand / (total + 1e-10), flatness: flatness);
  }
}
```

Apply to the first 960 ms of the event (post pre-roll). Reject if **either**:

- `snoreBandFraction < SpectralCfg.minSnoreBandFraction` (mostly above 500 Hz — likely fan, alarm, electronic noise), **or**
- `flatness > SpectralCfg.maxFlatness` (white-noise-like — definitely not voice or snoring).

Rejected events get logged to the debug log for tuning but never written to disk or DB.

**Known limitation: this filter is a fan-rejector, not a snore-detector.** A quiet snore in a fan-running room has its band fraction dominated by the fan's broadband energy, not the snore. Computing the band fraction on the *event minus the calibrated noise spectrum* would fix this but is materially more code (per-bin spectral subtraction, careful handling of the noise estimate). For v1, gate the filter on calibration variance: if `noiseFloor.madDbfs > SpectralCfg.maxAmbientMadForFilter`, **skip the spectral filter entirely** for this session and rely on YAMNet alone. Quiet bedrooms get the cheap reject; noisy bedrooms pay YAMNet's cost. Worth fixing properly in v2 if real-bedroom data shows it matters.

### 4.3 Event window — and no-zero-padding merge

Each event window is its own contiguous PCM blob: `pre-roll + live + tail`. **Do not merge events at the audio layer** — that produces audible "broken recorder" silence. Merging is a data-layer concern only.

Two close events become two rows that the timeline UI groups visually. The classifier sees each separately. The user perceives them as one snore burst because they're rendered together.

```dart
class EventWindow {
  final int startMs;
  final BytesBuilder _bytes = BytesBuilder(copy: false);

  EventWindow(this.startMs, Uint8List preRoll) { _bytes.add(preRoll); }
  void appendChunk(Uint8List chunk) => _bytes.add(chunk);
  Uint8List takePcm() => _bytes.takeBytes();
}
```

Filter: drop events shorter than `AudioCfg.minEventDurationMs` (500 ms) before classifying. One-frame creaks add noise to the timeline.

## Phase 5 — YAMNet classifier

### 5.1 Use the int8-quantized model

Default YAMNet from TF Hub is float32 and runs ~50 ms per inference on a midrange phone. The int8-quantized variant runs at ~15–20 ms and uses a fraction of the memory. The accuracy hit on AudioSet classes we care about is small. **Use the quantized model from day one** — thermal headroom matters when the phone is pillow-trapped.

Place `yamnet.tflite` (quantized) and `yamnet_class_map.csv` in `assets/models/`.

### 5.2 Inference + aggregation

```dart
class Yamnet {
  late final Interpreter _interp;
  late final List<String> _classNames;

  Future<void> load() async {
    _interp = await Interpreter.fromAsset('assets/models/yamnet.tflite');
    final csv = await rootBundle.loadString('assets/models/yamnet_class_map.csv');
    _classNames = csv.split('\n').skip(1)
      .where((l) => l.trim().isNotEmpty)
      .map((l) => l.split(',')[2].replaceAll('"', ''))
      .toList();
  }

  /// Returns curated label → confidence. Empty map if event is too short.
  Map<String, double> classify(Int16List pcm) {
    if (pcm.length < 15600) {
      pcm = Int16List(15600)..setRange(0, pcm.length, pcm);
    }
    final waveform = Float32List(pcm.length);
    for (var i = 0; i < pcm.length; i++) waveform[i] = pcm[i] / 32768.0;

    final scoresOut = <int, Object>{};
    _interp.runForMultipleInputs([waveform], scoresOut);
    final scores = scoresOut[0] as List<List<double>>;  // [frames, 521]

    if (scores.isEmpty) return const {};

    // Max-over-frames per class — preserves brief but distinctive sounds
    // (a 2-second snore inside a 30-second mostly-speech event).
    final maxPerClass = List.filled(521, 0.0);
    // Frames-above-floor count per class — the precision floor.
    // A class only gets to be the top label if it shows up in enough frames,
    // not just one outlier with a high score.
    final framesAboveFloor = List.filled(521, 0);
    for (final frame in scores) {
      for (var c = 0; c < 521; c++) {
        if (frame[c] > maxPerClass[c]) maxPerClass[c] = frame[c];
        if (frame[c] >= LabelCfg.frameFloorConfidence) framesAboveFloor[c]++;
      }
    }
    final minFrames = (scores.length * LabelCfg.minFrameFractionAboveFloor).ceil();
    // Zero out the max for classes that don't meet the precision floor.
    for (var c = 0; c < 521; c++) {
      if (framesAboveFloor[c] < minFrames) maxPerClass[c] = 0.0;
    }
    return LabelMap.aggregate(maxPerClass, _classNames);
  }
}
```

**Aggregation = max-over-frames with a precision floor.** Plain mean averages a 2 s snore inside a 30 s speech event into "Speech" — lose the snore. Plain max promotes a single outlier frame to top label, even if 99% of the event is something else. The compromise: take the max per class, but only count classes that exceed `frameFloorConfidence` (0.3) in at least `minFrameFractionAboveFloor` (25%) of the event's frames. Brief-but-real signals survive (a 3 s snore in a 12 s event = 25%); single-frame outliers don't. Tune both numbers on the fixture corpus.

### 5.3 Post-classification reject path

```dart
Map<String, double> labels = yamnet.classify(eventPcm);
final maxCurated = labels.entries
    .where((e) => e.key != 'Other')
    .map((e) => e.value)
    .fold<double>(0.0, math.max);
final otherScore = labels['Other'] ?? 0.0;

if (maxCurated < LabelCfg.minTopCuratedForKeep
    && otherScore > LabelCfg.maxOtherForKeep) {
  debugLog.event('rejected_low_confidence', {
    'max_curated': maxCurated, 'other': otherScore,
  });
  return;  // do not write file, do not insert row
}
```

The earlier draft used `maxCurated < 0.15` alone, which kept basically everything the gate fired on (YAMNet routinely emits 0.2–0.3 on the wrong class for ambiguous audio). The new policy keeps an event if **either** some curated class has a real foothold (`≥ 0.3`) **or** YAMNet isn't confidently saying it's nothing (`Other ≤ 0.5`). Drops only clear non-events. Tune both thresholds on the fixture corpus.

### 5.4 Label map

Explicit mapping from YAMNet AudioSet class names to the curated set; everything else collapses to `Other`:

```dart
class LabelMap {
  static const Map<String, String> yamnetToCurated = {
    'Snoring': 'Snoring',
    'Snort': 'Snoring',
    'Speech': 'Speech',
    'Conversation': 'Speech',
    'Whispering': 'Whisper',
    'Cough': 'Cough',
    'Sneeze': 'Sneeze',
    'Throat clearing': 'Throat clearing',
    'Burping, eructation': 'Belch',
    'Fart': 'Fart',
    'Hiccup': 'Hiccup',
    'Cat': 'Cat', 'Meow': 'Cat', 'Purr': 'Cat',
    'Dog': 'Dog', 'Bark': 'Dog', 'Whimper (dog)': 'Dog',
  };

  static Map<String, double> aggregate(
    List<double> scores, List<String> classNames,
  ) {
    final out = <String, double>{};
    for (var i = 0; i < classNames.length; i++) {
      final curated = yamnetToCurated[classNames[i]] ?? 'Other';
      // Take max within the curated bucket (don't sum — that double-counts Snoring + Snort).
      if ((out[curated] ?? 0) < scores[i]) out[curated] = scores[i];
    }
    return out;
  }
}
```

### 5.5 YAMNet evaluation plan (don't block v1, but plan it)

YAMNet is trained on AudioSet, which has known weaknesses on bedroom audio — especially around snoring vs. heavy breathing vs. apnea gasps. Plan an honest evaluation, after v1 ships:

1. Record 3 nights with v1 enabled.
2. Manually relabel every event using the in-app dropdown.
3. Compute precision/recall against the YAMNet predictions.
4. If precision < 70% on `Snoring`, plan to fine-tune. Common path: extract YAMNet embeddings (the penultimate-layer 1024-d vector) and train a small head on your own data. ~few hundred labeled events is usually enough.

This is v2 work, not a v1 blocker. But it's a known liability — write the evaluation harness now (just an export-events-to-CSV button) so you can do the analysis in one sitting after a few nights.

## Phase 6 — Persistence with a state machine

The DB row and the audio file have to be written separately. If we don't define a state, we get orphans (file with no row) and dead rows (row pointing at nothing). Use a `pending` → `ready` machine.

### 6.1 Schema

`lib/data/events_table.dart`:

```dart
class Events extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get startedAt => integer()();
  IntColumn get endedAt => integer()();
  IntColumn get durationMs => integer()();
  IntColumn get createdAt => integer()();                 // audit
  IntColumn get schemaVersion => integer().withDefault(const Constant(1))();
  TextColumn get state => text().withDefault(const Constant('pending'))();  // 'pending' | 'ready'
  TextColumn get topLabel => text().nullable()();
  TextColumn get labelsJson => text().nullable()();
  TextColumn get audioPath => text()();                    // RELATIVE to docs dir
  TextColumn get peaksPath => text().nullable()();         // RELATIVE
  BoolColumn get starred => boolean().withDefault(const Constant(false))();
  TextColumn get userLabel => text().nullable()();
  IntColumn get deletedAt => integer().nullable()();
}
```

Indices:

```sql
CREATE INDEX events_started_at_idx ON events(started_at);
CREATE INDEX events_state_idx      ON events(state);
CREATE INDEX events_pruning_idx    ON events(starred, started_at);
CREATE INDEX events_deleted_at_idx ON events(deleted_at);
```

The `(starred, started_at)` composite serves the auto-prune query.

**Migration template.** v1 has no upgrades, but write the v1→v2 hook now while the schema is fresh:

```dart
@override
MigrationStrategy get migration => MigrationStrategy(
  onCreate: (m) async {
    await m.createAll();
    // ...indices above
  },
  onUpgrade: (m, from, to) async {
    // Example for the next change:
    // if (from < 2) {
    //   await m.addColumn(events, events.someNewColumn);
    // }
  },
);
```

When v2 changes the schema, you have a marker; without it, you'll spend an hour re-reading the Drift migration docs.

### 6.2 State machine

The naive "insert pending → encode → update ready" has a race: if the encode worker crashes between writing the file and the DB UPDATE, you have a `pending` row pointing at a real file. The pending sweep deletes the row but doesn't know about the file → leaked file until the orphan sweep runs.

Fix: encode to a `.tmp` path, rename to the final path, *then* update the row. The pending sweep is also made idempotent by deleting the audio file at `audioPath` (and `audioPath + '.tmp'`) if either exists.

```
gate closes
   │
   ▼
INSERT row { state='pending', audioPath=<final path>, ... }
   │
   ▼
encode opus → write to <final path>.tmp
   │
   ▼
File.rename(<final path>.tmp → <final path>)
   │
   ▼
UPDATE row SET state='ready', topLabel, labelsJson, peaksPath = ...
```

Recovery on app boot, run in this order:

1. **Pending sweep.** Rows with `state='pending'` AND `createdAt < now - 60s`: delete row. Also delete the file at `audioPath` if it exists (covers the rename-succeeded-but-UPDATE-died case) and `audioPath + '.tmp'` if it exists.
2. **Orphan sweep.** Walk `events/YYYY-MM-DD/` and delete any file whose path doesn't match a current row. Catches both `.opus` files and stale `.tmp` files.
3. **Missing-file sweep.** `state='ready'` but the file is gone → mark `deletedAt = now`.

Order matters: pending sweep first deletes rows + their files atomically; orphan sweep then catches anything else. Run them every janitor cycle and at app boot.

### 6.3 Path handling

`audioPath` is **relative to the application documents directory**. iOS sandbox UUIDs change after TestFlight reinstalls, so absolute paths break. Always resolve at read time:

```dart
Future<File> resolve(String relativePath) async {
  final dir = await getApplicationDocumentsDirectory();
  return File(p.join(dir.path, relativePath));
}
```

### 6.4 Pre-computed waveform peaks

At write time, generate a downsampled peak-per-pixel array (200 peaks per event regardless of duration), serialize to a sidecar `.peaks` file. Player reads peaks instantly without loading the full event.

## Phase 7 — Opus encoding

### 7.1 Path A — ffmpeg (faster to ship, supply-chain risk)

`ffmpeg_kit_flutter` was archived by its original maintainer in 2024. There are forks (e.g. `ffmpeg_kit_flutter_new`); audit the one you pick before depending on it. The dependency is a ~50 MB AAR/framework; budget for it.

```dart
Future<File> encodeEventToOpus(Uint8List pcm, String outRelPath) async {
  final dir = await getApplicationDocumentsDirectory();
  final outPath = p.join(dir.path, outRelPath);
  await Directory(p.dirname(outPath)).create(recursive: true);

  final tmpPcm = await _writeTmpPcm(pcm);
  final cmd = '-f s16le -ar 16000 -ac 1 -i ${tmpPcm.path} '
              '-c:a libopus -b:a 24k -application voip $outPath';
  final session = await FFmpegKit.execute(cmd);
  if (!ReturnCode.isSuccess(await session.getReturnCode())) {
    throw StateError('opus encode failed');
  }
  await tmpPcm.delete();
  return File(outPath);
}
```

### 7.2 Path B — native libopus FFI (more setup, lighter, maintained)

Vendor `libopus` (Android: `.so` per-ABI; iOS: `.framework` or `.xcframework`). Use `dart:ffi` to call `opus_encoder_create`, `opus_encode`. 5–10 MB binary footprint, ~10× faster encoding than ffmpeg, no supply-chain risk. ~1–2 days of setup including container/Ogg framing for `.opus` files.

**Recommendation:** start with Path A to ship the loop; budget Path B as a Phase 7.5 if battery telemetry warrants it (you'll know after the first week of real overnights).

### 7.3 Backpressure

Encoding runs on a worker isolate. Events queue while encoding. If events come faster than ffmpeg can drain the queue (rare but possible on a noisy night with a slow phone), the queue grows unbounded. Cap the queue:

```dart
class EncodeQueue {
  final _queue = <_PendingEncode>[];
  static const _maxDepth = 8;

  Future<void> submit(_PendingEncode job) async {
    if (_queue.length >= _maxDepth) {
      // Drop oldest pending job; mark its DB row as deleted.
      final oldest = _queue.removeAt(0);
      debugLog.event('encode_dropped_overflow', {'id': oldest.eventId});
      await eventRepo.softDelete(oldest.eventId, reason: 'encode_overflow');
    }
    _queue.add(job);
    _maybeStart();
  }
}
```

Drop-oldest is the right policy: newer events are more likely to still be in-context for the user; the oldest is the easiest to lose. Log every drop so you can tune.

## Phase 8 — UI

State management: Riverpod, three providers:

- `recorderControllerProvider` — `isRecording`, `start()`, `stop()`. Wraps the recorder service.
- `eventsForNightProvider(DateTime)` — `StreamProvider` watching `EventRepo.eventsForNightStream(date)` so the timeline updates live.
- `gapsForNightProvider(DateTime)` — same shape, but for recording gaps. Rendered as `GapTile` between event tiles.

Screens:

1. **Home** — big "Start" / "Stop" button + elapsed time + "View last night's events".
2. **Timeline** — `EventTile`s grouped by hour, interspersed with `GapTile`s for interruptions. Each event tile: time, top label, duration, mini RMS sparkline, play button.
3. **Player** — full-screen waveform (from peaks file), transport controls. Star toggle. Manual relabel. Soft-delete with undo snackbar.
4. **Calibration** — onboarding + "Recalibrate" in settings.
5. **OEM onboarding** — see Phase 10.

**Display label rule** (codify in one place):

```dart
String displayLabel(Event e) {
  if (e.userLabel != null) return e.userLabel!;
  return e.topLabel ?? 'Other';   // pre-computed at write time
}
```

The `top_label` column is pre-computed when the row is updated to `ready` — don't re-parse `labels_json` on every render. Timeline can show hundreds of tiles on a noisy night; JSON-parsing them all per scroll frame burns CPU.

**Day-boundary policy:** a recording session belongs to one "night" by its start time, even if it crosses midnight. Events from a session that started at 23:55 are all under the previous date. Implement once in a single helper, `nightOf(Event e)`, used everywhere.

(Edge case: if someone uses the app for a 06:00 nap, the "night" of that session is the previous calendar day, which is wrong but harmless — it just means naps and overnight sessions are co-mingled under one date. Fine for v1.)

**Locale:** v1 ships English-only. Consent text, OEM walkthroughs, and label names are hardcoded English. i18n (specifically `is_IS`) is v2 work — retrofitting is annoying but not as bad as trying to write the consent flow in two languages from day one. Test with the device set to a non-English locale to confirm date headers and time formatting still render correctly via `intl`'s default formatters.

## Phase 9 — Janitor + retention with quota under pressure

`lib/janitor/janitor.dart` runs four passes:

1. **Hard-delete**: rows where `deletedAt IS NOT NULL` and older than 1 day → delete row + audio file + peaks file.
2. **Auto-prune**: rows where `started_at < now - retentionDays` AND `starred = false` → soft-delete.
3. **Orphan sweep**: walk `events/YYYY-MM-DD/` directories, compare to DB, delete files with no row.
4. **Pending sweep**: rows where `state='pending'` AND `createdAt < now - 60s` → DELETE (encode failed mid-flight; no file exists).

### Quota-under-pressure

Before recording starts, check free disk via `Directory(docsDir).statSync()` (or platform equivalent). If `free < RetentionCfg.minFreeDiskMb`:

1. Sort unstarred events by `started_at` ascending.
2. Soft-delete oldest events (regardless of age) until free space is back above the threshold or we run out of unstarred events.
3. If still below threshold, surface an in-app warning: "Low storage — recording disabled. Free space in Manage Storage to continue." Do not start recording.

This is the "fridge in a studio" failure mode: a single noisy night can balloon disk usage beyond expectations. Quota policy keeps the app from filling the device.

### Manage Storage screen

Quota refuses to delete starred events. If the user has accumulated 100 starred snores from a noisy week, they can fill the disk with content the janitor won't touch. Give them a way out:

- Total storage used + breakdown by date (bar chart over the last N days).
- Per-night actions: "Delete all unstarred from this night" (bulk soft-delete).
- Star-management list: every starred event with a quick "unstar" toggle.
- "Recording disabled" banner if quota is in the failed state, with direct links to the bulk actions above.

Without this, the failure mode "user can't record because their starred backlog filled the disk" has no in-app recovery path.

### Crash and reboot detection

Recording sessions can end three ways: clean stop, app crash, phone reboot/death. The UI needs to know which.

- Persist `session_started_at` and `last_clean_shutdown_at` to `shared_preferences`.
- On `start()`: write `session_started_at = now`, clear `last_clean_shutdown_at`.
- On `stop()`: write `last_clean_shutdown_at = now`, clear `session_started_at`.
- On every app launch: if `session_started_at` is set and `last_clean_shutdown_at` is unset → previous session ended unexpectedly. Compute gap (`now - last_heartbeat` from the heartbeat log), write a `RecordingGap` row covering it, log a `crash_detected` debug event, surface "Last recording ended unexpectedly at HH:MM" in the UI.

Without this, a weekly mid-event crash shows up as "weird missing data" and you never investigate. With this, you have a counter.

### Reboot auto-resume (opt-in)

The default — don't auto-resume after reboot — is correct: nothing surprises a user more than a phone they didn't unlock starting to record. But the failure mode is real: phone reboots at 3 AM for an OS update, half the night is lost.

Add a settings toggle: "Auto-resume after reboot during a session." Default off. When on:

- Schedule a `BOOT_COMPLETED` receiver (Android) / no-op on iOS (no equivalent permission).
- On boot: if `session_started_at` is set and `now - session_started_at < 12 h`, restart the recorder with the same session ID.
- Surface a notification: "Resumed recording after restart at HH:MM."

Document the limitation in the toggle's helper text: iOS doesn't support this; Android requires the `RECEIVE_BOOT_COMPLETED` permission and even then OEMs may suppress it.

### Schedule

- **Android:** `workmanager` periodic, every 6 hours. Note: WorkManager periodic minimum is 15 minutes; under Doze the actual interval can be much longer than 6 hours. The janitor is idempotent so this doesn't matter.
- **iOS:** run at app launch and on recorder service stop. `BGTaskScheduler` is unreliable while the audio session is active.

## Phase 10 — OEM polish, AVAudioSession deep config, distribution

### 10.1 Android OEM onboarding

`device_info_plus` to detect manufacturer. For known-bad OEMs (Samsung, Xiaomi, Realme, OnePlus, Oppo, Vivo, Huawei), add a screen to the first-launch flow with platform-specific instructions:

- **Samsung:** Settings → Battery → Background usage limits → Never sleeping apps → add ours.
- **Xiaomi (MIUI):** Settings → Apps → Manage apps → did_i_snore → Battery saver = No restrictions; Autostart = on.
- **OnePlus / Oppo / Realme:** Battery → Battery optimization → Don't optimize for our app.
- **Huawei:** App launch → Manage manually → enable all three (Auto-launch, Secondary launch, Run in background).

Use `disable_battery_optimization` to deep-link into the right settings activity where possible. Walk the user through it; verify with a "Test recording (5 min)" button after onboarding before the first real night.

### 10.2 iOS AVAudioSession

Already specified in Phase 1.2. Reiterate the production requirements:

```swift
try session.setCategory(
    .playAndRecord,
    mode: .measurement,
    options: [.mixWithOthers, .allowBluetooth, .duckOthers]
)
```

Subscribe and handle:

- `interruptionNotification` → on `.began`: stop recording, log gap start. On `.ended` with `.shouldResume = true`: re-activate session, resume recording, write `RecordingGap` row with duration.
- `interruptionNotification` → on `.ended` with `.shouldResume = false` (the user took the call, returned to home screen, etc.): the recorder is dead and iOS is telling us not to come back. Surface a persistent local notification "Recording stopped — tap to resume." Do not silently retry. The user agreed to record; if iOS says we can't, the user gets to decide whether to restart.
- `routeChangeNotification` → re-activate session if audio route became unavailable. Log a `route_change` gap row covering the transition.

Every interruption produces a `gap` row in the DB:

```dart
class RecordingGaps extends Table {
  IntColumn get startedAt => integer()();
  IntColumn get endedAt => integer()();
  TextColumn get reason => text()();   // 'interruption' | 'route_change' | 'crash'
}
```

The timeline UI renders gaps so the user knows when the recorder was deaf — a 3-minute hole is meaningful information, not something to hide.

### 10.3 Network enforcement

Belt-and-suspenders:

- **Android:** omit `INTERNET` permission (already done). Also set `android:usesCleartextTraffic="false"` and `android:networkSecurityConfig` pointing to a config that blocks all domains.
- **iOS:** `NSAppTransportSecurity → NSAllowsArbitraryLoads = false`. Doesn't block all networking but ensures any future dep that tries to phone home over plaintext fails.

Document these in the privacy section of the README, not just buried in the manifest.

### 10.4 Distribution

**Android:**

```bash
flutter build apk --release
adb install build/app/outputs/flutter-apk/app-release.apk
```

**iOS — TestFlight (for partner):**

1. Bump build number in Xcode.
2. `flutter build ipa --release`.
3. Upload via Xcode Organizer.
4. Add partner's Apple ID as a TestFlight tester.

90-day expiry — set a calendar reminder, or use `/schedule` for an agent that nudges you.

**iOS — Xcode sideload (for self):**

1. `flutter run --release` from the project root.
2. Trust the developer cert in Settings → General → VPN & Device Management.
3. Personal-team certs expire in 7 days. Re-`flutter run` resigns.

### 10.5 Store-disclosure prep

- **Play Store data safety form:** declare audio is collected, processed on-device, not transferred, not shared. Be explicit.
- **App Store privacy nutrition labels:** "Data Not Collected." Confirm this matches the actual code on every release.
- Some app-security scanners flag continuous-mic apps as potential spyware. Anticipate that personal/internal builds may need allowlisting in MDM environments.

## Failure modes and recovery

Concrete behavior for everything that can go wrong:

| Failure | Behavior |
| --- | --- |
| Disk full mid-night | Quota policy from Phase 9 kicks in; if it can't free enough, recorder pauses, writes gap, emits in-app warning. Never crashes silently. |
| DB write fails after Opus written | Orphan file. Janitor's orphan sweep deletes it. |
| Opus write fails after DB row inserted | Row stays `pending` past 60 s; janitor's pending-sweep deletes it. |
| App crashes mid-event | In-flight `EventWindow` is lost. No recovery — pre-roll is in RAM only. Acceptable. |
| Phone reboots mid-night | Recorder is dead. **Do not auto-resume** — surprises the user with a re-engaged mic. On next app launch, show "Last recording ended unexpectedly at HH:MM." Optional: persistent setting "Auto-resume after reboot," default off. |
| Mic permission revoked | Recorder service catches the OS error, stops cleanly, emits notification "Recording stopped: mic permission revoked." |
| Battery dies | Recorder dead. App on next launch shows "Last recording ended unexpectedly at HH:MM (estimated battery)." Add a low-battery warning when starting record on <30% unplugged. |
| iOS audio session interrupted (call) | See Phase 10.2 — gap row written, recorder resumes after `.ended` notification. |
| AirPods connect mid-night | Route change handled, session re-activated, gap row written for the route-change duration. |
| Encode queue overflow | Drop oldest pending encode (Phase 7.3 backpressure); log to debug log. |
| OEM kills foreground service | The OEM-onboarding screen is what prevents this; if it happens anyway, the next app launch detects the gap (`now - lastHeartbeat > 5 min`) and writes a gap row covering the dead period. |

## Debug logging

Network-free, so no Sentry. Build a buffered circular log file:

`lib/diag/debug_log.dart`:

```dart
class DebugLog {
  static const _maxBytes = 2 * 1024 * 1024;
  static const _flushIntervalSec = 5;
  static const _bufferLineLimit = 200;
  late final File _f;
  final List<String> _buffer = [];
  Timer? _flushTimer;

  Future<void> init() async {
    final dir = await getApplicationDocumentsDirectory();
    _f = File(p.join(dir.path, 'debug.log'));
    _flushTimer = Timer.periodic(
      const Duration(seconds: _flushIntervalSec),
      (_) => _flush(),
    );
  }

  void event(String name, [Map<String, dynamic>? props]) {
    _buffer.add(jsonEncode({
      'ts': DateTime.now().toIso8601String(),
      'event': name,
      ...?props,
    }));
    if (_buffer.length >= _bufferLineLimit) _flush();
  }

  Future<void> _flush() async {
    if (_buffer.isEmpty) return;
    final lines = _buffer.join('\n');
    _buffer.clear();
    await _f.writeAsString('$lines\n', mode: FileMode.append);
    if (await _f.length() > _maxBytes) await _truncateHalf();
  }

  /// Force-flush. Call on stop(), on crash detection, on app pause.
  Future<void> shutdown() async {
    _flushTimer?.cancel();
    await _flush();
  }
}
```

Buffered, not `flush: true` per line — gate transitions can fire many times per minute, and an fsync each time burns measurable battery over 8 hours. Forced flush on `stop()`, on `AppLifecycleState.paused`, and as the first action on the next launch (so a crash loses at most ~5 s of recent log).

Add a "Share debug log" button in settings (OS share sheet — only leaves the device on explicit user action, consistent with the privacy stance). Log every state transition: gate open/close, calibration changes, encode queue depth, gaps, rejects, crashes, OEM kill detections. Never log audio data.

## Testing strategy

### Unit-testable in isolation

- **PcmSlicer** — explicit chunk-boundary tests.
- **RingBuffer** — wrap, snapshot ordering, capacity behavior.
- **NoiseFloor** — fixture frame sequences, assert thresholds.
- **Gate** — synthetic dBFS sequences (silence, ramp, alternating), assert open/close transitions.
- **SpectralProbe** — synthetic sine waves at known frequencies, verify band fractions and flatness.
- **LabelMap** — known YAMNet score vectors, verify curated outputs.
- **Janitor passes** — set up DB + filesystem state, run pass, assert post-state.

### Integration tests with audio fixtures

Build the fixture corpus before tuning thresholds. Each is 30–60 s of real audio:

- `silence.wav` — quiet bedroom, no events.
- `silence_with_creaks.wav` — quiet but for furniture noises.
- `snore_clean.wav` — your own snoring, isolated.
- `snore_against_pillow.wav` — same, mic muffled.
- `snore_far_from_mic.wav` — phone 3 m away.
- `speech_two_people.wav` — bedroom conversation.
- `snore_with_speech_overlap.wav` — both at once.
- `traffic_distant.wav` — window open, no other sounds.
- `hvac_running.wav` — fan/AC steady.
- `cough_and_throat.wav` — discrete events.
- `overnight_full.wav` — 8-hour real recording from your own bed (the most important fixture; collect after Phase 1 passes).

For each: run the full pipeline, assert event count is in expected range, top labels are correct ≥80% of the time.

These fixtures are the regression test for any tuning change. The overnight one is the only way to know your real false-positive rate.

### Manual platform tests

Things you can't automate. Keep `docs/MANUAL_TEST.md` and run before merging anything that touches the recorder or platform glue:

- 8-hour overnight on each platform, plugged and unplugged.
- Phone call mid-recording.
- Bluetooth route change mid-recording (regular AirPods + AirPods Pro in A2DP-only state).
- Battery saver / Doze on Android — `adb shell dumpsys deviceidle force-idle` to simulate.
- OEM service-kill simulation — `adb shell am stopservice <pkg>/.RecorderService` mid-recording, verify gap row appears on next launch.
- Each OEM you support, real device, overnight.
- Cold-start after reboot — recorder should not auto-resume (unless toggle is on).
- Auto-resume toggle on, simulated reboot — recorder restarts within 30 s of boot, notification surfaces.

## v1 acceptance checklist

- [ ] Phase 1 smoke test passes on Pixel and iPhone.
- [ ] Calibration runs on first launch with live visualization.
- [ ] OEM onboarding completes for the test Samsung/Xiaomi device.
- [ ] Tap Start, lock screen, leave for 8 hours **unplugged** on a >80% battery; recorder survives.
- [ ] **Anchored battery test:** same phone, two consecutive nights, both starting >80%. Night A: recording all night. Night B: idle. App-induced drain = (B's end %) − (A's end %). Pass if app-induced drain < 35 percentage points. (Anchoring to a same-device idle baseline removes confounders like phone model, battery age, and ambient temperature.)
- [ ] Timeline shows ≥ 1 event with a non-`Other` label.
- [ ] Tap event → audio plays back: pre-roll audible (~2 s of pre-event audio before the loud part), tail audible (~1 s after), correct loudness, no clipping, duration matches `endedAt - startedAt` within ± 100 ms.
- [ ] Phone-call interruption + recovery → gap row visible in timeline; audio resumes within 2 s of `.ended` notification.
- [ ] Force-stop the recorder service mid-night (`adb shell am stopservice ...`) → next app launch detects and logs gap; user is notified.
- [ ] Star an event, run janitor with retention=1 day → starred event survives, unstarred ones deleted with their files.
- [ ] Soft-delete an event → disappears immediately, file removed on next janitor run.
- [ ] Force-quit the app mid-event → no orphan rows or files after janitor run on next launch.
- [ ] Phone-call interruption mid-recording → gap row created, timeline shows gap marker, recording resumes after call.
- [ ] AirPods connect mid-recording → gap or seamless continuation, no death.
- [ ] No outbound network traffic over 8 hours, verified via `adb shell tcpdump` on Android, Charles Proxy on iOS.
- [ ] Repeat full 8-hour test on partner's iPhone with TestFlight build.
- [ ] Debug log has no `error` lines after a clean run.

When all of these pass on both devices, ship v1.
