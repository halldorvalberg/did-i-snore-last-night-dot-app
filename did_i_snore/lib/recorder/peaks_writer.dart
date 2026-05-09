/// Phase 8 enabling — peaks sidecar generation. Spec §6.4 lines 816–818.
///
/// Runs after a successful opus encode and before `EventRepo.markReady`,
/// from `lib/recorder/encode_queue.dart::_drain`. The output is a
/// `<rel>.peaks` file living next to its `.opus` sibling in the same
/// day-partition directory; the player reads it directly and renders the
/// waveform tile instantly.
///
/// **Format (single source of truth, mirrored from `PeaksCfg`):**
///
/// - `PeaksCfg.peakCount × float32 little-endian`, no header, no
///   trailer. Total bytes = `PeaksCfg.peakCount * 4` (800 today).
/// - Each value is `max(abs(s)) / 32768.0` over a slice of the input
///   PCM, in `[0.0, 1.0]`.
/// - Slice boundaries: peak `i` covers
///   `pcm[floor(i * pcmLen / peakCount) .. floor((i+1) * pcmLen / peakCount))`.
///   The count is **constant regardless of event duration**.
///
/// **Endianness:** Dart's `Float32List` is host-endian. Every device we
/// ship to (iOS arm64, Android arm64-v8a/armeabi-v7a) is little-endian,
/// matching the spec. If the project ever targets a big-endian platform
/// this writer must explicitly serialise via `ByteData.setFloat32` with
/// `Endian.little` — but today the host-endian fast path is correct.
///
/// **Atomic write.** Same `.tmp` + rename pattern as the opus encoder:
/// write to `<peaks>.peaks.tmp`, then `File.rename` to `<peaks>.peaks`.
/// The two files live in the same day-partition directory, so the rename
/// is same-filesystem atomic on POSIX.
///
/// **Failure policy.** Throws on any IO error. The caller (encode queue)
/// treats peaks failure as **non-fatal**: the opus file is already on
/// disk after a successful encode, so a missing peaks sidecar is a lost
/// convenience (the player falls back to a flat placeholder), not a
/// broken event. The queue logs `peaks_failed` and proceeds with
/// `peaksPath=null`.
///
/// **No PCM logging.** This module reads PCM, computes peaks, writes
/// peaks. It never logs raw samples. The thrown error surfaces only the
/// underlying IO message via `e.toString()` at the queue's call site.
///
/// **Constants discipline:** `PeaksCfg.peakCount`,
/// `PeaksCfg.peaksExtension`, `PathsCfg.audioExtension`,
/// `PathsCfg.tmpSuffix`. No inline `200`, `'.peaks'`, `800`, `'.tmp'`.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../config/constants.dart';

/// Computes `PeaksCfg.peakCount` peaks from int16 PCM and writes them
/// to a `.peaks` sidecar next to the event's `.opus` file via the
/// `<final>.peaks.tmp` + rename pattern.
///
/// `audioRelPath` MUST be of the canonical shape
/// `events/YYYY-MM-DD/<ts>${PathsCfg.audioExtension}`. The peaks path
/// is derived by replacing the `.opus` extension with
/// `PeaksCfg.peaksExtension` via `p.setExtension`, giving
/// `events/YYYY-MM-DD/<ts>${PeaksCfg.peaksExtension}`. The player
/// performs the same conversion at read time — single convention.
///
/// Returns the relative peaks path (same shape as `audioRelPath`, with
/// the extension swapped) for storing in the `peaks_path` column.
/// Throws on any IO failure (disk full, permissions, etc.); the caller
/// decides whether to surface or swallow.
///
/// Edge cases:
///
/// - `pcm.length < PeaksCfg.peakCount` should never happen in
///   production (`AudioCfg.minEventDurationMs` × 16 kHz = 8000 samples,
///   far above 200). If it does, peaks whose slice is empty are
///   written as `0.0` rather than crashing — defensive, not aspirational.
/// - `pcm.isEmpty` produces an all-zero peaks file. Same defensive
///   reasoning.
Future<String> writeEventPeaks({
  required Int16List pcm,
  required String audioRelPath,
  required Directory docsDir,
}) async {
  // Guard against silently mis-named sidecars. A caller passing
  // something that isn't an `.opus` path is a bug we want loud, not a
  // peaks file landing under a wrong extension.
  assert(
    audioRelPath.endsWith(PathsCfg.audioExtension),
    'audioRelPath must end in ${PathsCfg.audioExtension}, got: $audioRelPath',
  );

  final peaksRelPath =
      p.setExtension(audioRelPath, PeaksCfg.peaksExtension);
  final peaksAbsPath = p.join(docsDir.path, peaksRelPath);
  final tmpAbsPath = '$peaksAbsPath${PathsCfg.tmpSuffix}';

  // Compute peaks. Float32List is host-endian little-endian on every
  // device we ship to.
  final peaks = Float32List(PeaksCfg.peakCount);
  final pcmLen = pcm.length;
  if (pcmLen > 0) {
    for (var i = 0; i < PeaksCfg.peakCount; i++) {
      final startIdx = (i * pcmLen) ~/ PeaksCfg.peakCount;
      final endIdx = ((i + 1) * pcmLen) ~/ PeaksCfg.peakCount;
      if (endIdx <= startIdx) {
        // Slice is empty (only possible when pcmLen < peakCount, which
        // production won't hit). Leave as 0.0.
        continue;
      }
      var maxAbs = 0;
      for (var j = startIdx; j < endIdx; j++) {
        // `s.abs()` would overflow for `Int16List.minValue = -32768`
        // (since 32768 doesn't fit in int16, though Dart `int` is 64-bit
        // and tolerates it). We compare `-s` and `s` directly to avoid
        // any platform-specific surprise.
        final s = pcm[j];
        final a = s < 0 ? -s : s;
        if (a > maxAbs) maxAbs = a;
      }
      // 32768.0 is the int16 magnitude divisor; clamp at 1.0 in case
      // `maxAbs == 32768` (i.e. `s == -32768`).
      final norm = maxAbs / 32768.0;
      peaks[i] = norm > 1.0 ? 1.0 : norm;
    }
  }

  // The encoder's `Directory.create(recursive: true)` already created
  // the day-partition directory; we don't `mkdir` again.
  final bytes = peaks.buffer.asUint8List(
    peaks.offsetInBytes,
    peaks.lengthInBytes,
  );

  final tmpFile = File(tmpAbsPath);
  await tmpFile.writeAsBytes(bytes, flush: true);
  // Atomic rename. Same filesystem (same day-partition directory) so
  // rename(2) is atomic on POSIX. If a previous attempt left a stale
  // final file, rename overwrites it.
  await tmpFile.rename(peaksAbsPath);

  return peaksRelPath;
}
