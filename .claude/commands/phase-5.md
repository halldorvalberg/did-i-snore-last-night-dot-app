---
description: Phase 5 — YAMNet classifier (int8 quantized, max-over-frames with precision floor)
---

Implement Phase 5 — YAMNet classifier from `docs/IMPLEMENTATION.md`. Read Phase 5 first.

## Goal

For each event window, produce a `(top_label, labels_json)` pair using the int8-quantized YAMNet model, with max-over-frames aggregation gated on a precision floor and a sensible post-classification reject path.

## Workflow

1. Read `docs/IMPLEMENTATION.md` Phase 5.
2. Download the **int8-quantized** YAMNet from TF Hub (NOT the float32 default). Place at `assets/models/yamnet.tflite` along with `yamnet_class_map.csv`. Add to `pubspec.yaml` assets.
3. Delegate to **classifier-builder**: implement `lib/classifier/yamnet.dart` and `lib/classifier/label_map.dart`. Aggregation is **max-over-frames with precision floor** (≥25% of frames above 0.3); within-bucket aggregation is **max, not sum**. Reject policy: drop if `max_curated < 0.3 AND Other > 0.5`.
4. Delegate to **test-author** in parallel: LabelMap tests (known YAMNet vectors → curated outputs, within-bucket max), classifier integration tests against `test/fixtures/snore_clean.wav`, `speech_two_people.wav`, `silence.wav`.
5. Wire the classifier into the post-gate pipeline in `recorder_service.dart`. On `GateClosed`, run YAMNet, apply reject policy, hand `(pcm, labels)` to the persistence layer.
6. Run `flutter test test/classifier/`.
7. Delegate to **spec-reviewer**: confirm precision floor, max-over-frames, within-bucket max, reject policy. Confirm `top_label` is pre-computed (not parsed at render time).

## Done when

- YAMNet runs on-device, ~15–20 ms per inference on a midrange phone.
- Aggregation matches spec exactly.
- Reject policy drops clear non-events; logs `rejected_low_confidence` to debug log.
- Fixture-driven tests pass for the basic acoustic categories.

## Out of scope

- Storing results (Phase 6).
- Encoding the audio (Phase 7).
- Fine-tuning YAMNet — that's v2 work after we collect 3 nights of real data.
