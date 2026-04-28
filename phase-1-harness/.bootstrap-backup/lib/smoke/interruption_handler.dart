// THROWAWAY HARNESS - Phase 2 will rebuild this properly with the constants
// from lib/config/constants.dart.
//
// InterruptionHandler
//
// Subscribes to platform-specific interruption signals and writes GAP lines
// to the heartbeat log. Reasons:
//   - interruption_began
//   - interruption_ended_no_resume
//   - route_change
//   - service_killed
//
// iOS: native AppDelegate observes AVAudioSession interruption + route change
// notifications and forwards them on the MethodChannel
// `app.didisnorelastnight.smoke/audio`.
//
// Android: native MainActivity registers an OnAudioFocusChangeListener and
// forwards focus losses on the same MethodChannel name. AudioRecord errors
// are surfaced from the Dart side via the `record` package's stream onError.
// This handler accepts a programmatic `reportServiceKilled()` entry point
// the foreground-service watchdog uses when it detects the recorder isolate
// has died and has just been respawned.

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/services.dart';

import 'heartbeat.dart';

enum GapReason {
  interruptionBegan,
  interruptionEndedNoResume,
  routeChange,
  serviceKilled,
}

extension on GapReason {
  String get wireName {
    switch (this) {
      case GapReason.interruptionBegan:
        return 'interruption_began';
      case GapReason.interruptionEndedNoResume:
        return 'interruption_ended_no_resume';
      case GapReason.routeChange:
        return 'route_change';
      case GapReason.serviceKilled:
        return 'service_killed';
    }
  }
}

class InterruptionHandler {
  InterruptionHandler({required this.heartbeat, MethodChannel? channel})
      : _channel = channel ??
            const MethodChannel('app.didisnorelastnight.smoke/audio');

  final GapSink heartbeat;
  final MethodChannel _channel;

  // Open interruption windows: reason -> startEpochMs.
  // We accept overlap (interruption + route change at the same time); each
  // gets its own pending entry keyed by reason.
  final Map<GapReason, int> _open = {};

  bool _wired = false;

  void start() {
    if (_wired) return;
    _channel.setMethodCallHandler(_onCall);
    _wired = true;
  }

  void stop() {
    if (!_wired) return;
    // Close any open gap windows so the log never has a half-open entry.
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    for (final entry in _open.entries.toList()) {
      heartbeat.logGap(
        startEpochMs: entry.value,
        endEpochMs: nowMs,
        reason: entry.key.wireName,
      );
    }
    _open.clear();
    _channel.setMethodCallHandler(null);
    _wired = false;
  }

  /// Manual entry point — called when the foreground service detects that the
  /// recorder isolate was killed and has just been respawned. The window is
  /// from the last heartbeat to now (best the harness can estimate).
  Future<void> reportServiceKilled({
    required int startEpochMs,
    required int endEpochMs,
  }) async {
    await heartbeat.logGap(
      startEpochMs: startEpochMs,
      endEpochMs: endEpochMs,
      reason: GapReason.serviceKilled.wireName,
    );
  }

  Future<dynamic> _onCall(MethodCall call) async {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    switch (call.method) {
      case 'interruptionBegan':
        // iOS .began. Android: AUDIOFOCUS_LOSS / AUDIOFOCUS_LOSS_TRANSIENT.
        _open[GapReason.interruptionBegan] = nowMs;
        return null;

      case 'interruptionEnded':
        // Payload: { "shouldResume": bool }
        final args = (call.arguments as Map?) ?? const {};
        final shouldResume = args['shouldResume'] == true;
        final start = _open.remove(GapReason.interruptionBegan) ?? nowMs;
        if (shouldResume) {
          await heartbeat.logGap(
            startEpochMs: start,
            endEpochMs: nowMs,
            reason: GapReason.interruptionBegan.wireName,
          );
        } else {
          await heartbeat.logGap(
            startEpochMs: start,
            endEpochMs: nowMs,
            reason: GapReason.interruptionEndedNoResume.wireName,
          );
        }
        return null;

      case 'routeChangeBegan':
        _open[GapReason.routeChange] = nowMs;
        return null;

      case 'routeChangeEnded':
        final start = _open.remove(GapReason.routeChange) ?? nowMs;
        await heartbeat.logGap(
          startEpochMs: start,
          endEpochMs: nowMs,
          reason: GapReason.routeChange.wireName,
        );
        return null;

      // Convenience: native may emit a single instantaneous "route_change"
      // with start+end epochs already stamped (e.g. iOS gives us the
      // notification AFTER the route has stabilized).
      case 'routeChangedAt':
        final args = (call.arguments as Map?) ?? const {};
        final start = (args['startEpochMs'] as num?)?.toInt() ?? nowMs;
        final end = (args['endEpochMs'] as num?)?.toInt() ?? nowMs;
        await heartbeat.logGap(
          startEpochMs: start,
          endEpochMs: end,
          reason: GapReason.routeChange.wireName,
        );
        return null;

      default:
        return null;
    }
  }

  // ---- Platform debugging helpers ----

  /// True on platforms where this handler will receive native events.
  bool get nativeEventsAvailable => Platform.isIOS || Platform.isAndroid;
}
