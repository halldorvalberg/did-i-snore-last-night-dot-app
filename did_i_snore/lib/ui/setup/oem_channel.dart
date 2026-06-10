/// Dart side of the OEM-settings deep-link channel (Phase 10.1).
///
/// Thin wrapper over the native `app.didisnorelastnight/oem` MethodChannel
/// handled in `MainActivity.kt` → `OemSettings.kt`. The native side tries
/// the vendor autostart/battery activity for the given `settingsKey` and
/// always falls back to this app's app-details screen, so this call never
/// throws on a missing OEM activity — at worst it opens a generic settings
/// page.
///
/// Note the separation of concerns: the **battery-optimization whitelist
/// request** (the system "allow unrestricted background activity?" dialog)
/// is NOT here — it goes through `permission_handler`'s
/// `Permission.ignoreBatteryOptimizations`. This channel only opens the
/// vendor autostart screens, which have no permission_handler equivalent.
library;

import 'package:flutter/services.dart';

/// Which screen the native side actually managed to open, surfaced so the
/// UI can tell the user whether they landed on the precise vendor screen or
/// a generic fallback.
enum OemSettingsResult {
  /// Opened the vendor-specific autostart/battery activity.
  oem,

  /// Fell back to this app's app-details page (links onward to battery).
  appDetails,

  /// Fell back to the global battery-optimization list.
  batterySettings,

  /// Nothing resolved (extraordinarily unlikely) — or the platform is not
  /// Android. The UI should rely on its on-screen written steps.
  none,
}

class OemChannel {
  const OemChannel([this._channel = _defaultChannel]);

  static const MethodChannel _defaultChannel =
      MethodChannel('app.didisnorelastnight/oem');

  final MethodChannel _channel;

  /// Asks the platform to open the best settings screen for [settingsKey]
  /// (the `OemStep.settingsKey` from `oem_steps.dart`). Returns which screen
  /// was opened. Swallows `MissingPluginException` / `PlatformException`
  /// (e.g. on a non-Android host or test) and returns [OemSettingsResult.none]
  /// rather than throwing into the widget tree.
  Future<OemSettingsResult> openOemSettings(String? settingsKey) async {
    try {
      final opened = await _channel.invokeMethod<String>(
        'openOemSettings',
        {'brand': settingsKey},
      );
      return switch (opened) {
        'oem' => OemSettingsResult.oem,
        'app-details' => OemSettingsResult.appDetails,
        'battery-settings' => OemSettingsResult.batterySettings,
        _ => OemSettingsResult.none,
      };
    } on MissingPluginException {
      return OemSettingsResult.none;
    } on PlatformException {
      return OemSettingsResult.none;
    }
  }
}
