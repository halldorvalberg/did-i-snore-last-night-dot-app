/// Phase 7 — encode a single event's PCM into a `.opus` file via the
/// chosen ffmpeg fork (`ffmpeg_kit_flutter_new_audio`). Spec §7.1.
///
/// **Sequence (single source of truth, mirrors the comment in
/// `lib/data/event_repo.dart`):**
///
/// ```
///   1. EventRepo.insertPending(audioPath)  — Phase 6
///   2. Write <docsDir>/<audioPath>.tmp     — this layer (writes a
///      raw int16 PCM scratch file to systemTemp, then runs ffmpeg
///      with `-i <pcm> ... <out>.tmp`)
///   3. File.rename(<out>.tmp -> <out>)     — this layer
///   4. EventRepo.markReady(id, ...)        — encode_queue.dart
/// ```
///
/// **Atomic .tmp + rename is non-negotiable.** If we wrote directly to
/// `<final>.opus`, a crash mid-encode would leave a half-written file
/// that the orphan sweep would happily classify as a real event. The
/// `.tmp` suffix makes that case unambiguous: the pending sweep
/// (`lib/janitor/janitor.dart::sweepPending`) unlinks both `<audioPath>`
/// and `<audioPath>$tmpSuffix` whenever it tears down a stale pending
/// row, and the orphan sweep treats the `.tmp` extension as
/// keep-set-eligible only when paired with a current row.
///
/// **Idempotent on the rename step.** If the encoder is re-run with the
/// same `relPath` (e.g. process killed after the rename, restarted on
/// next boot — though that exact path is currently impossible because
/// PCM lives in memory), the second run overwrites its own `.tmp` and
/// `File.rename` atomically replaces the final file. We do NOT pre-check
/// for `<final>.opus` existence: Phase 6's ms-precision filename
/// (`<startedAt>.opus`) makes collisions a bug, and refusing-on-collision
/// would mask that bug instead of surfacing it.
///
/// **Constants discipline:** bitrate from `EncoderCfg.opusBitrateKbps`,
/// the `.tmp` suffix from `PathsCfg.tmpSuffix`. No inline `'24k'`,
/// no inline `'.tmp'`. The sample rate / channels in the ffmpeg cmd
/// come from `AudioCfg`.
///
/// **No PCM logging.** The transient scratch `.pcm` file is the encode
/// input; it is unconditionally cleaned up in `finally`, success or
/// failure.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:ffmpeg_kit_flutter_new_audio/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_audio/return_code.dart';
import 'package:path/path.dart' as p;

import '../config/constants.dart';

/// Encodes `pcm` (int16 mono 16 kHz, matching `AudioCfg`) to
/// `<docsDir>/<relPath>` via the `<...>.tmp` + rename pattern.
///
/// `relPath` MUST already end in `PathsCfg.audioExtension` (the caller —
/// `RecorderService._audioRelPathForEvent` in production — produces the
/// canonical `events/YYYY-MM-DD/<startedAt>.opus` shape). This function
/// never derives the path itself.
///
/// Returns the final `File` on success. Throws `StateError` on encode
/// failure; the caller (the encode queue) decides what to do — pending
/// sweep is the canonical recovery path, so the queue does NOT
/// soft-delete on encode failure.
///
/// The scratch `.pcm` file lives in `Directory.systemTemp` (transient
/// per process; the OS tears it down on next reboot if we crash before
/// `finally`). It is deleted in `finally` regardless of outcome.
Future<File> encodeEventToOpus({
  required Int16List pcm,
  required String relPath,
  required Directory docsDir,
}) async {
  final outPath = p.join(docsDir.path, relPath);
  final tmpOutPath = '$outPath${PathsCfg.tmpSuffix}';

  // Create the day-partition directory if missing. Spec §7.1 line 830.
  // `recursive: true` covers both the `events/` parent and the
  // `YYYY-MM-DD/` child in one call.
  await Directory(p.dirname(outPath)).create(recursive: true);

  // Write the raw int16 LE scratch file. We can't pipe PCM into ffmpeg
  // through stdin via FFmpegKit (the API takes a command string with
  // file arguments only), so a scratch file on disk is the canonical
  // approach. Lives in systemTemp, NOT the docs dir, so it is never
  // visible to the orphan sweep (which only walks `events/`).
  //
  // `Int16List.buffer.asUint8List(...)` exposes the PCM as raw bytes
  // without copying; on little-endian platforms (iOS arm64, Android
  // arm64-v8a/armeabi-v7a — every device we support) this matches the
  // `s16le` ffmpeg flag below.
  final scratch = await File(
    p.join(
      Directory.systemTemp.path,
      'dis_encode_${DateTime.now().microsecondsSinceEpoch}.pcm',
    ),
  ).create();
  final pcmBytes = pcm.buffer.asUint8List(
    pcm.offsetInBytes,
    pcm.lengthInBytes,
  );

  try {
    await scratch.writeAsBytes(pcmBytes, flush: true);

    // ffmpeg invocation per spec §7.1 line 833. Quote both paths defensively
    // — `outPath` includes `<docsDir>` which on Android is
    // `/data/user/0/<pkg>/app_flutter` (no spaces today, but the ffmpeg
    // CLI parser splits on unquoted whitespace). Quoting also handles
    // future macOS / desktop sandbox paths that DO contain spaces.
    //
    // `-application voip` per spec — Opus's voip profile favours
    // intelligibility over fidelity at low bitrates, which is the right
    // tradeoff for snore audio (we care about "what was it" more than
    // about reproducing the room ambience perfectly).
    //
    // Bitrate flag MUST come from `EncoderCfg.opusBitrateKbps` — see
    // library doc on constants discipline.
    final cmd = '-y '
        '-f s16le -ar ${AudioCfg.sampleRateHz} -ac ${AudioCfg.channels} '
        '-i "${scratch.path}" '
        '-c:a libopus -b:a ${EncoderCfg.opusBitrateKbps}k '
        '-application voip '
        '"$tmpOutPath"';

    final session = await FFmpegKit.execute(cmd);
    final rc = await session.getReturnCode();
    if (!ReturnCode.isSuccess(rc)) {
      // Failed encode: do NOT delete the .tmp file from this layer.
      // The encode queue's failure handler treats encode failure as
      // "leave the row pending; the pending sweep will tear down
      // everything in the 60-second grace window". Deleting the .tmp
      // here would be redundant and would race the sweep on a
      // restart-after-crash scenario.
      throw StateError(
        'opus encode failed: ffmpeg returned ${rc?.getValue()} for '
        '$tmpOutPath',
      );
    }

    // Atomic rename. On POSIX (Android, iOS) this is `rename(2)`, which
    // is atomic within the same filesystem. The `.tmp` and final file
    // are in the same day-partition directory, so they're guaranteed
    // same-filesystem.
    final finalFile = await File(tmpOutPath).rename(outPath);
    return finalFile;
  } finally {
    // Clean up the transient PCM scratch file unconditionally. Both
    // happy path and failure path land here — the file is never useful
    // to keep around (it's just int16 LE bytes we already had in RAM).
    if (await scratch.exists()) {
      try {
        await scratch.delete();
      } catch (_) {
        // Best-effort cleanup. If the OS won't let us delete (extremely
        // rare on app-private temp), the next reboot will. We must not
        // throw here — that would mask the real error from the encode
        // path above.
      }
    }
  }
}
