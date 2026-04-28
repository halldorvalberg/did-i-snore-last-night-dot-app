---
description: Phase 0 — Bootstrap (Flutter project, folder layout, deps, constants, consent flow)
---

Implement Phase 0 — Bootstrap from `docs/IMPLEMENTATION.md`. Read Phase 0 first; the spec there is canonical.

## Goal

A buildable Flutter project with the agreed folder layout, pinned dependencies, the canonical constants file, and a first-launch consent screen that runs before the OS permission prompt.

## Workflow

1. Read `docs/IMPLEMENTATION.md` Phase 0.
2. Create the Flutter project on the main thread:
   ```bash
   flutter create --org app.didisnorelastnight --platforms=android,ios did_i_snore
   ```
3. Set up the folder layout per 0.1 (empty files / placeholder modules are fine).
4. Add dependencies via `flutter pub add` per 0.2 (pin versions). Verify `flutter pub get` resolves cleanly.
5. Write `lib/config/constants.dart` exactly per 0.3. No inline literals elsewhere — that's a spec-reviewer fail later.
6. Delegate first-launch consent flow to **ui-builder**. Brief: the 5-step flow described in 0.4, hardcoded English, "Continue" triggers the OS mic-permission dialog.
7. Run `flutter analyze` and boot on a connected device to confirm the consent flow appears.
8. Delegate to **spec-reviewer** for a privacy-invariants pass: no `INTERNET` permission, no analytics deps, ATS configured.

## Done when

- `flutter analyze` is clean.
- App boots on Android and iOS.
- Consent screen renders on first launch; OS permission dialog follows "Continue."
- `pubspec.yaml` has no networking or analytics deps.
- Spec-reviewer reports PASS on privacy invariants.

## Out of scope

- Mic capture (Phase 2).
- Background service / AVAudioSession (Phase 1).
- Any actual recording.
