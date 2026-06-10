/// Widget tests for the Manage Storage screen.
///
/// Spec: `docs/IMPLEMENTATION.md` §9 lines 929–938. Pinned behaviour:
///
/// - Empty state renders without crashing.
/// - Per-night card shows correct counts; "Delete all unstarred"
///   soft-deletes ONLY unstarred rows (starred protection is the
///   load-bearing invariant).
/// - SnackBar's "Undo" restores the deleted rows.
/// - Quota-failed banner appears when `quotaResultProvider.canRecord`
///   is false.
///
/// **DB strategy:** swap `appDbProvider` to an in-memory
/// `NativeDatabase.memory()` per test, so `EventRepo.softDelete` /
/// `undelete` round-trip through the same code path the production
/// app uses. The `manageStorageStateProvider` is left un-overridden
/// — it composes `eventRepoProvider` + `freeBytesProvider` +
/// `docsDirProvider`, which we override individually.
library;

import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:did_i_snore/data/db.dart';
import 'package:did_i_snore/janitor/quota.dart';
import 'package:did_i_snore/ui/manage_storage/manage_storage_screen.dart';
import 'package:did_i_snore/ui/providers.dart';

/// Inserts a `state='ready'` row directly. Bypasses `markReady` since
/// the repo's flow requires a pending insert first; we want to set up
/// arbitrary fixtures (different `starred` values, different nights).
Future<int> _insertReady(
  AppDb db, {
  required int startedAt,
  bool starred = false,
}) {
  return db.into(db.events).insert(
        EventsCompanion.insert(
          startedAt: startedAt,
          endedAt: startedAt + 1000,
          durationMs: 1000,
          createdAt: startedAt,
          audioPath: 'events/x/$startedAt.opus',
          state: const Value('ready'),
          topLabel: const Value('Snoring'),
          labelsJson: const Value('{}'),
          starred: Value(starred),
        ),
      );
}

/// Builds the screen wrapped in a tiny MaterialApp so navigation +
/// SnackBar plumbing work. `extraOverrides` can swap in a custom
/// `quotaResultProvider` for the banner test.
Widget _harness({
  required AppDb db,
  required Directory tempDir,
  List<Override> extraOverrides = const [],
}) {
  return ProviderScope(
    overrides: [
      appDbProvider.overrideWith((ref) {
        ref.onDispose(db.close);
        return db;
      }),
      docsDirProvider.overrideWith((_) async => tempDir),
      // Plenty free — the chip renders green and the banner stays off
      // unless a test overrides quota explicitly.
      freeBytesProvider.overrideWith(
          (ref, dir) async => 100 * 1024 * 1024 * 1024),
      // Default quota = "all good"; the banner test re-overrides
      // this. Without an explicit override the provider would call
      // `df` against the host, which is flaky and irrelevant.
      quotaResultProvider.overrideWith(
        (ref) async => QuotaResult.allow(100 * 1024),
      ),
      ...extraOverrides,
    ],
    child: const MaterialApp(home: ManageStorageScreen()),
  );
}

void main() {
  late AppDb db;
  late Directory tempDir;

  setUp(() async {
    db = AppDb.forTesting(NativeDatabase.memory());
    tempDir = await Directory.systemTemp.createTemp('manage_storage_test_');
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  testWidgets('empty state renders both section headings + empty hints',
      (tester) async {
    await tester.pumpWidget(_harness(db: db, tempDir: tempDir));
    await tester.pumpAndSettle();

    expect(find.text('Recordings by night'), findsOneWidget);
    expect(find.text('Starred events'), findsOneWidget);
    expect(find.text('No recorded events yet.'), findsOneWidget);
    // The "no starred" hint copy starts with this prefix; using a
    // textContaining matcher avoids pinning the full sentence.
    expect(
      find.textContaining('No starred events'),
      findsOneWidget,
    );
    // Header card + "Used by recordings" label always present.
    expect(find.text('Used by recordings'), findsOneWidget);
  });

  testWidgets(
      'delete-all-unstarred soft-deletes only unstarred rows; undo restores',
      (tester) async {
    // One starred + two unstarred, all in the same night.
    final t = DateTime(2026, 5, 7, 22).millisecondsSinceEpoch;
    final starredId = await _insertReady(db, startedAt: t, starred: true);
    final unstarred1 =
        await _insertReady(db, startedAt: t + 60_000, starred: false);
    final unstarred2 =
        await _insertReady(db, startedAt: t + 120_000, starred: false);

    await tester.pumpWidget(_harness(db: db, tempDir: tempDir));
    // The snapshot provider does real `File.exists()` lookups against
    // tempDir. `runAsync` lets the IO complete; pumping after renders
    // the resolved snapshot. Multiple `runAsync` cycles handle the
    // chain (docsDir → repo.allReadyEvents → file stats → freeBytes
    // → snapshot data) where each link awaits the previous one.
    for (var i = 0; i < 4; i++) {
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pump(const Duration(milliseconds: 50));
    }

    // The card subtitle reports "1 starred / 2 unstarred".
    expect(find.textContaining('1 starred'), findsOneWidget);
    expect(find.textContaining('2 unstarred'), findsOneWidget);

    // Tap "Delete all unstarred" — confirmation dialog appears.
    await tester.tap(find.text('Delete all unstarred'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('Delete unstarred events?'), findsOneWidget);
    // Confirm. Manual `pump` cycles let the soft-delete + provider
    // invalidation + SnackBar appearance resolve, without blocking on
    // the SnackBar dismiss timer.
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    // The starred row is still there, both unstarred are tombstoned.
    final repo = ProviderScope.containerOf(
      tester.element(find.byType(ManageStorageScreen)),
    ).read(eventRepoProvider);
    final starredRow = await repo.getById(starredId);
    final unstarred1Row = await repo.getById(unstarred1);
    final unstarred2Row = await repo.getById(unstarred2);

    expect(starredRow!.deletedAt, isNull,
        reason: 'starred row MUST survive — the bulk action filters it out');
    expect(unstarred1Row!.deletedAt, isNotNull,
        reason: 'unstarred row should be soft-deleted');
    expect(unstarred2Row!.deletedAt, isNotNull,
        reason: 'unstarred row should be soft-deleted');

    // SnackBar appeared with Undo affordance.
    expect(find.textContaining('Deleted 2 events'), findsOneWidget);
    expect(find.text('Undo'), findsOneWidget);

    // Tap Undo — both unstarred rows' deletedAt clears.
    await tester.tap(find.text('Undo'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect((await repo.getById(unstarred1))!.deletedAt, isNull);
    expect((await repo.getById(unstarred2))!.deletedAt, isNull);
  });

  testWidgets('quota-failed banner appears when canRecord is false',
      (tester) async {
    await tester.pumpWidget(_harness(
      db: db,
      tempDir: tempDir,
      extraOverrides: [
        quotaResultProvider.overrideWith(
          (ref) async => const QuotaResult(
            canRecord: false,
            freeMb: 50,
            prunedCount: 0,
            blockReason: 'Low storage. Free space to continue.',
          ),
        ),
      ],
    ));
    await tester.pumpAndSettle();

    expect(find.text('Recording disabled'), findsOneWidget);
    expect(
      find.text('Low storage. Free space to continue.'),
      findsOneWidget,
    );
    expect(find.text('Free space now'), findsOneWidget);
  });

  testWidgets('starred event appears in the star-management list with Unstar',
      (tester) async {
    final t = DateTime(2026, 5, 7, 22).millisecondsSinceEpoch;
    final id = await _insertReady(db, startedAt: t, starred: true);

    await tester.pumpWidget(_harness(db: db, tempDir: tempDir));
    // Multiple alternating `runAsync` + `pump` cycles let the chained
    // futures resolve, each `runAsync` advancing real wall-clock so
    // `File.exists()` checks return, and each `pump` reacting to the
    // newly-arrived data.
    for (var i = 0; i < 4; i++) {
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pump(const Duration(milliseconds: 50));
    }

    // Sanity check: section heading is rendered, then scroll the
    // star-management section into the viewport.
    expect(find.text('Starred events'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Unstar'),
      200,
      scrollable: find.byType(Scrollable).first,
    );

    // The starred event shows up under "Starred events" with an
    // Unstar button.
    expect(find.text('Unstar'), findsOneWidget);

    await tester.tap(find.text('Unstar'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    final repo = ProviderScope.containerOf(
      tester.element(find.byType(ManageStorageScreen)),
    ).read(eventRepoProvider);
    expect((await repo.getById(id))!.starred, isFalse,
        reason: 'tap on Unstar must clear the starred flag');
  });
}
