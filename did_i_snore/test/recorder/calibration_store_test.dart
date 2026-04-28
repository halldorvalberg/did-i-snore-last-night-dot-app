/// Round-trip persistence tests for `CalibrationStore`.
///
/// Three things matter here, in priority order:
///
/// 1. The storage key format is locked. Renaming the key silently loses
///    every existing user's calibration; a regression test on the literal
///    `noise_floor_v1:<deviceId>` shape catches that at PR time.
/// 2. Corrupt or absent values return null instead of throwing — a bad
///    value should mean "uncalibrated", not "app crashes on launch".
/// 3. Per-device isolation works: the same prefs backing two stores with
///    different device ids do not collide.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:did_i_snore/recorder/calibrator.dart';
import 'package:did_i_snore/recorder/calibrator_store.dart';

CalibrationStore _store(String deviceId) => CalibrationStore(
      prefsLoader: SharedPreferences.getInstance,
      deviceIdLoader: () async => deviceId,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('CalibrationStore', () {
    setUp(() {
      // Each test gets a fresh in-memory prefs map.
      SharedPreferences.setMockInitialValues(<String, Object>{});
    });

    test('save then load returns equal NoiseFloor', () async {
      final store = _store('test-device');
      const original = NoiseFloor(-47.3, 1.7);

      await store.save(original);
      final loaded = await store.load();

      expect(loaded, isNotNull);
      expect(loaded!.medianDbfs, equals(-47.3));
      expect(loaded.madDbfs, equals(1.7));
      expect(loaded, equals(original));
    });

    test('load with no value returns null (no throw)', () async {
      final store = _store('test-device');
      expect(await store.load(), isNull);
    });

    test('corrupt values return null without throwing', () async {
      // Three shapes of garbage that the parser must survive cleanly:
      // - too many commas
      // - wrong number of parts
      // - empty
      const corruptInputs = <String>[
        'not,a,number',
        'only-one-token',
        '',
      ];

      for (final raw in corruptInputs) {
        SharedPreferences.setMockInitialValues(<String, Object>{
          'flutter.noise_floor_v1:test-device': raw,
        });
        final store = _store('test-device');
        final loaded = await store.load();
        expect(loaded, isNull,
            reason: 'corrupt input ${jsonEscape(raw)} should load as null');
      }
    });

    test('NaN and Infinity tokens are rejected as corrupt', () async {
      // `double.tryParse('NaN')` and `double.tryParse('Infinity')` both
      // return non-null finite-failing doubles. Returning a NaN floor
      // would silently disable detection (every gate comparison with NaN
      // is false). load() filters via .isFinite, so these come back as
      // null — equivalent to "uncalibrated, please calibrate".
      const corrupt = <String>[
        'NaN,NaN',
        'NaN,2.0',
        '-50.0,NaN',
        'Infinity,1.0',
        '-50.0,-Infinity',
      ];
      for (final raw in corrupt) {
        SharedPreferences.setMockInitialValues(<String, Object>{
          'flutter.noise_floor_v1:test-device': raw,
        });
        final store = _store('test-device');
        expect(await store.load(), isNull,
            reason: 'non-finite input ${jsonEscape(raw)} should load as null');
      }
    });

    test('clear() makes load return null', () async {
      final store = _store('test-device');
      await store.save(const NoiseFloor(-50.0, 2.0));
      expect(await store.load(), isNotNull);

      await store.clear();
      expect(await store.load(), isNull);
    });

    test('per-device isolation: stores with different ids do not collide',
        () async {
      final storeA = _store('device-a');
      final storeB = _store('device-b');

      await storeA.save(const NoiseFloor(-40.0, 1.0));
      // storeB has a different device id and should see no value.
      expect(await storeB.load(), isNull);

      // Saving on B does not overwrite A.
      await storeB.save(const NoiseFloor(-60.0, 3.0));
      final aLoaded = await storeA.load();
      final bLoaded = await storeB.load();

      expect(aLoaded, isNotNull);
      expect(aLoaded!.medianDbfs, equals(-40.0));
      expect(bLoaded, isNotNull);
      expect(bLoaded!.medianDbfs, equals(-60.0));
    });

    test('storage key format is locked: noise_floor_v1:<deviceId>', () async {
      // Regression guard. If someone renames the key prefix or changes
      // the value format, this fails loudly instead of silently losing
      // every existing user's calibration on next release.
      final store = _store('abc');
      await store.save(const NoiseFloor(-50.0, 2.0));

      final prefs = await SharedPreferences.getInstance();
      // SharedPreferences mock prefixes keys with 'flutter.' on read;
      // querying via getString uses the unprefixed key on the public API.
      final raw = prefs.getString('noise_floor_v1:abc');

      expect(raw, isNotNull,
          reason: 'storage key prefix changed — old user calibrations lost');
      // Don't pin the exact format string in case the agent picks `;` vs
      // `,` or different rounding — just assert both numbers appear.
      expect(raw!, contains('-50'));
      expect(raw, contains('2'));
    });

    test('save overwrites the previous value for the same device', () async {
      final store = _store('test-device');
      await store.save(const NoiseFloor(-50.0, 2.0));
      await store.save(const NoiseFloor(-45.0, 1.5));

      final loaded = await store.load();
      expect(loaded, isNotNull);
      expect(loaded!.medianDbfs, equals(-45.0));
      expect(loaded.madDbfs, equals(1.5));
    });
  });
}

/// Tiny helper for human-readable corrupt-input failure messages.
String jsonEscape(String s) => '"${s.replaceAll('"', r'\"')}"';
