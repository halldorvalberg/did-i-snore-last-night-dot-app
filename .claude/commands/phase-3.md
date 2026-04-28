---
description: Phase 3 — Calibration (median+MAD noise floor, live RMS visualization, no silent upward refinement)
---

Implement Phase 3 — Calibration from `docs/IMPLEMENTATION.md`. Read Phase 3 first.

## Goal

Stop hardcoding `tHigh` / `tLow`. Derive them from the actual room via median + MAD noise-floor estimation, with a live-visualization UI and a strict "no silent upward refinement at runtime" policy.

## Workflow

1. Read `docs/IMPLEMENTATION.md` Phase 3.
2. In parallel:
   - Delegate to **audio-pipeline-builder**: implement `lib/recorder/calibrator.dart` (median + MAD on frame-RMS dBFS, `tHigh = median + 5*MAD`, `tLow = median + 3*MAD`, persistence via `shared_preferences` keyed by `deviceId`). Implement the per-session downward refinement (only when window variance is low, never raise threshold during a session).
   - Delegate to **ui-builder**: build `lib/ui/setup/calibration_screen.dart` — live RMS bar at ~10 Hz, 30-second sliding history strip, "Save calibration" button enabled only after ≥10 contiguous seconds below the estimated quiet floor, "Cancel and try again" link always visible.
3. Delegate to **test-author**: NoiseFloor unit tests with synthetic frame sequences (uniform, normal-with-outliers, all-identical-MAD-zero edge case). Calibrator persistence test.
4. Run `flutter test`, then run on a connected device and walk through calibration manually.
5. Delegate to **spec-reviewer** for a "no silent upward refinement" check: confirm runtime refinement only lowers the threshold, only when variance is low.

## Done when

- Calibrator implemented and tested.
- Calibration screen renders live, "Save" gates correctly on the quiet-floor condition.
- Threshold persists across app restarts.
- No code path raises `tHigh` mid-session.

## Out of scope

- Gate state machine (Phase 4) — Phase 3 only produces thresholds; Phase 4 consumes them.
- Spectral filter (Phase 4).
