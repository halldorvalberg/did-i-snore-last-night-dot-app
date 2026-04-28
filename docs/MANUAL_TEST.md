# Manual platform tests

Anything that touches the recorder pipeline, AVAudioSession, or the
foreground service must be re-verified here before merging. Automated tests
cannot exercise OS interruption behavior, real Bluetooth route changes, or
8-hour-locked-screen survival.

Keep entries in this file forensic, not aspirational. Document **what you ran,
on which device, on which OS version, on which date**, and what you observed.
"It works" is not an acceptable manual-test note.

## Phase 1 — smoke harness verification

These mirror `docs/IMPLEMENTATION.md` § 1.3. Run all of them, on real
devices, before declaring Phase 1 done.

### 1. 8-hour overnight (Pixel, plugged)

1. Build and install: `cd phase-1-harness && bash bootstrap.sh && flutter run --release`.
2. Tap **Start**, grant mic + notification permissions.
3. Confirm persistent notification "Smoke test recording — tap to manage."
4. Plug into charger, lock screen, leave for ≥ 8 hours.
5. Wake phone, tap **Stop**.
6. Pull `<docs>/smoke/heartbeat.log` via `adb shell run-as` (see README).
7. Run `dart run tools/smoke_verifier.dart heartbeat.log`. Exit 0 = pass.

Expected: ~480 heartbeats; every `bytes_since_last_heartbeat` in
`[1,824,000, 2,016,000]`; zero unexplained gaps.

### 2. 8-hour overnight (iPhone, plugged)

Same as above. Pull the log via Xcode → Devices → Download Container.

Pay attention to the `INFO,...,ios_input_route` lines. Expected:
`MicrophoneBuiltIn/iPhone Mic@<sr>Hz/1ch` if no Bluetooth devices are paired.
Anything reporting `BluetoothHFP` at `8000Hz` is the AirPods downgrade case
and needs investigation before declaring Phase 1 done.

### 3. 8-hour overnight (Pixel, **unplugged**)

Same as #1 but unplug at start, with battery > 80 %. Pass criterion adds:
phone is still alive in the morning.

### 4. Phone-call interruption

1. Start recording with the harness on the test phone.
2. From a second phone, call the test phone.
3. Answer the call, hold for ~15 s, hang up.
4. Continue recording for at least 2 more minutes.
5. Stop, pull log, run verifier.

Expected:

- One `GAP,<start>,<end>,interruption_began` line, where `<end> - <start>`
  ≈ call duration.
- Heartbeats covering the call minute may be out-of-band; the verifier
  must accept them because the GAP covers them.
- Heartbeats after the call back in band within 2 s of `.ended`.

### 5. AirPods connect mid-recording

1. Start recording with no Bluetooth audio device connected.
2. Verify the first `INFO,..,ios_input_route` line shows the built-in mic.
3. Connect AirPods (any model).
4. Wait 2 minutes.
5. Disconnect AirPods.
6. Wait 2 minutes, stop, pull log.

Expected:

- A `GAP,...,route_change` line at each transition.
- A new `INFO,..,ios_input_route` line after each route stabilises.
- Heartbeats back in band within one tick after the route settles.

### 6. AirPods Pro A2DP-only state (iOS)

1. With AirPods Pro charging in their case, take **one** earbud out of the
   case and put it in your ear. iOS will route output to AirPods but, in
   some configurations, will not switch input.
2. Start the harness.
3. Read the `INFO,..,ios_input_route` line.

Expected: explicit route logged, including sample rate and channel count.
This test does not have a single pass criterion — its purpose is to make
the silent-downgrade case **visible** in the log so we can decide whether
to disallow it in production.

### 7. Notification arrives mid-recording

1. Start recording.
2. From another device, send the test phone an SMS / push.
3. Wait 60 s, stop, pull log.

Expected: no GAP, no out-of-band beat.

### 8. Android Doze

1. Start recording.
2. `adb shell dumpsys deviceidle force-idle`.
3. Wait 5 minutes.
4. `adb shell dumpsys deviceidle unforce`.
5. Stop, pull log, run verifier.

Expected: verifier passes. Foreground service must survive; bytes still
flow.

### 9. OEM-kill simulation

1. Start recording.
2. `adb shell am stopservice <pkg>/id.flutter.flutter_background_service.BackgroundService`
   (where `<pkg>` is `app.didisnorelastnight.smoke.phase_1_harness`).
3. Reopen the app.
4. The harness should detect the gap on next launch.

Expected: `GAP,...,service_killed` appears in the log covering the dead
period. (Phase 1 surfaces this on app re-foreground; the production app
will detect it from a watchdog.)

### 10. Samsung One UI overnight

Same as #1 but on a Samsung device after running the OEM-onboarding
deep-link in Settings (Phase 10 will automate this; for Phase 1, do it by
hand following `docs/IMPLEMENTATION.md` § 10.1).

## Reporting failures

If any of the above fails, do **not** continue to Phase 2. File a note in
this document under a new heading describing:

- Device model + OS version
- Date and time of the run
- Exact verifier output (paste, do not paraphrase)
- The relevant GAP / INFO lines from the log
- Hypothesis (do not guess at fixes; document what you saw)

Then escalate per the platform-glue agent contract: "Background-service
survival changes → propose an explicit Phase 1 smoke-test re-run rather
than declaring it works."
