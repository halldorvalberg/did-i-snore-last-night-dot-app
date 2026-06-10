# CLAUDE.md

Guidance for Claude Code (claude.ai/code) when working in this repository.

## What this is

**did-i-snore-last-night.app** — a Flutter (Android + iOS) app that records you while
you sleep, throws away the silence, and shows a morning timeline of the noises you
actually made (snores, sleep-talk, coughs, the cat at 3 AM). Everything runs
**on-device, no network**. It's a personal app for the author and partner — no
monetization, no analytics, no accounts.

The load-bearing design decision is privacy: on Android the `INTERNET` permission is
omitted from the release manifest entirely, so the OS won't let any dependency open a
socket. Audio never leaves the app sandbox except through the OS share sheet, one
event at a time, on explicit user action.

## Source of truth

- `README.md` — product design, data model, label set, stack. Locked; revisit before
  changing event-merge semantics, retention, or labels.
- `docs/IMPLEMENTATION.md` — the staged build plan (Phases 0–10), ordered by risk.
  This is the authoritative spec. Phase numbers below map to its sections.
- `docs/MANUAL_TEST.md` — the device tests that can't be automated.
- `.claude/commands/phase-*.md` — per-phase task briefs (also surfaced as `/phase-N`).

When code and docs disagree, treat the doc as intent and flag the drift; don't silently
"fix" the doc to match code.

## Layout

```
did_i_snore/                  # the Flutter app (cd here for all dart/flutter commands)
  lib/
    config/constants.dart     # ALL tunables live here — never sprinkle literals
    consent/                  # first-launch consent flow (precedes OS mic prompt)
    recorder/                 # the audio pipeline (see below)
    classifier/               # YAMNet TFLite + curated label map
    data/                     # Drift (SQLite) schema, EventRepo, *.g.dart (committed)
    janitor/                  # retention sweeps, quota-under-pressure, scheduler
    ui/                       # Riverpod + Flutter screens
  test/                       # mirrors lib/ ; 240+ tests, fixture-driven
  assets/models/              # yamnet.tflite (int8) + yamnet_class_map.csv
phase-1-harness/              # throwaway Phase-1 smoke test; holds the REFERENCE
                              # native Kotlin RecorderService.kt (not yet ported to prod)
docs/                         # IMPLEMENTATION.md, MANUAL_TEST.md
```

## The audio pipeline (lib/recorder/)

Per 20 ms frame (16 kHz mono int16): RMS→dBFS → ring buffer (always) → gate. On
gate-open, an `EventWindow` is seeded with a 2 s pre-roll snapshot; on gate-close,
duration filter → optional spectral pre-filter → emit.

```
mic → pcm_slicer → ring_buffer → gate (RMS hysteresis, 300 ms hold)
                                   └→ event_window (2 s pre-roll + live + 1 s tail)
                                        → spectral pre-filter (cheap reject)
                                        → yamnet classify (0.96 s frames, max-over-frames)
                                        → encode_queue → opus + Drift row
```

Key invariants (don't regress these):
- **Permissive RMS gate, not a speech VAD.** Snoring is rhythmic non-speech; VADs gate
  it out. The gate keeps everything noisy and lets YAMNet disambiguate.
- **Merge is a data-layer concern only.** Events <4 s apart become two rows the UI
  groups visually. Never merge at the audio layer (produces "broken recorder" silence).
- **Threshold comes from calibration, never a constant.** median + MAD noise floor.
  Runtime refinement may only *lower* `tHigh`, never raise it (see
  `memory/phase3_quiet_check.md`).
- **Classifier aggregation = max-over-frames with a precision floor** — preserves a
  brief snore inside a long speech event without promoting single-frame outliers.

## Android recorder is native Kotlin (architecture lock-in)

Phase 1 proved the Dart `record` + `flutter_background_service` stack is **not viable on
Android 14+** (FGS-promotion timeout SIGKILL + isolate listener race — IMPLEMENTATION
§1.4). The production Android recorder MUST be a native Kotlin foreground `Service` that
owns `AudioRecord` and calls `startForeground(..., FOREGROUND_SERVICE_TYPE_MICROPHONE)`
synchronously in `onStartCommand`, publishing PCM to Dart over an `EventChannel`.

`lib/recorder/recorder_service.dart` is the **iOS recorder and the Dart test harness
only** — it is explicitly *not* the Android production path. Do not wire it into the
Android FGS. The reference native service lives in `phase-1-harness/.../RecorderService.kt`
and has not yet been ported into `did_i_snore/android/` — that port is outstanding glue work.

Audio source is `AndroidAudioSource.unprocessed` (raw, no AGC/NS — they'd corrupt the
noise floor). Requires `minSdk = 24`; we refuse to ship below it.

## Constants discipline

Every tunable lives in `lib/config/constants.dart` (`AudioCfg`, `GateCfg`, `SpectralCfg`,
`LabelCfg`, `RetentionCfg`). When tuning behavior, change the constant — never inline a
literal in pipeline code. Tests reference these constants too.

## Persistence (lib/data/)

Drift/SQLite. One row per event with a `pending → ready` state machine: insert
`pending` → encode to `<path>.tmp` → `File.rename` → update `ready`. This avoids
orphans/dead-rows on mid-encode crash. `audioPath`/`peaksPath` are **relative** to the
docs dir (iOS rewrites the sandbox UUID on every TestFlight reinstall — absolute paths
break). Recovery sweeps (pending/orphan/missing-file) run at boot and each janitor cycle.

## Commands

All from `did_i_snore/`:

```bash
flutter pub get
flutter test                                          # full unit/widget suite (~240 tests)
flutter test test/path/to/foo_test.dart               # single file
flutter analyze
dart run build_runner build --delete-conflicting-outputs   # regen Drift *.g.dart (committed)
flutter build apk --release
flutter build ipa --release
```

Drift `*.g.dart` files are committed, so a fresh checkout analyzes without codegen; rerun
build_runner only after touching a table class.

## Conventions

- **Match the surrounding file's idiom** — comment density here is high and explains
  *why* (platform bugs, supply-chain notes); preserve that when editing those files.
- **Tests are fixture-driven and mirror `lib/`.** Land code with tests; the
  `test-author` and `spec-reviewer` agents exist for this.
- **No network code, ever.** No SDK that phones home. Audit every dependency add against
  the privacy stance.
- **Commits on this repo omit the `Co-Authored-By: Claude` trailer.**
- Specialized subagents exist per subsystem (audio-pipeline, classifier, persistence,
  platform-glue, ui, test-author, spec-reviewer) — prefer them for in-domain work.

## Status (v1 in development, nothing ships yet)

Phases 0–9 are implemented in Dart with passing tests. Outstanding before v1 ships:
porting the native Kotlin `RecorderService` into the production Android app, iOS
`AVAudioSession` production wiring, OEM onboarding (Phase 10), and the on-device
overnight/battery acceptance tests in IMPLEMENTATION's v1 checklist.
