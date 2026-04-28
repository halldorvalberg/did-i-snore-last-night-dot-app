---
description: Phase 4 — Gate, event window, spectral pre-filter
---

Implement Phase 4 — Gate, event window, spectral pre-filter from `docs/IMPLEMENTATION.md`. Read Phase 4 first.

## Goal

Detect events with the hysteresis gate, capture them into windows (pre-roll + live + tail), and reject obvious garbage with a calibration-aware spectral pre-filter before paying YAMNet's cost.

## Workflow

1. Read `docs/IMPLEMENTATION.md` Phase 4.
2. Delegate to **audio-pipeline-builder**: implement `lib/recorder/gate.dart` (RMS hysteresis, ≥300 ms hold to open, 1 s tail to close), `lib/recorder/spectral.dart` (FFT-based snore-band fraction + flatness), `lib/recorder/event_window.dart` (pre-roll prepend, append on chunk, no zero-padding for merges).
3. **Spectral filter must be gated on calibration MAD.** If `noiseFloor.madDbfs > SpectralCfg.maxAmbientMadForFilter`, skip the filter for the session — it's a fan-rejector, not a snore-detector.
4. Delegate to **test-author** in parallel: Gate transition tests (silence, sustained-above-with-300ms-hold, hysteresis check, tail timing), SpectralProbe tests with synthetic sine waves at known frequencies, EventWindow tests including pre-roll prepend.
5. Wire it all together in `lib/recorder/recorder_service.dart` so a manual end-to-end test can fire: tap Start, clap at the phone, observe an event.
6. Run `flutter test test/recorder/`.
7. Delegate to **spec-reviewer**: confirm event merging is data-layer-only (no zero-padding in audio), confirm spectral filter has the ambient-MAD bypass.

## Done when

- Gate fires on the right inputs, ignores noise below `tHigh`, holds 300 ms, releases after 1 s.
- Spectral filter rejects fan-only events in quiet ambients, defers to YAMNet in noisy ambients.
- Event windows include the pre-roll, no zero-padded merges.
- Min-event-duration filter (500 ms) drops one-frame creaks.

## Out of scope

- YAMNet classification (Phase 5).
- File encoding (Phase 7).
- DB writes (Phase 6).
- Data-layer event merging — that's Phase 6's `EventRepo`.
