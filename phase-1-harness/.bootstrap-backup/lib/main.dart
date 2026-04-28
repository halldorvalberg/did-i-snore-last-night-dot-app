// THROWAWAY HARNESS - Phase 2 will rebuild this properly with the constants
// from lib/config/constants.dart.
//
// Single-screen smoke-test harness:
//   - Start / Stop button
//   - Elapsed time when running
//   - Last heartbeat: bytes-since-last-heartbeat + current segment file
//   - Active iOS input route (so the user can spot AirPods A2DP downgrades)
//
// Architecture:
//   - UI isolate: hosts MethodChannel `app.didisnorelastnight.smoke/audio`,
//     receives native interruption + route events, forwards them to the
//     service over the flutter_background_service event bus.
//   - Service (background) isolate: owns the mic stream, the segment writer,
//     and the heartbeat log. Subscribes to `gap` / `routeInfo` events from
//     the UI side and pipes them into the heartbeat writer.
//
// The MethodChannel cannot be registered on the service isolate because
// the native plugin registrar lives on the UI engine. This is a
// flutter_background_service limitation and the reason for the split.

import 'dart:async';
import 'dart:io' show Platform;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
// ignore: depend_on_referenced_packages
import 'package:flutter_background_service_android/flutter_background_service_android.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';

import 'smoke/heartbeat.dart';
import 'smoke/interruption_handler.dart';
import 'smoke/mic_writer.dart';
import 'smoke/route_logger.dart';

// ---- Service / notification identifiers ----

const String _notificationChannelId = 'smoke_recorder';
const String _notificationChannelName = 'Smoke recorder';
const int _notificationId = 1001;

// ---- Service <-> UI message protocol ----

const String _evtState = 'state';
const String _cmdStart = 'start';
const String _cmdStop = 'stop';
const String _cmdAppPaused = 'appPaused';
const String _cmdReportState = 'reportState';
// Gap forwarding from UI -> service. Payload:
//   { startEpochMs: int, endEpochMs: int, reason: string }
const String _cmdGap = 'gap';
// Route info forwarding from UI -> service. Payload:
//   { route: string }
const String _cmdRouteInfo = 'routeInfo';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const SmokeApp());
}

// ============================================================================
// App
// ============================================================================

class SmokeApp extends StatefulWidget {
  const SmokeApp({super.key});

  @override
  State<SmokeApp> createState() => _SmokeAppState();
}

class _SmokeAppState extends State<SmokeApp> with WidgetsBindingObserver {
  bool _initialized = false;

  // The interruption + route observers live on the UI isolate (only place
  // the native MethodChannel is wired). They translate native events into
  // messages on the background-service event bus.
  late final _UiSideAudioBridge _bridge;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _bridge = _UiSideAudioBridge();
    _initOnce();
  }

  @override
  void dispose() {
    _bridge.stop();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _initOnce() async {
    await _initializeBackgroundService();
    _bridge.start();
    if (mounted) {
      setState(() => _initialized = true);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      // Tell the service to force-flush its heartbeat buffer before we go
      // background. The service is the source of truth for the log file.
      FlutterBackgroundService().invoke(_cmdAppPaused);
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Phase 1 Harness',
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.indigo),
      home: _initialized
          ? const SmokeHome()
          : const Scaffold(body: Center(child: CircularProgressIndicator())),
    );
  }
}

// ============================================================================
// UI-side audio bridge
// ============================================================================
//
// Owns the InterruptionHandler + RouteLogger. Their HeartbeatWriter on this
// side is a thin shim that, instead of writing to disk, forwards the events
// it would have written to the background service over the event bus. The
// service-side heartbeat writer is the only thing that touches the log file.

class _UiSideAudioBridge {
  final _ForwardingHeartbeat _shim = _ForwardingHeartbeat();
  late final InterruptionHandler _interruptions =
      InterruptionHandler(heartbeat: _shim);
  late final RouteLogger _routes = RouteLogger(heartbeat: _shim);

  void start() {
    _interruptions.start();
    _routes.start();
  }

  void stop() {
    _interruptions.stop();
    _routes.stop();
  }
}

/// GapSink that forwards every gap/info call to the background service.
class _ForwardingHeartbeat implements GapSink {
  final FlutterBackgroundService _svc = FlutterBackgroundService();

  @override
  Future<void> logGap({
    required int startEpochMs,
    required int endEpochMs,
    required String reason,
  }) async {
    _svc.invoke(_cmdGap, {
      'startEpochMs': startEpochMs,
      'endEpochMs': endEpochMs,
      'reason': reason,
    });
  }

  @override
  Future<void> logInfo(String key, String value) async {
    if (key == 'ios_input_route') {
      _svc.invoke(_cmdRouteInfo, {'route': value});
    } else {
      _svc.invoke(_cmdRouteInfo, {'route': '$key=$value'});
    }
  }
}

// ============================================================================
// Home screen
// ============================================================================

class SmokeHome extends StatefulWidget {
  const SmokeHome({super.key});

  @override
  State<SmokeHome> createState() => _SmokeHomeState();
}

class _SmokeHomeState extends State<SmokeHome> {
  bool _running = false;
  DateTime? _startedAt;
  int _lastBytes = 0;
  int _totalBytes = 0;
  String _currentSegment = '';
  String _lastRoute = '';
  DateTime? _lastHeartbeatAt;

  Timer? _uiTicker;
  StreamSubscription<Map<String, dynamic>?>? _stateSub;

  @override
  void initState() {
    super.initState();
    _uiTicker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
    _stateSub =
        FlutterBackgroundService().on(_evtState).listen(_onServiceState);
    // Ask service for its current state on startup.
    FlutterBackgroundService().invoke(_cmdReportState);
  }

  @override
  void dispose() {
    _uiTicker?.cancel();
    _stateSub?.cancel();
    super.dispose();
  }

  void _onServiceState(Map<String, dynamic>? data) {
    if (data == null) return;
    setState(() {
      _running = data['running'] == true;
      final startedMs = data['startedAtMs'];
      _startedAt = (startedMs is int)
          ? DateTime.fromMillisecondsSinceEpoch(startedMs)
          : null;
      _lastBytes = (data['lastBytes'] as num?)?.toInt() ?? 0;
      _totalBytes = (data['totalBytes'] as num?)?.toInt() ?? 0;
      _currentSegment = data['currentSegment']?.toString() ?? '';
      _lastRoute = data['lastRoute']?.toString() ?? '';
      final hbMs = data['lastHeartbeatAtMs'];
      _lastHeartbeatAt = (hbMs is int)
          ? DateTime.fromMillisecondsSinceEpoch(hbMs)
          : null;
    });
  }

  Future<void> _start() async {
    final mic = await Permission.microphone.request();
    if (!mic.isGranted) {
      _toast('Microphone permission denied');
      return;
    }
    if (Platform.isAndroid) {
      // Android 13+: notification permission for the foreground-service
      // notification.
      await Permission.notification.request();
    }
    final svc = FlutterBackgroundService();
    final ok = await svc.startService();
    if (!ok) {
      _toast('Could not start background service');
      return;
    }
    svc.invoke(_cmdStart);
  }

  Future<void> _stop() async {
    final svc = FlutterBackgroundService();
    svc.invoke(_cmdStop);
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  String _fmtElapsed() {
    final s = _startedAt;
    if (s == null) return '--:--:--';
    final d = DateTime.now().difference(s);
    final h = d.inHours.toString().padLeft(2, '0');
    final m = (d.inMinutes % 60).toString().padLeft(2, '0');
    final sec = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$h:$m:$sec';
  }

  String _fmtBand() {
    // Expected per minute: 1,920,000 bytes (16k Hz * 2 bytes * 60).
    const expected = 1920000;
    if (_lastBytes <= 0) return '— (no heartbeat yet)';
    final pct = (_lastBytes / expected) * 100.0;
    final ok = pct >= 95.0 && pct <= 105.0;
    final tag = ok ? 'IN BAND' : 'OUT OF BAND';
    return '$_lastBytes B (${pct.toStringAsFixed(1)}% of expected) — $tag';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Phase 1 Smoke Test')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            FilledButton.icon(
              icon: Icon(_running ? Icons.stop : Icons.fiber_manual_record),
              label: Text(_running ? 'Stop' : 'Start'),
              onPressed: _running ? _stop : _start,
            ),
            const SizedBox(height: 24),
            _row('State', _running ? 'recording' : 'idle'),
            _row('Elapsed', _fmtElapsed()),
            _row('Last heartbeat',
                _lastHeartbeatAt?.toLocal().toIso8601String() ?? '—'),
            _row('Bytes since last heartbeat', _fmtBand()),
            _row('Total bytes written', '$_totalBytes'),
            _row('Current segment',
                _currentSegment.isEmpty ? '—' : _currentSegment),
            _row('iOS input route',
                _lastRoute.isEmpty ? (Platform.isIOS ? '—' : 'n/a') : _lastRoute),
            const SizedBox(height: 24),
            const Text(
              'Heartbeat log: <docs>/smoke/heartbeat.log\n'
              'Segments: <docs>/smoke/YYYY-MM-DD/HH-MM-SS.pcm',
              style: TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }

  Widget _row(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 200,
            child: Text(label,
                style: const TextStyle(fontWeight: FontWeight.w600)),
          ),
          Expanded(
            child: Text(value,
                style: const TextStyle(fontFamily: 'monospace')),
          ),
        ],
      ),
    );
  }
}

// ============================================================================
// Background service plumbing
// ============================================================================

Future<void> _initializeBackgroundService() async {
  final notif = FlutterLocalNotificationsPlugin();
  // Android side: create the notification channel for the foreground-service
  // notification. iOS does not need a channel.
  if (Platform.isAndroid) {
    final androidImpl = notif.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    await androidImpl?.createNotificationChannel(
      const AndroidNotificationChannel(
        _notificationChannelId,
        _notificationChannelName,
        description: 'Smoke test recording — tap to manage.',
        importance: Importance.low,
      ),
    );
  }

  final svc = FlutterBackgroundService();
  await svc.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: _onServiceStart,
      autoStart: false,
      isForegroundMode: true,
      notificationChannelId: _notificationChannelId,
      initialNotificationTitle: 'Smoke test recording',
      initialNotificationContent: 'Tap to manage.',
      foregroundServiceNotificationId: _notificationId,
      foregroundServiceTypes: [AndroidForegroundType.microphone],
    ),
    iosConfiguration: IosConfiguration(
      onForeground: _onServiceStart,
      onBackground: _iosOnBackground,
      autoStart: false,
    ),
  );
}

// Required iOS background callback. Returning true keeps the service alive.
@pragma('vm:entry-point')
bool _iosOnBackground(ServiceInstance service) {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  return true;
}

@pragma('vm:entry-point')
void _onServiceStart(ServiceInstance service) async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();

  final heartbeat = HeartbeatWriter();
  final mic = MicWriter(heartbeat: heartbeat);
  // Last route reported from the UI side, surfaced back to the UI in state
  // emissions so the home screen can display it.
  String lastRoute = '';

  DateTime? startedAt;

  Future<void> emitState() async {
    service.invoke(_evtState, {
      'running': mic.isRunning,
      'startedAtMs': startedAt?.millisecondsSinceEpoch,
      'lastBytes': heartbeat.lastBytesSinceLastHeartbeat,
      'totalBytes': heartbeat.lastTotalBytes,
      'currentSegment': mic.currentSegmentFile,
      'lastRoute': lastRoute,
      'lastHeartbeatAtMs':
          heartbeat.lastHeartbeatAt?.millisecondsSinceEpoch,
    });
  }

  Timer? uiPushTimer;

  service.on(_cmdStart).listen((_) async {
    if (mic.isRunning) return;
    try {
      await mic.start();
      await heartbeat.start();
      startedAt = DateTime.now();
      uiPushTimer ??=
          Timer.periodic(const Duration(seconds: 1), (_) => emitState());
      await emitState();
    } catch (e, st) {
      // ignore: avoid_print
      print('start failed: $e\n$st');
    }
  });

  service.on(_cmdStop).listen((_) async {
    try {
      await mic.stop();
      await heartbeat.stop();
    } finally {
      uiPushTimer?.cancel();
      uiPushTimer = null;
      startedAt = null;
      await emitState();
      // Stop the foreground service itself (Android) so we drop the
      // notification.
      if (service is AndroidServiceInstance) {
        await service.setAsBackgroundService();
      }
      await service.stopSelf();
    }
  });

  service.on(_cmdAppPaused).listen((_) async {
    await heartbeat.forceFlush();
  });

  service.on(_cmdReportState).listen((_) => emitState());

  // Forwarded gap events from the UI-side InterruptionHandler.
  service.on(_cmdGap).listen((data) async {
    if (data == null) return;
    final start = (data['startEpochMs'] as num?)?.toInt();
    final end = (data['endEpochMs'] as num?)?.toInt();
    final reason = data['reason']?.toString();
    if (start == null || end == null || reason == null) return;
    await heartbeat.logGap(
      startEpochMs: start,
      endEpochMs: end,
      reason: reason,
    );
  });

  // Forwarded route info from the UI-side RouteLogger.
  service.on(_cmdRouteInfo).listen((data) async {
    if (data == null) return;
    final route = data['route']?.toString();
    if (route == null) return;
    lastRoute = route;
    await heartbeat.logInfo('ios_input_route', route);
    await emitState();
  });
}
