/// Riverpod wiring shared across UI screens.
///
/// Spec: `docs/IMPLEMENTATION.md` §8 lines 877–908. Three of the four
/// providers listed in the spec live here; the fourth
/// (`recorderControllerProvider`) ships in
/// `lib/recorder/recorder_controller_provider.dart` next to its service
/// dependency.
///
/// **Lifecycle ground rules:**
///
/// - `appDbProvider` is keep-alive (a plain `Provider`, not autoDispose).
///   The DB is a process-singleton: closing it on dispose would tear down
///   the only sqlite handle the recorder, janitor, and timeline all share,
///   so the keep-alive lock is structural — not an optimisation. The
///   `onDispose` close exists for `ProviderScope` overrides in tests
///   where the scope's lifetime IS the DB's lifetime.
/// - `eventRepoProvider` is a thin wrapper around the keep-alive DB.
/// - `docsDirProvider` is a `FutureProvider` so the path resolves once
///   per process and every screen joins against the same root.
/// - `yamnetProvider` lazy-loads the int8-quantized TFLite model. The
///   4.1 MB asset parses in <1 s on a Nothing Phone 3a, but UI callers
///   should still surface a spinner when this provider's `AsyncValue`
///   is `loading` because the first record-button tap waits on it.
///
/// **Empty `gapsForNightProvider`:** Phase 10 will populate the
/// `recording_gaps` table from native interruption notifications. For
/// v1 (Phase 8) the timeline interleave logic is in place but the
/// stream returns `const <RecordingGap>[]` — the provider shape stays
/// stable so the timeline doesn't have to grow a Phase 10 branch later.
///
/// **No telemetry, no analytics, no crash reporters.** Spec line 902 —
/// if a future dep tries to add one, refuse it.
library;

import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../classifier/yamnet.dart';
import '../data/db.dart';
import '../data/event_repo.dart';

/// Process-singleton `AppDb`. One instance per `ProviderScope`; in
/// production the scope IS the process (root `ProviderScope` in
/// `main.dart` lives for the whole app lifetime).
///
/// `onDispose(db.close)` is structurally a no-op in production — the
/// scope never tears down — but matters in tests that build a fresh
/// `ProviderScope` per group: closing the DB on scope tear-down lets
/// the next test open a fresh in-memory database without leaking the
/// previous handle.
final appDbProvider = Provider<AppDb>((ref) {
  final db = AppDb();
  ref.onDispose(db.close);
  return db;
});

/// Repository over the singleton DB. Stateless wrapper; one instance
/// shared by every screen that watches it.
final eventRepoProvider = Provider<EventRepo>(
  (ref) => EventRepo(ref.watch(appDbProvider)),
);

/// Application documents directory. Memoised — the recorder controller
/// and the encode queue both need it, and resolving twice is harmless
/// but wasteful.
final docsDirProvider = FutureProvider<Directory>(
  (_) => getApplicationDocumentsDirectory(),
);

/// YAMNet classifier. Loaded lazily on first watch; the model is parsed
/// off the asset bundle (cold start ~1 s on the reference device). The
/// recorder controller awaits this before calling `RecorderService.start`,
/// so the home screen's record button shows a spinner during this load.
///
/// `onDispose(y.close)` releases the native interpreter when the
/// `ProviderScope` tears down — only meaningful in tests where the
/// scope's lifetime is bounded.
final yamnetProvider = FutureProvider<Yamnet>((ref) async {
  final y = Yamnet();
  await y.load();
  ref.onDispose(y.close);
  return y;
});

/// Live stream of the night's events. Wraps
/// `EventRepo.eventsForNightStream`, which filters
/// `state='ready' AND deletedAt IS NULL` and applies the local-day
/// window. Spec §8 lines 882, 904.
///
/// The `family` argument is the `night` `DateTime`. Two screens watching
/// the same night share one underlying Drift `watch()` because Riverpod
/// memoises by argument equality (and `DateTime` is value-equal).
final eventsForNightProvider =
    StreamProvider.family<List<Event>, DateTime>((ref, night) {
  return ref.watch(eventRepoProvider).eventsForNightStream(night);
});

/// Live stream of the night's recording gaps. Spec §8 line 883.
///
/// **Phase 8 placeholder.** Phase 10 wires the native interruption /
/// route-change listeners that insert rows into `recording_gaps`; until
/// then this returns an empty stream. Keeping the provider shape stable
/// means the timeline's interleave logic doesn't sprout a Phase 10 if
/// branch — once Phase 10 lands, only this provider body changes.
final gapsForNightProvider =
    StreamProvider.family<List<RecordingGap>, DateTime>((ref, night) {
  // TODO Phase 10: query recording_gaps by [nightStart, nightStart+24h)
  // window and surface as a Drift `.watch()` stream.
  return Stream.value(const <RecordingGap>[]);
});
