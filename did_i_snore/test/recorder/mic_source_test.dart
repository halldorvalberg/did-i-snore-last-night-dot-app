/// Contract tests for `MicSource`.
///
/// `record` 6.x does not ship a documented in-process fake, and we cannot
/// open a real microphone in unit tests. Coverage here is limited to what's
/// observable by stubbing the `com.llfbandit.record/messages` method
/// channel:
///
/// - Constructor doesn't throw (record's `AudioRecorder` reaches the
///   platform channel during construction; we stub it).
/// - `pcm16` is a `Stream<Uint8List>` and is broadcast (multiple listeners
///   are allowed).
/// - `stop()` is idempotent and safe before `start()`.
///
/// The full capture path — `start()` → platform mic → `pcm16` chunks →
/// `stop()` cleanup — is covered by the manual smoke procedure in
/// MANUAL_TEST.md (Phase 2). TODO(test): add a hardware-in-the-loop
/// integration test once `record` exposes a fake or we wire one through
/// the platform_interface.
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:did_i_snore/recorder/mic_source.dart';

/// Method-channel name used by `record` 6.x. Pinned in
/// `record_platform_interface/src/record_method_channel_mixin.dart`.
const _recordChannel = MethodChannel('com.llfbandit.record/messages');

/// Generic stub that swallows every call from `record` and returns null.
/// `MicSource` only invokes `create` (constructor) and `stop` in the tests
/// here; both are happy with a null reply.
void _stubRecordChannel() {
  TestWidgetsFlutterBinding.ensureInitialized();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_recordChannel, (call) async => null);
}

void _clearStub() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_recordChannel, null);
}

void main() {
  setUp(_stubRecordChannel);
  tearDown(_clearStub);

  group('MicSource', () {
    test('constructor does not throw', () {
      expect(() => MicSource(), returnsNormally);
    });

    test('pcm16 is a broadcast stream — multiple listeners are allowed', () {
      final mic = MicSource();
      expect(mic.pcm16.isBroadcast, isTrue);

      // Two concurrent listeners must not throw on subscribe.
      final subA = mic.pcm16.listen((_) {});
      final subB = mic.pcm16.listen((_) {});

      expect(subA, isNotNull);
      expect(subB, isNotNull);

      // Cleanup so the test process can exit cleanly.
      subA.cancel();
      subB.cancel();
    });

    test('pcm16 yields Uint8List events (type contract)', () {
      // We can't deliver real audio, but the static type of `pcm16` should
      // be `Stream<Uint8List>`. Pinning this in a test catches accidental
      // generic widening (e.g. to `Stream<List<int>>`) at compile time.
      final mic = MicSource();
      final Stream<Uint8List> typed = mic.pcm16;
      expect(typed, isA<Stream<Uint8List>>());
    });

    test('stop() before start() does not throw', () async {
      final mic = MicSource();
      await expectLater(mic.stop(), completes);
    });

    test('stop() is idempotent: calling twice does not throw', () async {
      final mic = MicSource();
      await mic.stop();
      await expectLater(mic.stop(), completes);
    });
  });
}
