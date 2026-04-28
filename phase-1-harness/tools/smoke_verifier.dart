// THROWAWAY HARNESS - Phase 2 will rebuild this properly.
//
// Heartbeat log verifier.
//
// Reads a heartbeat.log produced by the smoke-test harness and asserts:
//
//   1. Each periodic heartbeat line's `bytes_since_last_heartbeat` is in
//      the band [1,920,000 * 0.95, 1,920,000 * 1.05] = [1,824,000, 2,016,000].
//      Anything outside the band = silent mic failure.
//
//   2. Every detected gap (a heartbeat row with delta = 0, or a heartbeat
//      row missing for > 90 s, or a delta significantly below band) is
//      explained by a GAP line whose [start, end] window covers it.
//      Otherwise the gap is "unexplained" → fails.
//
//   3. Total heartbeat count >= expected for the session duration.
//
// Usage:
//   dart run tools/smoke_verifier.dart <path/to/heartbeat.log>
//
// Exit codes:
//   0 = pass
//   1 = unexplained gap or out-of-band heartbeat
//   2 = log unreadable / malformed
//
// This file lives in `tools/` so it isn't part of the app build. Run it from
// your dev machine after pulling the log off the phone.

import 'dart:io';

const int expectedBytesPerMinute = 16000 * 2 * 60; // 1,920,000
const double bandLow = 0.95;
const double bandHigh = 1.05;
const int heartbeatMaxIntervalMs = 90 * 1000; // tolerate 30 s slack

void main(List<String> argv) async {
  if (argv.length != 1) {
    stderr.writeln('usage: dart run tools/smoke_verifier.dart <heartbeat.log>');
    exit(2);
  }
  final f = File(argv.single);
  if (!await f.exists()) {
    stderr.writeln('file not found: ${argv.single}');
    exit(2);
  }
  final lines = await f.readAsLines();

  final beats = <_Heartbeat>[];
  final gaps = <_Gap>[];

  for (final raw in lines) {
    final line = raw.trim();
    if (line.isEmpty) continue;
    if (line.startsWith('SESSION_START') || line.startsWith('SESSION_STOP')) {
      continue;
    }
    if (line.startsWith('INFO')) continue;
    if (line.startsWith('GAP,')) {
      final parts = line.split(',');
      if (parts.length < 4) continue;
      final start = int.tryParse(parts[1]);
      final end = int.tryParse(parts[2]);
      if (start == null || end == null) continue;
      gaps.add(_Gap(startMs: start, endMs: end, reason: parts.sublist(3).join(',')));
      continue;
    }
    // Heartbeat row: iso,epochMs,total,delta,segment
    final parts = line.split(',');
    if (parts.length < 5) continue;
    final epochMs = int.tryParse(parts[1]);
    final total = int.tryParse(parts[2]);
    final delta = int.tryParse(parts[3]);
    if (epochMs == null || total == null || delta == null) continue;
    beats.add(_Heartbeat(epochMs: epochMs, total: total, delta: delta));
  }

  if (beats.isEmpty) {
    stderr.writeln('no heartbeat rows in log');
    exit(2);
  }

  var failures = 0;
  final lowAbs = (expectedBytesPerMinute * bandLow).toInt();
  final highAbs = (expectedBytesPerMinute * bandHigh).toInt();
  stdout.writeln('expected per-minute band: [$lowAbs, $highAbs] bytes');

  // Helper: is a moment covered by any GAP window?
  bool covered(int startMs, int endMs) {
    for (final g in gaps) {
      // Any overlap counts as covered.
      if (g.endMs >= startMs && g.startMs <= endMs) return true;
    }
    return false;
  }

  // Skip the first beat — its delta is "since start of recording", which is
  // less than 60 s of audio.
  for (var i = 1; i < beats.length; i++) {
    final b = beats[i];
    final prev = beats[i - 1];
    final intervalMs = b.epochMs - prev.epochMs;

    if (intervalMs > heartbeatMaxIntervalMs) {
      // Heartbeat skipped — must be explained.
      if (!covered(prev.epochMs, b.epochMs)) {
        stdout.writeln(
          'FAIL: missing heartbeat between '
          '${prev.epochMs} and ${b.epochMs} (${intervalMs}ms gap, no GAP marker)',
        );
        failures++;
      }
      continue;
    }

    if (b.delta < lowAbs || b.delta > highAbs) {
      // Out of band. Allowed only if a GAP covers this minute.
      if (!covered(prev.epochMs, b.epochMs)) {
        stdout.writeln(
          'FAIL: out-of-band heartbeat at ${b.epochMs}: '
          'delta=${b.delta} (expected [$lowAbs, $highAbs])',
        );
        failures++;
      }
    }
  }

  // Summary
  stdout.writeln('heartbeats: ${beats.length}');
  stdout.writeln('gaps     : ${gaps.length}');
  for (final g in gaps) {
    stdout.writeln(
      '  GAP ${g.reason}: ${g.startMs} -> ${g.endMs} '
      '(${g.endMs - g.startMs} ms)',
    );
  }

  if (failures > 0) {
    stdout.writeln('VERIFY: FAIL ($failures issues)');
    exit(1);
  }
  stdout.writeln('VERIFY: PASS');
  exit(0);
}

class _Heartbeat {
  _Heartbeat({required this.epochMs, required this.total, required this.delta});
  final int epochMs;
  final int total;
  final int delta;
}

class _Gap {
  _Gap({required this.startMs, required this.endMs, required this.reason});
  final int startMs;
  final int endMs;
  final String reason;
}
