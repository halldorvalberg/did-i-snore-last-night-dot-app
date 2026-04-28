/// Riverpod glue for the calibration screen.
///
/// The [Calibrator] class itself stays Riverpod-free — these providers
/// are the seam where the UI binds to it. Keep this file thin: anything
/// that's not a `Provider` or `StreamProvider` belongs in `calibrator.dart`.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'calibrator.dart';
import 'calibrator_store.dart';

/// The [CalibrationStore] singleton. Test code overrides this with a mock
/// using `ProviderScope(overrides: ...)`.
final calibrationStoreProvider = Provider<CalibrationStore>((ref) {
  return CalibrationStore();
});

/// The interactive [Calibrator] for the calibration screen. Auto-disposed
/// so leaving the screen tears down the mic; the screen widget should
/// keep this provider alive only while it's mounted.
final calibratorProvider = Provider.autoDispose<Calibrator>((ref) {
  final store = ref.watch(calibrationStoreProvider);
  final calibrator = Calibrator(store: store);
  ref.onDispose(() {
    // Fire-and-forget — Provider disposal is sync, but the calibrator's
    // teardown is async. Awaiting in onDispose is not supported; the mic
    // plugin handles concurrent stop() calls gracefully.
    calibrator.dispose();
  });
  return calibrator;
});

/// Live calibration state stream for the UI to render at ~10 Hz.
///
/// Note that this provider does NOT call `start()` on the calibrator —
/// the screen widget is responsible for the start/stop lifecycle so that
/// pushing a sub-route or backgrounding the screen can pause the mic
/// without rebuilding the calibrator itself.
final calibrationStateProvider = StreamProvider.autoDispose<CalibrationState>(
  (ref) {
    final calibrator = ref.watch(calibratorProvider);
    return calibrator.state;
  },
);

/// Currently persisted [NoiseFloor] for this device, if any. Used by the
/// home screen to decide whether to show "Calibrate" or "Recalibrate" and
/// by the recorder to know whether it can start.
final persistedNoiseFloorProvider = FutureProvider<NoiseFloor?>((ref) async {
  final store = ref.watch(calibrationStoreProvider);
  return store.load();
});
