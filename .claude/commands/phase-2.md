---
description: Phase 2 — Mic capture, ring buffer, frame slicer
---

Implement Phase 2 — Mic capture, ring buffer, frame slicer from `docs/IMPLEMENTATION.md`. Read Phase 2 first.

**Prerequisite:** Phase 1 smoke test passed on both platforms. If it didn't, go back.

## Goal

The actual data path: PCM stream → ring buffer + explicit frame slicer that yields 20 ms frames regardless of incoming chunk size. No gating yet, no classification yet. Just clean foundations.

## Workflow

1. Read `docs/IMPLEMENTATION.md` Phase 2.
2. In parallel:
   - Delegate to **audio-pipeline-builder**: implement `lib/recorder/mic_source.dart`, `lib/recorder/pcm_slicer.dart`, `lib/recorder/ring_buffer.dart`, `lib/recorder/energy.dart`. Use `Uint8List` ring tail in the slicer (no `List<int>` boxing); use `setRange` with split-on-wrap in the ring buffer.
   - Delegate to **test-author**: write tests for all three modules, including the canonical PcmSlicer chunk-boundary test (73 bytes then 12000 bytes → 18 frames + 553-byte tail) and ring buffer wrap tests.
3. Run `flutter test test/recorder/` — all tests must pass.
4. Delegate to **spec-reviewer** for a constants-discipline pass: no inline literals for frame sizes, sample rates, or buffer capacities.

## Done when

- All four modules implemented and unit-tested.
- Tests cover the chunk-boundary edge cases and wrap-around.
- `flutter analyze` clean.
- Spec-reviewer PASS.

## Out of scope

- Energy gate (Phase 4).
- Calibration (Phase 3).
- Event windowing (Phase 4).
- File I/O — at this stage the pipeline ends in `Stream<Uint8List>`-of-frames; nothing is written to disk.
