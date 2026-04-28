---
description: Phase 6 — Persistence (Drift schema, pending→ready state machine, atomic .tmp rename)
---

Implement Phase 6 — Persistence from `docs/IMPLEMENTATION.md`. Read Phase 6 first.

## Goal

Drift schema with the `pending` → `ready` state machine. Audio writes use a `.tmp` rename pattern. Recovery sweeps run in the documented order. Soft delete + janitor cleanup; relative paths only.

## Workflow

1. Read `docs/IMPLEMENTATION.md` Phase 6.
2. Delegate to **persistence-builder**:
   - `lib/data/events_table.dart` — schema with `state`, `top_label` (pre-computed), `labels_json`, `audio_path` (relative), `peaks_path`, soft-delete, audit `created_at`, `schema_version`.
   - `lib/data/recording_gaps_table.dart` — interruption/route/crash gap rows for timeline rendering.
   - `lib/data/db.dart` — Drift database with all four indices (`started_at`, `state`, `(starred, started_at)`, `deleted_at`) and the v1→v2 migration template stub.
   - `lib/data/event_repo.dart` — queries: `eventsForNightStream`, `softDelete`, `setStarred`, `setUserLabel`, plus the state-machine helpers `insertPending` → `markReady`.
3. Run `dart run build_runner build` for Drift codegen.
4. Delegate to **test-author** in parallel: state-machine tests (insert pending → encode + rename → mark ready), pending-sweep tests (pending row + `.tmp` file, pending row + final file), orphan-sweep tests, missing-file-sweep tests. Idempotency tests for every sweep (run twice, post-state unchanged).
5. Wire `EventRepo.insertPending` into the post-classification flow from Phase 5.
6. Delegate to **spec-reviewer**: confirm relative paths only, sweep ordering, indices match.

## Done when

- Schema + indices present.
- State machine round-trips correctly.
- All three recovery sweeps tested and idempotent.
- `dart run build_runner build` clean.

## Out of scope

- Actual encoding (Phase 7) — Phase 6 just owns the row + sweep logic.
- Janitor scheduling (Phase 9) — Phase 6 implements the sweep functions; Phase 9 wires them to WorkManager / app-launch.
- Quota under pressure (Phase 9).
