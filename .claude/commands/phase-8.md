---
description: Phase 8 — UI (home, timeline, player, gap markers)
---

Implement Phase 8 — UI from `docs/IMPLEMENTATION.md`. Read Phase 8 first.

## Goal

A user-facing app: home with start/stop, timeline with events + gap markers, player with waveform from peaks file, with Riverpod providers tying it to the recorder service and event repo.

## Workflow

1. Read `docs/IMPLEMENTATION.md` Phase 8.
2. Delegate to **ui-builder**:
   - `lib/ui/home/home_screen.dart` — Start/Stop button, elapsed time, link to last night's events.
   - `lib/ui/timeline/timeline_screen.dart` — events grouped by hour, `GapTile` interleaved between events for interruptions.
   - `lib/ui/timeline/event_tile.dart` — time, top label (pre-computed, NOT JSON-parsed), duration, mini RMS sparkline, play button.
   - `lib/ui/timeline/gap_tile.dart` — visible gap marker with reason and duration.
   - `lib/ui/player/player_screen.dart` — full-screen waveform from `peaks_path` (NOT loading full audio), transport controls, star toggle, manual relabel dropdown, soft-delete with undo snackbar.
   - Riverpod: `recorderControllerProvider`, `eventsForNightProvider`, `gapsForNightProvider`.
3. Use the `nightOf(Event e)` helper consistently for date grouping.
4. Delegate to **test-author**: smoke tests for each provider + a widget test for `EventTile` rendering with a stub event.
5. Run `flutter analyze`, run on a connected device, manually exercise: start a brief recording, observe events appear live in the timeline, play one back, star one, soft-delete one (verify undo works).
6. Delegate to **spec-reviewer**: confirm `top_label` is read pre-computed (no JSON parsing in widgets), confirm `nightOf` is the single helper, confirm no analytics/telemetry SDK was added.

## Done when

- All four screens render and behave per spec.
- Timeline updates live during a recording (StreamProvider works).
- Player loads from peaks file, no full-audio in memory.
- Spec-reviewer PASS.

## Out of scope

- OEM onboarding screen (Phase 10).
- Manage Storage screen (Phase 9).
- Settings screen beyond what's referenced (some bits land in Phase 9 / 10).
