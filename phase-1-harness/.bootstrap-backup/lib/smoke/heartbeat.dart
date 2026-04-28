// THROWAWAY HARNESS - Phase 2 will rebuild this properly with the constants
// from lib/config/constants.dart.
//
// Heartbeat writer. Every 60 seconds, append one CSV line to
// `<applicationDocumentsDirectory>/smoke/heartbeat.log`:
//
//   <iso8601_ts>,<epoch_ms>,<total_bytes_written>,<bytes_since_last_heartbeat>,<current_segment_file>
//
// Also handles GAP lines:
//
//   GAP,<start_epoch_ms>,<end_epoch_ms>,<reason>
//
// Buffer in memory; one fsync/min, not per-byte. Force flush on stop() and on
// AppLifecycleState.paused.

import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Narrow interface for "something that can record gap and info events."
/// Implemented by [HeartbeatWriter] (the real disk-backed log on the
/// background-service isolate) and by the UI-side forwarding shim that
/// just relays events to the service over the event bus.
abstract class GapSink {
  Future<void> logGap({
    required int startEpochMs,
    required int endEpochMs,
    required String reason,
  });
  Future<void> logInfo(String key, String value);
}

class HeartbeatWriter implements GapSink {
  HeartbeatWriter();

  // Bytes counter set by the mic writer. We don't own the mic pipeline; we
  // just sample the counter once a minute.
  int Function() _totalBytesProvider = () => 0;
  String Function() _currentSegmentFileProvider = () => '';

  int _lastTotalBytes = 0;

  Timer? _tickTimer;
  File? _logFile;

  // In-memory buffer of pending lines. Flushed to disk once per heartbeat tick
  // and on stop() / AppLifecycleState.paused.
  final List<String> _buffer = <String>[];

  /// Wire up the providers the writer reads at each tick. Called once by
  /// MicWriter at start.
  void bind({
    required int Function() totalBytesProvider,
    required String Function() currentSegmentFileProvider,
  }) {
    _totalBytesProvider = totalBytesProvider;
    _currentSegmentFileProvider = currentSegmentFileProvider;
  }

  /// Resolve the heartbeat log path under <docs>/smoke/heartbeat.log.
  /// Creates the directory if missing.
  Future<File> _resolveLogFile() async {
    if (_logFile != null) return _logFile!;
    final dir = await getApplicationDocumentsDirectory();
    final smokeDir = Directory(p.join(dir.path, 'smoke'));
    if (!await smokeDir.exists()) {
      await smokeDir.create(recursive: true);
    }
    final f = File(p.join(smokeDir.path, 'heartbeat.log'));
    _logFile = f;
    return f;
  }

  /// Start the 60s timer. Idempotent: calling start twice is a no-op.
  Future<void> start() async {
    if (_tickTimer != null) return;
    await _resolveLogFile();
    _lastTotalBytes = _totalBytesProvider();
    _tickTimer = Timer.periodic(const Duration(seconds: 60), (_) => _tick());
    // Append a session-start marker line so the verifier can find boundaries.
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    _buffer.add('SESSION_START,$nowMs,${DateTime.now().toIso8601String()}');
    await _flush();
  }

  /// Stop the timer and force-flush the buffer.
  Future<void> stop() async {
    _tickTimer?.cancel();
    _tickTimer = null;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    _buffer.add('SESSION_STOP,$nowMs,${DateTime.now().toIso8601String()}');
    await _flush();
  }

  /// Force the in-memory buffer to disk. Call on AppLifecycleState.paused.
  Future<void> forceFlush() async {
    await _flush();
  }

  /// Append a GAP line. Reasons:
  ///   interruption_began, interruption_ended_no_resume, route_change, service_killed
  @override
  Future<void> logGap({
    required int startEpochMs,
    required int endEpochMs,
    required String reason,
  }) async {
    _buffer.add('GAP,$startEpochMs,$endEpochMs,$reason');
    // Gaps are load-bearing; flush immediately rather than wait for the tick.
    await _flush();
  }

  /// Append an arbitrary informational line (e.g. the active iOS input route).
  /// Format: INFO,<epoch_ms>,<key>,<value>
  @override
  Future<void> logInfo(String key, String value) async {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    _buffer.add('INFO,$nowMs,$key,$value');
    await _flush();
  }

  // Last latched value, for the UI to display "last bytes/heartbeat".
  int lastBytesSinceLastHeartbeat = 0;
  int lastTotalBytes = 0;
  String lastCurrentSegmentFile = '';
  DateTime? lastHeartbeatAt;

  Future<void> _tick() async {
    final nowIso = DateTime.now().toIso8601String();
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final total = _totalBytesProvider();
    final delta = total - _lastTotalBytes;
    _lastTotalBytes = total;

    final currentFile = _currentSegmentFileProvider();
    _buffer.add('$nowIso,$nowMs,$total,$delta,$currentFile');

    lastBytesSinceLastHeartbeat = delta;
    lastTotalBytes = total;
    lastCurrentSegmentFile = currentFile;
    lastHeartbeatAt = DateTime.now();

    await _flush();
  }

  Future<void> _flush() async {
    if (_buffer.isEmpty) return;
    final f = await _resolveLogFile();
    final lines = _buffer.join('\n');
    _buffer.clear();
    // FileMode.append + writeAsString fsyncs on close; this is the
    // "one fsync per minute" the spec calls for.
    await f.writeAsString('$lines\n', mode: FileMode.append, flush: true);
  }
}
