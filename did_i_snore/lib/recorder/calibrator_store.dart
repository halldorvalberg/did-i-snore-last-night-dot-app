/// Persistence for the calibrated [NoiseFloor]. Per-device, in
/// `shared_preferences`, keyed by a stable `device_info_plus` id.
///
/// Per-device because the calibration depends on the *microphone* — the
/// same user on a different phone has a different floor. Persisting in
/// `shared_preferences` (vs. the Drift DB) is deliberate: this value is
/// needed before the recorder isolate boots, and SP is synchronous after
/// the first warm-up. The DB layer (Phase 6) is for events.
///
/// Storage shape:
///   key:   `noise_floor_v1:<deviceId>`
///   value: `"<medianDbfs>,<madDbfs>"`
///
/// Two doubles, one comma — no JSON dependency for two floats. The `v1`
/// prefix lets a future change to the math (e.g. switching to MADN, or
/// adding spectral context) coexist with old data via a new key prefix.
library;

import 'package:device_info_plus/device_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'calibrator.dart' show NoiseFloor;

/// Storage key prefix; bump on incompatible value-format changes.
const String _keyPrefix = 'noise_floor_v1:';

/// Falls back here if `device_info_plus` returns `null` or fails — better
/// than crashing the app on a device that doesn't expose an id. The user
/// can recalibrate per-install in that case.
const String _fallbackDeviceId = 'unknown';

/// Loads / saves a per-device [NoiseFloor] via `shared_preferences`.
class CalibrationStore {
  /// Allows tests to inject a mock prefs / fixed device id without
  /// dragging in plugin platform channels.
  final Future<SharedPreferences> Function() _prefs;
  final Future<String> Function() _deviceId;

  CalibrationStore({
    Future<SharedPreferences> Function()? prefsLoader,
    Future<String> Function()? deviceIdLoader,
  })  : _prefs = prefsLoader ?? SharedPreferences.getInstance,
        _deviceId = deviceIdLoader ?? _resolveDeviceId;

  /// Returns the persisted floor for this device, or null if there is none.
  /// Returns null on parse failure too — a corrupt value is equivalent to
  /// "uncalibrated, please calibrate".
  Future<NoiseFloor?> load() async {
    final prefs = await _prefs();
    final id = await _deviceId();
    final raw = prefs.getString('$_keyPrefix$id');
    if (raw == null) return null;
    final parts = raw.split(',');
    if (parts.length != 2) return null;
    final median = double.tryParse(parts[0]);
    final mad = double.tryParse(parts[1]);
    if (median == null || mad == null) return null;
    // double.tryParse accepts the literal strings "NaN" and "Infinity" —
    // returning a NaN floor would silently disable threshold-based
    // detection because every comparison with NaN is false. Reject those
    // and any other non-finite values; the user gets re-prompted to
    // calibrate, which is the correct recovery from corrupt persistence.
    if (!median.isFinite || !mad.isFinite) return null;
    return NoiseFloor(median, mad);
  }

  /// Persists [floor] for this device. Overwrites any previous value.
  Future<void> save(NoiseFloor floor) async {
    final prefs = await _prefs();
    final id = await _deviceId();
    await prefs.setString(
      '$_keyPrefix$id',
      '${floor.medianDbfs},${floor.madDbfs}',
    );
  }

  /// Removes the persisted floor for this device. Used by the "Recalibrate"
  /// settings action.
  Future<void> clear() async {
    final prefs = await _prefs();
    final id = await _deviceId();
    await prefs.remove('$_keyPrefix$id');
  }
}

/// Resolves a stable per-device id via `device_info_plus`.
///
/// Android: `androidInfo.id` — derived from build/serial; stable across
///   launches but not across factory resets. Fine for calibration.
/// iOS: `iosInfo.identifierForVendor` — Apple's recommended app-scoped id;
///   resets when all the vendor's apps are uninstalled.
///
/// We deliberately do NOT use `androidInfo.serialNumber` (requires
/// `READ_PHONE_STATE` on older API levels) or any IMEI-class identifier.
Future<String> _resolveDeviceId() async {
  try {
    final plugin = DeviceInfoPlugin();
    // device_info_plus 10.x exposes platform-specific getters and a
    // top-level `deviceInfo` aggregator. We branch on the concrete type
    // returned to keep the logic platform-aware without `Platform.isX`
    // in pure-Dart tests.
    final info = await plugin.deviceInfo;
    final data = info.data;
    // Android: 'id' key; iOS: 'identifierForVendor'.
    final id = data['id'] as String? ??
        data['identifierForVendor'] as String? ??
        _fallbackDeviceId;
    return id.isEmpty ? _fallbackDeviceId : id;
  } catch (_) {
    return _fallbackDeviceId;
  }
}
