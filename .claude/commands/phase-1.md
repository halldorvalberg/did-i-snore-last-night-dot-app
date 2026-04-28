---
description: Phase 1 — Background-survival smoke test (the hard gate before any detection logic)
---

Implement Phase 1 — Background-survival smoke test from `docs/IMPLEMENTATION.md`. Read Phase 1 first.

This phase is the gate. If it doesn't pass on both platforms, do not start Phase 2. The whole product depends on this answer.

## Goal

Prove the app can hold the mic open for 8 hours on a locked, plugged-in phone, surviving phone calls, Bluetooth route changes, notifications, Doze, and OEM service-kill.

## Workflow

1. Read `docs/IMPLEMENTATION.md` Phase 1.
2. Delegate to **platform-glue-builder** to build the throwaway harness:
   - Foreground service (Android) / `AVAudioSession` (iOS) per the locked config (no `.duckOthers`).
   - 30-second PCM segments to `<docs>/smoke/YYYY-MM-DD/HH-MM-SS.pcm`.
   - 60-second heartbeat log including `bytes_since_last_heartbeat`.
   - Interruption + route-change handlers writing `GAP` lines.
3. Delegate to **test-author** in parallel to write the heartbeat verifier — asserts every minute's bytes are in `[1.92 MB × 0.95, 1.92 MB × 1.05]`.
4. Run all 1.3 test rows manually on real devices. There is no automatic version of this — the whole point is to verify on hardware.
5. Capture the heartbeat logs from each overnight run in `docs/smoke-test-results/` for posterity.

## Pass criterion (zero compromise)

- **Zero unexplained gaps.** Every gap traces to a logged interruption.
- 8-hour overnight passes on Pixel and iPhone, plugged AND unplugged from >80%.
- Phone-call interruption + recovery works.
- AirPods Pro A2DP-only state has explicit input-route logging.
- `adb shell dumpsys deviceidle force-idle` doesn't kill the service.
- `adb shell am stopservice` produces a detected gap on next launch (not silent death).

If anything fails, **fix it before Phase 2**. Do not paper over with a higher gap tolerance.

## Out of scope

- Energy gate logic (Phase 4).
- Calibration (Phase 3).
- Any code in `lib/recorder/` beyond the harness (the harness is throwaway — Phase 2 rebuilds it properly).
