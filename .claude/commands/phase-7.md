---
description: Phase 7 — Opus encoding (worker isolate, .tmp + rename, backpressure)
---

Implement Phase 7 — Opus encoding from `docs/IMPLEMENTATION.md`. Read Phase 7 first.

## Goal

Encode each event's PCM into a `.opus` file via a worker isolate, using the atomic `.tmp` + rename pattern from Phase 6's state machine, with bounded-queue backpressure.

## Decision needed up-front: Path A or Path B

- **Path A — ffmpeg (faster to ship).** `ffmpeg_kit_flutter` was archived in 2024; pick a maintained fork (e.g., `ffmpeg_kit_flutter_new`) and audit before depending on it. ~50 MB binary footprint.
- **Path B — native libopus FFI.** ~5–10 MB footprint, ~10× faster encode, no supply-chain risk. ~1–2 days of FFI setup.

**Recommendation:** Path A for v1, swap to Path B if battery telemetry warrants. State your choice before delegating.

## Workflow

1. Read `docs/IMPLEMENTATION.md` Phase 7.
2. Confirm Path A vs Path B with the user if not already decided.
3. Delegate to **audio-pipeline-builder** (encoder lives in `lib/recorder/`):
   - `lib/recorder/opus_encoder.dart` — encode PCM to `<audio_path>.tmp`, then atomic `File.rename` to final path.
   - `lib/recorder/encode_queue.dart` — bounded queue (`_maxDepth = 8`), drop-oldest on overflow, log `encode_dropped_overflow` to debug log and soft-delete the dropped row.
4. Wire the encoder into the post-classification flow: Phase 5 has produced `(pcm, labels, top_label)`, Phase 6 inserted the `pending` row, now Phase 7 encodes and Phase 6's `markReady` finishes the transition.
5. Delegate to **test-author**: encode-and-rename tests using a small synthetic PCM blob, queue-overflow test (submit 10 jobs, assert 8 process and 2 are dropped with the correct events).
6. Run `flutter test`, then a manual end-to-end: clap at the phone, see an event row appear with a playable `.opus` file.
7. Delegate to **spec-reviewer**: confirm atomic rename pattern, confirm backpressure behavior, confirm encoder runs on a worker isolate (not the recorder hot path).

## Done when

- Events get encoded to `.opus` files with the `.tmp` + rename pattern.
- Encode queue has backpressure with logged drops.
- App can produce playable audio files end-to-end.

## Out of scope

- Playback UI (Phase 8).
- Janitor cleanup of `.tmp` files (Phase 9 — but the orphan sweep in Phase 6 already handles them).
