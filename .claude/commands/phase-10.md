---
description: Phase 10 — OEM polish, AVAudioSession deep config, settings, distribution
---

Implement Phase 10 — OEM polish, AVAudioSession deep config, settings, distribution from `docs/IMPLEMENTATION.md`. Read Phase 10 first.

## Goal

Production-quality platform behavior: OEM-specific onboarding, complete iOS audio session handling (interruptions, route changes, gap rows), reboot auto-resume toggle, network-blocking enforcement, and the build/install pipeline for partner-on-iPhone.

## Workflow

1. Read `docs/IMPLEMENTATION.md` Phase 10.
2. Delegate to **platform-glue-builder**:
   - Production AVAudioSession setup with all three notification subscribers (`interruptionNotification`, `routeChangeNotification`, plus app-lifecycle).
   - `interruptionNotification` `.ended` with `shouldResume = false`: surface a persistent local notification "Recording stopped — tap to resume." Do not silently retry.
   - Network-blocking enforcement: `usesCleartextTraffic="false"` + a `network-security-config` that blocks all domains on Android; `NSAppTransportSecurity → NSAllowsArbitraryLoads = false` on iOS.
   - `RECEIVE_BOOT_COMPLETED` receiver gated on the auto-resume settings toggle.
3. Delegate to **ui-builder** in parallel:
   - `lib/ui/setup/oem_onboarding.dart` — OEM detection via `device_info_plus`, walkthroughs for Samsung, Xiaomi, OnePlus, Oppo, Realme, Vivo, Huawei. Use `disable_battery_optimization` for deep-links. After onboarding: 5-minute test recording to verify foreground service survival.
   - Settings screen: retention window slider, auto-resume-after-reboot toggle (default OFF, with iOS limitation explained in helper text), "Recalibrate," "Share debug log."
4. Delegate to **test-author**: AVAudioSession interruption-handler unit tests where possible (mock `AVAudioSessionInterruptionNotification`); manual-test entries for everything device-only.
5. Update `docs/MANUAL_TEST.md`: add OEM service-kill (`adb shell am stopservice`), Doze (`adb shell dumpsys deviceidle force-idle`), AirPods Pro A2DP-only test, auto-resume after simulated reboot.
6. Set up distribution:
   - **Android:** verify release build runs (`flutter build apk --release`).
   - **iOS:** TestFlight provisioning. Push first build, add partner's Apple ID, set 90-day expiry calendar reminder.
7. Delegate to **spec-reviewer** for the full v1 acceptance checklist (Phase 10 is the final review gate before declaring v1 done).

## Done when

- All v1 acceptance checklist items in `docs/IMPLEMENTATION.md` pass.
- Partner has a working TestFlight build.
- Manual test results are documented in `docs/smoke-test-results/`.
- Spec-reviewer PASS on the full hard-invariants list.

## Out of scope

- v2 features (multi-night stats, custom labels, fine-tuning).
- Anything that requires data we don't have yet (post-shipping evaluation).

## After this phase

Ship v1, sleep on it, collect 3 nights of real data with the in-app CSV export. Then decide on v2 priorities — fine-tuning, stats, or label customization first.
