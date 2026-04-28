// THROWAWAY HARNESS - Phase 2 will rebuild this properly with the constants
// from lib/config/constants.dart.
//
// RouteLogger
//
// On iOS, on every AVAudioSession activation we want the active input route
// name written to the heartbeat log. This catches the AirPods Pro A2DP-only
// state where iOS silently downgrades input to the built-in mic, or worse,
// falls back to HFP at 8 kHz mono.
//
// The native side (ios/Runner/AppDelegate.swift) emits a `routeActivated`
// event on the `app.didisnorelastnight.smoke/audio` MethodChannel with the
// active input port type + name. This Dart class plumbs those into the
// heartbeat log.
//
// On Android we do not have a direct equivalent; the foreground service plus
// `record` does the right thing. This file is a no-op on Android.

import 'dart:io' show Platform;

import 'package:flutter/services.dart';

import 'heartbeat.dart';

class RouteLogger {
  RouteLogger({required this.heartbeat, MethodChannel? channel})
      : _channel = channel ??
            const MethodChannel('app.didisnorelastnight.smoke/audio');

  final GapSink heartbeat;
  final MethodChannel _channel;

  bool _wired = false;

  String _lastRoute = '';
  String get lastRoute => _lastRoute;

  void start() {
    if (_wired) return;
    if (!Platform.isIOS) return; // Android: nothing to do here.
    _channel.setMethodCallHandler(_onCall);
    _wired = true;
    // Ask native to emit a routeActivated event for the current state.
    _channel.invokeMethod<void>('reportCurrentRoute');
  }

  void stop() {
    if (!_wired) return;
    if (!Platform.isIOS) return;
    _channel.setMethodCallHandler(null);
    _wired = false;
  }

  Future<dynamic> _onCall(MethodCall call) async {
    switch (call.method) {
      case 'routeActivated':
        // Expected payload (Map):
        //   { "portType": "MicrophoneBuiltIn", "portName": "iPhone Mic",
        //     "sampleRate": 48000.0, "channels": 1 }
        final args = (call.arguments as Map?) ?? const {};
        final portType = args['portType']?.toString() ?? 'unknown';
        final portName = args['portName']?.toString() ?? 'unknown';
        final sr = args['sampleRate']?.toString() ?? '?';
        final ch = args['channels']?.toString() ?? '?';
        _lastRoute = '$portType/$portName@${sr}Hz/${ch}ch';
        await heartbeat.logInfo('ios_input_route', _lastRoute);
        return null;
      default:
        return null;
    }
  }
}
