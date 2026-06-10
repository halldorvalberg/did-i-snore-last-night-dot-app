/// State + providers backing the OEM onboarding flow (Phase 10.1).
///
/// Three concerns, all platform-aware and test-overridable:
///
/// 1. **"Seen" persistence** — a `did_i_snore.oem_onboarding_seen` bool in
///    SharedPreferences, so the first-launch gate shows the screen exactly
///    once. Re-opening it from Home (the re-accessible entry point) does not
///    require clearing this.
/// 2. **Device identity** — manufacturer + brand from `device_info_plus`,
///    used to key `oemStepsFor(...)`. On a non-Android host (the test
///    runner, iOS) this resolves to empty strings, so the screen degrades to
///    the universal battery step with no vendor cards.
/// 3. **A "should we surface it?" gate** — combines (1) with `Platform.isAndroid`
///    so the consent→home path on a non-Android test host is never
///    intercepted (the widget tests in `test/widget_test.dart` depend on
///    landing straight on Home).
library;

import 'dart:io' show Platform;

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// SharedPreferences key for "the user has been through (or dismissed) the
/// OEM onboarding once". Namespaced to match the project's other prefs keys.
const String oemOnboardingSeenKey = 'did_i_snore.oem_onboarding_seen';

/// Manufacturer + brand pair, lower-cased at the source so callers don't
/// each re-lowercase. Empty on non-Android platforms / test hosts.
class DeviceMake {
  const DeviceMake({required this.manufacturer, required this.brand});

  final String manufacturer;
  final String brand;

  static const DeviceMake unknown = DeviceMake(manufacturer: '', brand: '');
}

/// Resolves the device make via `device_info_plus`. Only meaningful on
/// Android; everywhere else (iOS, the Dart test VM) returns
/// [DeviceMake.unknown] so the onboarding screen shows just the universal
/// battery step. Never throws — a plugin failure degrades to unknown.
final deviceMakeProvider = FutureProvider<DeviceMake>((ref) async {
  if (!Platform.isAndroid) return DeviceMake.unknown;
  try {
    final info = await DeviceInfoPlugin().androidInfo;
    return DeviceMake(
      manufacturer: info.manufacturer,
      brand: info.brand,
    );
  } catch (_) {
    return DeviceMake.unknown;
  }
});

/// Controller for the "onboarding seen" pref. Mirrors the shape of
/// [ConsentController] (StateNotifier + async `_load`) so the first-launch
/// gate can switch on a tri-state without flashing the wrong screen for a
/// frame.
enum OnboardingSeen { unknown, no, yes }

class OemOnboardingController extends StateNotifier<OnboardingSeen> {
  OemOnboardingController() : super(OnboardingSeen.unknown) {
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final seen = prefs.getBool(oemOnboardingSeenKey) ?? false;
    state = seen ? OnboardingSeen.yes : OnboardingSeen.no;
  }

  /// Marks onboarding as seen (called from the screen's "Done" CTA) and
  /// persists it so the first-launch gate won't show it again.
  Future<void> markSeen() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(oemOnboardingSeenKey, true);
    state = OnboardingSeen.yes;
  }
}

final oemOnboardingSeenProvider =
    StateNotifierProvider<OemOnboardingController, OnboardingSeen>(
  (ref) => OemOnboardingController(),
);

/// True only when we should auto-surface the onboarding screen after consent
/// on first launch: Android, and the user hasn't seen it yet. On any
/// non-Android host this is `false`, so the consent→home path is untouched
/// and the existing widget tests land directly on Home.
final shouldShowOemOnboardingProvider = Provider<bool>((ref) {
  if (!Platform.isAndroid) return false;
  return ref.watch(oemOnboardingSeenProvider) == OnboardingSeen.no;
});
