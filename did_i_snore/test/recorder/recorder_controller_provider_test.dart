/// Smoke test for `RecorderController`.
///
/// We don't construct a `RecorderService` (that touches the real mic
/// plugin); instead we verify the controller's branching logic for the
/// pre-flight calibration check. The interesting case is "no
/// persisted noise floor → start() bails with an errorMessage and
/// does NOT flip to recording" — this is the gate the home screen's
/// `Calibrate first` SnackBar relies on.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:did_i_snore/recorder/calibrator.dart';
import 'package:did_i_snore/recorder/calibrator_provider.dart';
import 'package:did_i_snore/recorder/recorder_controller_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('start() with no calibration sets errorMessage and stays idle',
      () async {
    final container = ProviderContainer(
      overrides: [
        // Force the persisted-floor future to resolve to null — i.e.
        // calibration has never been run.
        persistedNoiseFloorProvider.overrideWith((ref) async => null),
      ],
    );
    addTearDown(container.dispose);

    // Resolve the persisted floor before invoking the controller, so
    // valueOrNull is non-loading by the time start() reads it.
    expect(await container.read(persistedNoiseFloorProvider.future), isNull);

    final controller =
        container.read(recorderControllerProvider.notifier);
    await controller.start();

    final state = container.read(recorderControllerProvider);
    expect(state.isRecording, isFalse,
        reason: 'no calibration must keep us out of recording');
    expect(state.errorMessage, isNotNull,
        reason: 'errorMessage should surface a reason');
    expect(state.errorMessage, contains('Calibrate'),
        reason: 'message should mention calibration so the SnackBar makes sense');
  });

  test('clearError() nulls the message', () async {
    final container = ProviderContainer(
      overrides: [
        persistedNoiseFloorProvider.overrideWith((ref) async => null),
      ],
    );
    addTearDown(container.dispose);

    await container.read(persistedNoiseFloorProvider.future);
    final controller =
        container.read(recorderControllerProvider.notifier);
    await controller.start();
    expect(container.read(recorderControllerProvider).errorMessage,
        isNotNull);

    controller.clearError();
    expect(container.read(recorderControllerProvider).errorMessage, isNull);
  });

  test('stop() with no active session is a no-op', () async {
    final container = ProviderContainer(
      overrides: [
        persistedNoiseFloorProvider
            .overrideWith((ref) async => const NoiseFloor(-60.0, 1.5)),
      ],
    );
    addTearDown(container.dispose);

    await container.read(persistedNoiseFloorProvider.future);
    final controller =
        container.read(recorderControllerProvider.notifier);
    // Without ever calling start(), stop() should return immediately.
    await controller.stop();
    final state = container.read(recorderControllerProvider);
    expect(state.isRecording, isFalse);
    expect(state.errorMessage, isNull);
  });
}
