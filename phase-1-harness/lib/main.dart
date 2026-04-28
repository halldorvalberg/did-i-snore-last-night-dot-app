// THROWAWAY HARNESS - thin Dart shell that drives the native recorder.
//
// All recording, foreground-service plumbing, and heartbeat logging runs
// in Kotlin (RecorderService.kt). This file is just:
//   - mic + notification permission gates,
//   - Start / Stop button,
//   - state polling so the UI shows what the service is doing.
//
// Phase 2 will replace the entire harness with the production recorder
// pipeline at lib/recorder/, also Kotlin-backed.

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

const _channelName = 'app.didisnorelastnight.smoke/audio';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const SmokeApp());
}

class SmokeApp extends StatelessWidget {
  const SmokeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Phase 1 Harness',
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.indigo),
      home: const SmokeHome(),
    );
  }
}

class SmokeHome extends StatefulWidget {
  const SmokeHome({super.key});

  @override
  State<SmokeHome> createState() => _SmokeHomeState();
}

class _SmokeHomeState extends State<SmokeHome> {
  static const _channel = MethodChannel(_channelName);

  bool _running = false;
  DateTime? _startedAt;
  int _lastBytes = 0;
  int _totalBytes = 0;
  String _currentSegment = '';
  DateTime? _lastHeartbeatAt;

  Timer? _pollTimer;

  @override
  void initState() {
    super.initState();
    _channel.setMethodCallHandler(_onNativeCall);
    // Poll the native state every second. We don't push because the
    // native side has no Dart engine binding outside this activity.
    _pollTimer = Timer.periodic(const Duration(seconds: 1), (_) => _poll());
    _poll();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _channel.setMethodCallHandler(null);
    super.dispose();
  }

  Future<dynamic> _onNativeCall(MethodCall call) async {
    // We don't need to do anything with interruptionBegan / Ended for
    // the harness; the native recorder is independent of the Activity's
    // audio focus. Logging via debugPrint is enough for now.
    debugPrint('native: ${call.method} ${call.arguments}');
    return null;
  }

  Future<void> _poll() async {
    try {
      final res = await _channel.invokeMethod<Map<dynamic, dynamic>>('getState');
      if (res == null || !mounted) return;
      setState(() {
        _running = res['running'] == true;
        final startedMs = res['sessionStartedAtMs'];
        _startedAt = (startedMs is int && startedMs > 0)
            ? DateTime.fromMillisecondsSinceEpoch(startedMs)
            : null;
        _totalBytes = (res['totalBytes'] as num?)?.toInt() ?? 0;
        _lastBytes = (res['lastHeartbeatBytes'] as num?)?.toInt() ?? 0;
        _currentSegment = res['currentSegmentFile']?.toString() ?? '';
        final hbMs = res['lastHeartbeatAtMs'];
        _lastHeartbeatAt = (hbMs is int && hbMs > 0)
            ? DateTime.fromMillisecondsSinceEpoch(hbMs)
            : null;
      });
    } catch (e) {
      // Channel may not be wired up yet on first frame.
      debugPrint('poll failed: $e');
    }
  }

  Future<void> _start() async {
    final mic = await Permission.microphone.request();
    if (!mic.isGranted) {
      _toast('Microphone permission denied');
      return;
    }
    if (Platform.isAndroid) {
      await Permission.notification.request();
    }
    try {
      await _channel.invokeMethod<bool>('start');
    } on PlatformException catch (e) {
      _toast('Start failed: ${e.message}');
    }
  }

  Future<void> _stop() async {
    try {
      await _channel.invokeMethod<bool>('stop');
    } on PlatformException catch (e) {
      _toast('Stop failed: ${e.message}');
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
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
            const SizedBox(height: 24),
            const Text(
              'Heartbeat log: <docs>/smoke/heartbeat.log\n'
              'Segments: <docs>/smoke/YYYY-MM-DD/HH-MM-SS.pcm\n'
              '(Recording runs in native RecorderService — survives '
              'backgrounding.)',
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
