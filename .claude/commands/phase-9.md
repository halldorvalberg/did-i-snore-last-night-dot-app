---
description: Phase 9 — Janitor + retention + quota under pressure + Manage Storage screen
---

Implement Phase 9 — Janitor + retention from `docs/IMPLEMENTATION.md`. Read Phase 9 first.

## Goal

A janitor that runs the four sweeps on schedule, enforces 14-day retention for unstarred events, refuses to record when disk is too full, and a Manage Storage screen so users with starred backlogs have a way out.

## Workflow

1. Read `docs/IMPLEMENTATION.md` Phase 9.
2. Delegate to **persistence-builder**:
   - `lib/janitor/janitor.dart` — four passes: hard-delete (rows with `deleted_at` older than 1 day), auto-prune (unstarred older than `RetentionCfg.defaultDays`), pending sweep, orphan sweep, missing-file sweep. Run in the documented order.
   - Quota under pressure: pre-recording free-disk check, oldest-unstarred prune, refuse-to-start with surfaced "Manage Storage" prompt if still under threshold.
   - Schedule: `workmanager` periodic 6 h on Android; on iOS run at app launch + on recorder stop.
3. Delegate to **ui-builder** in parallel:
   - `lib/ui/manage_storage/manage_storage_screen.dart` — total used + per-night breakdown, "delete all unstarred from this night" bulk action, star-management list with per-event unstar toggle.
   - Hook into the "Recording disabled — free space" banner that appears when quota is in failed state.
4. Wire crash detection (`session_started_at` / `last_clean_shutdown_at`): on app launch, if previous session crashed, write a `RecordingGap` row covering the gap and log `crash_detected`.
5. Delegate to **test-author**: full sweep tests with realistic DB+filesystem fixtures, quota-under-pressure tests (mock `Directory.statSync()`), idempotency runs.
6. Delegate to **spec-reviewer**: confirm sweep ordering, confirm the v1→v2 migration stub is in place, confirm Manage Storage doesn't bypass starred protection.

## Done when

- Janitor runs on schedule on both platforms.
- Auto-prune removes unstarred events past retention; starred events untouched.
- Disk-full state refuses to record with a recovery path.
- Manage Storage screen lets the user free space without the janitor's help.
- Crash detection produces a gap row on next launch.

## Out of scope

- OEM onboarding (Phase 10).
- Auto-resume-after-reboot toggle (Phase 10's settings).
