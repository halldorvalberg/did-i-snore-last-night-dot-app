/// Full-screen audio player.
///
/// Spec: `docs/IMPLEMENTATION.md` §8 line 889. Renders the pre-computed
/// peaks waveform (NOT the full audio), provides transport controls,
/// star toggle, manual relabel, and soft-delete with undo. Audio
/// playback via `just_audio` — Opus-in-Ogg is supported by the
/// platform decoders just_audio wraps (ExoPlayer on Android, AVPlayer
/// on iOS), so we never transcode at playback time.
///
/// **Waveform from peaks file, not full audio.** The peaks sidecar is
/// `PeaksCfg.peakCount` × float32 LE = 800 bytes per event. Decoding
/// the full Opus to render a waveform would burn the device for every
/// tap; the peaks file is the whole reason the encoder writes one
/// (spec §6.4). When `event.peaksPath == null` (older events from
/// before Phase 7 retrofit) the player shows a flat placeholder and
/// proportional seek still works.
///
/// **Star toggle is in the AppBar.** Manual relabel and soft-delete
/// live in the body so they don't compete for the AppBar real estate
/// once the player gets fancier (Phase 10 settings).
///
/// **Soft-delete with undo.** `softDelete` then pop the player; the
/// timeline screen catches the SnackBar via the standard
/// `ScaffoldMessenger`. Undo calls the repo's `undelete` (added in
/// Phase 8). Material default snack auto-dismisses ~5 s — well inside
/// the 1-day `hardDeleteAfterDays` window so undo never races a hard
/// delete.
///
/// **No JSON parsing in build paths.** The relabel dropdown reads
/// `LabelMap.yamnetToCurated.values.toSet()` for its options; the
/// display label uses `displayLabel(event)` (which itself reads
/// `topLabel` directly).
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';

import '../../classifier/label_map.dart';
import '../../config/constants.dart';
import '../../data/db.dart' show Event;
import '../providers.dart';
import '../timeline/display_label.dart';

class PlayerScreen extends ConsumerStatefulWidget {
  const PlayerScreen({super.key, required this.event});

  final Event event;

  @override
  ConsumerState<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends ConsumerState<PlayerScreen> {
  late AudioPlayer _player;

  /// Peaks loaded from `peaksPath`. Null while loading or on failure;
  /// the painter falls back to a flat placeholder in either case.
  List<double>? _peaks;

  /// Local snapshot of the row we're playing. Updated when the user
  /// stars/unstars or changes the label so the screen reflects edits
  /// without waiting for the upstream stream emit. The timeline
  /// listens to its own stream, so it sees the same edits independently.
  late Event _event;

  bool _peaksLoaded = false;

  @override
  void initState() {
    super.initState();
    _event = widget.event;
    _player = AudioPlayer();
    // Fire-and-forget; we surface load errors via SnackBar but don't
    // block the build.
    _initialise();
  }

  Future<void> _initialise() async {
    try {
      final docsDir = await ref.read(docsDirProvider.future);
      final audioAbsPath = '${docsDir.path}/${_event.audioPath}';
      await _player.setFilePath(audioAbsPath);
      if (_event.peaksPath != null) {
        await _loadPeaks('${docsDir.path}/${_event.peaksPath}');
      }
      if (mounted) setState(() => _peaksLoaded = true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not load audio: $e')),
      );
    }
  }

  Future<void> _loadPeaks(String absPath) async {
    try {
      final f = File(absPath);
      if (!await f.exists()) return;
      final bytes = await f.readAsBytes();
      final expectedLen = PeaksCfg.peakCount * 4;
      if (bytes.lengthInBytes < expectedLen) return;
      final floats = Float32List.view(
        bytes.buffer,
        bytes.offsetInBytes,
        PeaksCfg.peakCount,
      );
      _peaks = List<double>.from(floats);
    } catch (_) {
      // Stay null; placeholder rendered.
    }
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  Future<void> _toggleStar() async {
    final repo = ref.read(eventRepoProvider);
    final next = !_event.starred;
    setState(() => _event = _withStar(_event, next));
    await repo.setStarred(_event.id, next);
  }

  Future<void> _setLabel(String? label) async {
    final repo = ref.read(eventRepoProvider);
    setState(() => _event = _withUserLabel(_event, label));
    await repo.setUserLabel(_event.id, label);
  }

  Future<void> _softDeleteAndPop() async {
    final repo = ref.read(eventRepoProvider);
    final id = _event.id;
    await repo.softDelete(id);
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    Navigator.of(context).pop();
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: const Text('Event deleted'),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () async {
            await repo.undelete(id);
          },
        ),
      ),
    );
  }

  void _seekProportional(double fraction) {
    final dur = _player.duration;
    if (dur == null) return;
    final ms = (dur.inMilliseconds * fraction.clamp(0.0, 1.0)).round();
    _player.seek(Duration(milliseconds: ms));
  }

  Future<void> _skip(Duration delta) async {
    final pos = _player.position;
    final dur = _player.duration ?? Duration.zero;
    var target = pos + delta;
    if (target < Duration.zero) target = Duration.zero;
    if (target > dur) target = dur;
    await _player.seek(target);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(displayLabel(_event)),
        actions: [
          IconButton(
            icon: Icon(_event.starred ? Icons.star : Icons.star_border),
            tooltip: _event.starred ? 'Unstar' : 'Star',
            onPressed: _toggleStar,
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Delete',
            onPressed: _softDeleteAndPop,
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Waveform region — flexible so it expands on tall
              // screens and shrinks on short ones without breaking
              // the transport controls below.
              Expanded(
                flex: 2,
                child: StreamBuilder<Duration>(
                  stream: _player.positionStream,
                  builder: (ctx, snap) {
                    final pos = snap.data ?? Duration.zero;
                    final dur =
                        _player.duration ?? const Duration(milliseconds: 1);
                    final fraction = dur.inMilliseconds == 0
                        ? 0.0
                        : pos.inMilliseconds / dur.inMilliseconds;
                    return GestureDetector(
                      onTapDown: (details) {
                        final box = ctx.findRenderObject() as RenderBox?;
                        if (box == null) return;
                        final localX =
                            details.localPosition.dx / box.size.width;
                        _seekProportional(localX);
                      },
                      child: CustomPaint(
                        painter: _WaveformPainter(
                          peaks: _peaks,
                          progress: fraction.clamp(0.0, 1.0),
                          barColor: theme.colorScheme.primary,
                          baseColor: theme.colorScheme.outlineVariant,
                          progressColor: theme.colorScheme.tertiary,
                        ),
                        child: const SizedBox.expand(),
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 12),
              if (!_peaksLoaded)
                Text(
                  'Loading audio…',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  textAlign: TextAlign.center,
                )
              else if (_event.peaksPath == null)
                Text(
                  'No waveform available',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  textAlign: TextAlign.center,
                ),

              const SizedBox(height: 16),

              // Position scrubber (linear progress + duration text).
              StreamBuilder<Duration>(
                stream: _player.positionStream,
                builder: (ctx, snap) {
                  final pos = snap.data ?? Duration.zero;
                  final dur = _player.duration ?? Duration.zero;
                  return Column(
                    children: [
                      Slider(
                        value: dur.inMilliseconds == 0
                            ? 0.0
                            : pos.inMilliseconds /
                                dur.inMilliseconds.clamp(1, 1 << 30),
                        onChanged: (v) => _seekProportional(v),
                      ),
                      Padding(
                        padding:
                            const EdgeInsets.symmetric(horizontal: 16),
                        child: Row(
                          mainAxisAlignment:
                              MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              _formatPosition(pos),
                              style: theme.textTheme.bodySmall,
                            ),
                            Text(
                              _formatPosition(dur),
                              style: theme.textTheme.bodySmall,
                            ),
                          ],
                        ),
                      ),
                    ],
                  );
                },
              ),

              const SizedBox(height: 8),

              // Transport row: -10, play/pause, +10.
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    iconSize: 36,
                    icon: const Icon(Icons.replay_10),
                    onPressed: () => _skip(const Duration(seconds: -10)),
                  ),
                  const SizedBox(width: 8),
                  StreamBuilder<PlayerState>(
                    stream: _player.playerStateStream,
                    builder: (ctx, snap) {
                      final state = snap.data;
                      final playing = state?.playing ?? false;
                      final processing =
                          state?.processingState ?? ProcessingState.idle;
                      final isCompleted =
                          processing == ProcessingState.completed;
                      return FilledButton.icon(
                        style: FilledButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 24,
                            vertical: 16,
                          ),
                        ),
                        icon: Icon(
                          playing ? Icons.pause : Icons.play_arrow,
                          size: 28,
                        ),
                        label: Text(
                          playing ? 'Pause' : (isCompleted ? 'Replay' : 'Play'),
                        ),
                        onPressed: () async {
                          if (playing) {
                            await _player.pause();
                          } else {
                            if (isCompleted) {
                              await _player.seek(Duration.zero);
                            }
                            await _player.play();
                          }
                        },
                      );
                    },
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    iconSize: 36,
                    icon: const Icon(Icons.forward_10),
                    onPressed: () => _skip(const Duration(seconds: 10)),
                  ),
                ],
              ),

              const SizedBox(height: 24),

              // Manual relabel — curated buckets only. Spec line 889.
              _RelabelDropdown(
                current: _event.userLabel ?? _event.topLabel,
                onChanged: _setLabel,
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _formatPosition(Duration d) {
    final m = d.inMinutes.toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }
}

/// Manual-relabel dropdown. Reads its option set from
/// `LabelMap.yamnetToCurated.values.toSet()` so the v1 curated buckets
/// are the single source of truth. Spec hard-requirement: no inline
/// curated label strings.
class _RelabelDropdown extends StatelessWidget {
  const _RelabelDropdown({
    required this.current,
    required this.onChanged,
  });

  final String? current;
  final void Function(String?) onChanged;

  @override
  Widget build(BuildContext context) {
    final options = <String>{
      ...LabelMap.yamnetToCurated.values,
      'Other',
    }.toList()..sort();
    final value = options.contains(current) ? current : null;
    return Row(
      children: [
        const Icon(Icons.label_outline),
        const SizedBox(width: 12),
        Expanded(
          child: DropdownButtonFormField<String>(
            initialValue: value,
            decoration: const InputDecoration(
              labelText: 'Label',
              border: OutlineInputBorder(),
            ),
            items: [
              const DropdownMenuItem<String>(
                value: null,
                child: Text('(use auto-detected)'),
              ),
              for (final o in options)
                DropdownMenuItem<String>(value: o, child: Text(o)),
            ],
            onChanged: onChanged,
          ),
        ),
      ],
    );
  }
}

class _WaveformPainter extends CustomPainter {
  _WaveformPainter({
    required this.peaks,
    required this.progress,
    required this.barColor,
    required this.baseColor,
    required this.progressColor,
  });

  final List<double>? peaks;
  final double progress;
  final Color barColor;
  final Color baseColor;
  final Color progressColor;

  @override
  void paint(Canvas canvas, Size size) {
    if (peaks == null) {
      // Flat placeholder: a single horizontal line.
      final p = Paint()
        ..color = baseColor
        ..strokeWidth = 1.5;
      final y = size.height / 2;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), p);
    } else {
      final n = peaks!.length;
      final barWidth = size.width / n;
      final paint = Paint()
        ..strokeWidth = (barWidth * 0.6).clamp(1.0, 4.0)
        ..strokeCap = StrokeCap.round;
      final centreY = size.height / 2;
      for (var i = 0; i < n; i++) {
        final h = (peaks![i] * size.height).clamp(2.0, size.height);
        final x = (i + 0.5) * barWidth;
        paint.color = (i / n) <= progress ? progressColor : barColor;
        canvas.drawLine(
          Offset(x, centreY - h / 2),
          Offset(x, centreY + h / 2),
          paint,
        );
      }
    }
    // Progress cursor.
    final cursorPaint = Paint()
      ..color = progressColor
      ..strokeWidth = 2.0;
    final cursorX = (progress.clamp(0.0, 1.0)) * size.width;
    canvas.drawLine(
      Offset(cursorX, 0),
      Offset(cursorX, size.height),
      cursorPaint,
    );
  }

  @override
  bool shouldRepaint(covariant _WaveformPainter old) =>
      old.peaks != peaks ||
      old.progress != progress ||
      old.barColor != barColor ||
      old.baseColor != baseColor ||
      old.progressColor != progressColor;
}

// ---- private helpers --------------------------------------------------

/// Drift's generated row class is final-fields, no copyWith. We need to
/// reflect star/label edits locally without round-tripping through the
/// stream. Cheap to hand-build — the row has 14 columns.
Event _withStar(Event e, bool starred) => Event(
      id: e.id,
      startedAt: e.startedAt,
      endedAt: e.endedAt,
      durationMs: e.durationMs,
      createdAt: e.createdAt,
      schemaVersion: e.schemaVersion,
      state: e.state,
      topLabel: e.topLabel,
      labelsJson: e.labelsJson,
      audioPath: e.audioPath,
      peaksPath: e.peaksPath,
      starred: starred,
      userLabel: e.userLabel,
      deletedAt: e.deletedAt,
    );

Event _withUserLabel(Event e, String? userLabel) => Event(
      id: e.id,
      startedAt: e.startedAt,
      endedAt: e.endedAt,
      durationMs: e.durationMs,
      createdAt: e.createdAt,
      schemaVersion: e.schemaVersion,
      state: e.state,
      topLabel: e.topLabel,
      labelsJson: e.labelsJson,
      audioPath: e.audioPath,
      peaksPath: e.peaksPath,
      starred: e.starred,
      userLabel: userLabel,
      deletedAt: e.deletedAt,
    );
