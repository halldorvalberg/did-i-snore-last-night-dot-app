/// Widget smoke tests for `OemOnboardingScreen`.
///
/// The pure OEM→steps mapping is covered exhaustively in
/// `oem_steps_test.dart`; here we only assert the screen renders that
/// mapping without throwing, reflects the battery-whitelist status, and that
/// the "Open settings" deep-link is routed through the injected [OemChannel].
///
/// We don't touch the real platform channels: permission_handler's method
/// channel is stubbed to "denied" (so the action button shows), and the
/// OEM deep-link channel is swapped for a fake that records the call.
/// `device_info_plus` is overridden at the provider level via
/// `deviceMakeProvider`, so no native call happens.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:did_i_snore/ui/setup/oem_channel.dart';
import 'package:did_i_snore/ui/setup/oem_onboarding.dart';
import 'package:did_i_snore/ui/setup/oem_onboarding_state.dart';

/// permission_handler's platform method channel.
const _permissionChannel =
    MethodChannel('flutter.baseflow.com/permissions/methods');

/// Stubs the whitelist probe to [granted] (1 = granted, 0 = denied on the
/// platform-interface PermissionStatus enum).
void _stubPermissions({required bool granted}) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_permissionChannel, (call) async {
    switch (call.method) {
      case 'checkPermissionStatus':
        return granted ? 1 : 0;
      case 'requestPermissions':
        return <int, int>{0: granted ? 1 : 0};
      default:
        return null;
    }
  });
}

void _clearPermissions() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_permissionChannel, null);
}

/// Fake deep-link channel that records the keys it was asked to open. We
/// subclass with a fixed dummy MethodChannel that is never invoked because
/// every method is overridden.
class _FakeOemChannel extends OemChannel {
  _FakeOemChannel() : super(const MethodChannel('test/oem'));

  final List<String?> opened = [];

  @override
  Future<OemSettingsResult> openOemSettings(String? settingsKey) async {
    opened.add(settingsKey);
    return OemSettingsResult.oem;
  }
}

Widget _wrap(Widget child, {List<Override> overrides = const []}) {
  return ProviderScope(
    overrides: overrides,
    child: MaterialApp(home: child),
  );
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(_clearPermissions);

  testWidgets('renders the universal step and a Nothing vendor card', (t) async {
    _stubPermissions(granted: false);
    final fake = _FakeOemChannel();

    await t.pumpWidget(_wrap(
      OemOnboardingScreen(oemChannel: fake),
      overrides: [
        deviceMakeProvider.overrideWith(
          (ref) async => const DeviceMake(
              manufacturer: 'Nothing', brand: 'Nothing'),
        ),
      ],
    ));
    await t.pump(); // resolve device-make future + permission status
    await t.pump();

    // Intro + universal step present.
    expect(find.text('Allow unrestricted background activity'), findsOneWidget);
    expect(find.text('Allow background activity'), findsOneWidget);

    // Vendor card for the reference device.
    expect(find.text('Nothing OS — app battery management'), findsOneWidget);
    expect(find.text('Open settings'), findsWidgets);
    expect(find.text('Done — back to recording'), findsOneWidget);
  });

  testWidgets('granted battery whitelist shows the Done pill, hides the button',
      (t) async {
    _stubPermissions(granted: true);

    await t.pumpWidget(_wrap(
      const OemOnboardingScreen(),
      overrides: [
        deviceMakeProvider.overrideWith(
          (ref) async => const DeviceMake(manufacturer: 'Google', brand: 'Pixel'),
        ),
      ],
    ));
    await t.pump();
    await t.pump();

    // Granted → the "Done" pill is shown and the action button is gone.
    expect(find.text('Done'), findsOneWidget);
    expect(find.text('Allow background activity'), findsNothing);
    // Stock OEM → no vendor cards, just the universal step.
    expect(find.text('Open settings'), findsNothing);
  });

  testWidgets('Open settings routes the vendor key through the channel',
      (t) async {
    _stubPermissions(granted: true);
    final fake = _FakeOemChannel();

    await t.pumpWidget(_wrap(
      OemOnboardingScreen(oemChannel: fake),
      overrides: [
        deviceMakeProvider.overrideWith(
          (ref) async =>
              const DeviceMake(manufacturer: 'Xiaomi', brand: 'Redmi'),
        ),
      ],
    ));
    await t.pump();
    await t.pump();

    final openBtn = find.text('Open settings').first;
    await t.ensureVisible(openBtn);
    await t.pump();
    await t.tap(openBtn);
    await t.pump();
    await t.pump();

    expect(fake.opened, ['xiaomi']);
  });

  testWidgets('Done marks onboarding seen and pops', (t) async {
    _stubPermissions(granted: true);

    final nav = GlobalKey<NavigatorState>();
    await t.pumpWidget(ProviderScope(
      overrides: [
        deviceMakeProvider.overrideWith(
          (ref) async => const DeviceMake(manufacturer: 'Google', brand: 'Pixel'),
        ),
      ],
      child: MaterialApp(
        navigatorKey: nav,
        home: const _LauncherPad(),
      ),
    ));
    await t.pump();

    // Push the onboarding so there's something to pop.
    nav.currentState!.push(MaterialPageRoute(
      builder: (_) => const OemOnboardingScreen(),
    ));
    await t.pump();
    await t.pump();

    await t.tap(find.text('Done — back to recording'));
    await t.pump();
    await t.pump();

    // Popped back to the launcher pad.
    expect(find.text('pad'), findsOneWidget);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(oemOnboardingSeenKey), isTrue);
  });
}

/// Minimal home stand-in to pop back to.
class _LauncherPad extends StatelessWidget {
  const _LauncherPad();

  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: Center(child: Text('pad')));
}
