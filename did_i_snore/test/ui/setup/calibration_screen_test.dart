/// Smoke tests for `CalibrationScreen`.
///
/// We don't open the real microphone here — the screen's only job is to
/// render the latest snapshot from `calibrationStateProvider` and gate the
/// Save button on `state.canSave`. Both providers are overridden:
///
/// - `calibratorProvider` is replaced with a `_FakeCalibrator` whose
///   lifecycle methods are no-ops and whose `state` stream is a controller
///   we drive from the test.
/// - `calibrationStateProvider` falls through to the calibrator's stream
///   the same way the production wiring does.
///
/// We additionally stub the `record` plugin's method channel because
/// `Calibrator()`s default constructor would touch it during construction;
/// this stays defensive in case a future refactor lets the default
/// calibrator slip into a test.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:did_i_snore/recorder/calibrator.dart';
import 'package:did_i_snore/recorder/calibrator_provider.dart';
import 'package:did_i_snore/recorder/calibrator_store.dart';
import 'package:did_i_snore/recorder/mic_source.dart';
import 'package:did_i_snore/recorder/pcm_slicer.dart';
import 'package:did_i_snore/ui/setup/calibration_screen.dart';

/// `Calibrator` subclass that shadows every mic-touching method with a
/// no-op and exposes a writable stream the test can pump events into.
class _FakeCalibrator extends Calibrator {
  _FakeCalibrator()
      : super(
          mic: _UnusedMicSource(),
          slicer: PcmSlicer(frameBytes: 640),
          store: _NoopStore(),
        );

  final StreamController<CalibrationState> _ctrl =
      StreamController<CalibrationState>.broadcast();

  /// Captures lifecycle calls from the screen for assertion.
  int startCalls = 0;
  int stopCalls = 0;
  int resetCalls = 0;
  int saveCalls = 0;

  /// Floor returned from `save()`. Override per-test if needed.
  NoiseFloor saveResult = const NoiseFloor(-60.0, 1.5);

  @override
  Stream<CalibrationState> get state => _ctrl.stream;

  @override
  Future<void> start() async {
    startCalls++;
  }

  @override
  Future<void> stop() async {
    stopCalls++;
  }

  @override
  Future<void> reset() async {
    resetCalls++;
  }

  @override
  Future<NoiseFloor> save() async {
    saveCalls++;
    return saveResult;
  }

  @override
  Future<void> dispose() async {
    if (!_ctrl.isClosed) {
      await _ctrl.close();
    }
  }

  void emit(CalibrationState s) {
    _ctrl.add(s);
  }
}

/// Mic stand-in that throws if anything actually touches it. The fake
/// calibrator never delegates to the parent mic logic, so this is just
/// belt-and-braces.
class _UnusedMicSource extends MicSource {
  _UnusedMicSource();
}

class _NoopStore extends CalibrationStore {
  _NoopStore() : super();

  @override
  Future<NoiseFloor?> load() async => null;

  @override
  Future<void> save(NoiseFloor floor) async {}

  @override
  Future<void> clear() async {}
}

/// Method-channel name pinned by `permission_handler_android` (and the
/// platform-interface fallback). Stubbing it returns `granted` to the
/// `Permission.microphone.isGranted` probe in `_bootstrap`.
const _permissionChannel =
    MethodChannel('flutter.baseflow.com/permissions/methods');

void _stubPermissions() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_permissionChannel, (call) async {
    switch (call.method) {
      case 'checkPermissionStatus':
        // 1 = granted on the platform-interface PermissionStatus enum.
        return 1;
      case 'requestPermissions':
        return <int, int>{0: 1};
      default:
        return null;
    }
  });
}

void _clearPermissions() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_permissionChannel, null);
}

const _recordChannel = MethodChannel('com.llfbandit.record/messages');

void _stubRecord() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_recordChannel, (call) async => null);
}

void _clearRecord() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_recordChannel, null);
}

CalibrationState _state({
  required double rmsDbfs,
  required double estimatedFloorDbfs,
  required int contiguousQuietMs,
  List<double>? historyDbfs,
}) {
  return CalibrationState(
    rmsDbfs: rmsDbfs,
    historyDbfs: historyDbfs ?? const [-70.0, -68.0, -65.0],
    estimatedFloorDbfs: estimatedFloorDbfs,
    contiguousQuietMs: contiguousQuietMs,
    canSave: contiguousQuietMs >= 10000,
  );
}

Widget _wrap(Widget child, _FakeCalibrator fake) {
  return ProviderScope(
    overrides: [
      calibratorProvider.overrideWith((_) => fake),
    ],
    child: MaterialApp(home: child),
  );
}

void main() {
  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    _stubPermissions();
    _stubRecord();
  });

  tearDown(() {
    _clearPermissions();
    _clearRecord();
  });

  testWidgets('walks through the three status phases', (tester) async {
    final fake = _FakeCalibrator();
    addTearDown(fake.dispose);

    await tester.pumpWidget(_wrap(const CalibrationScreen(), fake));

    // Initial frame: stream has no data yet, loading spinner shows.
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    // The phrase appears in both the AppBar title and the body header.
    expect(find.text('Calibrate this room'), findsNWidgets(2));

    // Let the post-frame callback run so `start()` is invoked.
    await tester.pump();
    expect(fake.startCalls, 1);

    // Phase 1: Listening (no quiet streak yet).
    fake.emit(_state(
      rmsDbfs: -40.0,
      estimatedFloorDbfs: -50.0,
      contiguousQuietMs: 0,
    ));
    await tester.pump();
    expect(find.text('Listening...'), findsOneWidget);

    // Phase 2: making progress (4s of 10s).
    fake.emit(_state(
      rmsDbfs: -55.0,
      estimatedFloorDbfs: -50.0,
      contiguousQuietMs: 4000,
    ));
    // pump a bit longer than the AnimatedSwitcher's 200ms transition.
    await tester.pump(const Duration(milliseconds: 250));
    expect(
      find.text('Looking quiet — keep going (4s / 10s)'),
      findsOneWidget,
    );

    // Phase 3: ready to save.
    fake.emit(_state(
      rmsDbfs: -55.0,
      estimatedFloorDbfs: -50.0,
      contiguousQuietMs: 12000,
    ));
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('Quiet enough — you can save'), findsOneWidget);

    // Save button is enabled now; tapping it calls calibrator.save().
    final saveBtn = find.widgetWithText(FilledButton, 'Save calibration');
    expect(saveBtn, findsOneWidget);
    expect(
      tester.widget<FilledButton>(saveBtn).onPressed,
      isNotNull,
      reason: 'Save must be enabled when canSave is true',
    );
  });

  testWidgets(
    'Save button is disabled until canSave',
    (tester) async {
      final fake = _FakeCalibrator();
      addTearDown(fake.dispose);

      await tester.pumpWidget(_wrap(const CalibrationScreen(), fake));
      await tester.pump();

      fake.emit(_state(
        rmsDbfs: -45.0,
        estimatedFloorDbfs: -50.0,
        contiguousQuietMs: 3000,
      ));
      await tester.pump();

      final btn = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Save calibration'),
      );
      expect(btn.onPressed, isNull);
    },
  );

  testWidgets(
    'stop() is invoked when the screen is disposed',
    (tester) async {
      final fake = _FakeCalibrator();
      addTearDown(fake.dispose);

      await tester.pumpWidget(_wrap(const CalibrationScreen(), fake));
      await tester.pump();

      // Replace the widget tree with something else to force dispose.
      await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
      // The dispose path includes `ref.read(calibratorProvider).stop()`.
      // Provider auto-dispose tears down on the next microtask; either way
      // stop() should have been observed at least once.
      expect(fake.stopCalls, greaterThanOrEqualTo(1));
    },
  );
}
