/// Home screen — Phase 8 build, restyled to the "Did I Snore?" design
/// system (the Claude-design mockup; see `lib/ui/theme/`).
///
/// Three jobs, unchanged from the original spec (`docs/IMPLEMENTATION.md`
/// §8 line 887):
///
/// 1. The **big circular Start/Stop button** ([RecordButton]) — disabled
///    until calibration is persisted; surfaces controller errors as
///    SnackBars.
/// 2. The **elapsed-time readout** (mono, `hh:mm:ss`) while recording,
///    refreshed by a per-second `Timer.periodic`.
/// 3. The **last-night summary card** — tappable, pushes the timeline;
///    shows real v1 stats (events, snoring minutes, gaps). The v2 stats
///    the mockup hints at (asleep-for, bedtime/wake) are intentionally
///    omitted — we don't compute them yet and won't show fake numbers.
///
/// The calibration entry, quota-failed banner, and Manage Storage entry
/// from the original screen are preserved; only the presentation changed.
///
/// **No `print()`** — errors flow through `RecorderState.errorMessage`
/// and a SnackBar.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app.dart';
import '../../data/db.dart' show Event;
import '../../recorder/calibrator.dart';
import '../../recorder/calibrator_provider.dart';
import '../../recorder/recorder_controller_provider.dart';
import '../providers.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';
import '../timeline/display_label.dart';
import '../timeline/night_of.dart';
import '../widgets/loudness.dart';
import '../widgets/pill.dart';
import 'record_button.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  NoiseFloor? _lastCalibration;
  Timer? _ticker;

  @override
  void dispose() {
    _ticker?.cancel();
    _ticker = null;
    super.dispose();
  }

  Future<void> _openCalibration() async {
    final result = await Navigator.of(context).pushNamed<Object?>(
      calibrationRoute,
    );
    if (!mounted) return;
    if (result is NoiseFloor) {
      setState(() => _lastCalibration = result);
      ref.invalidate(persistedNoiseFloorProvider);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Calibration saved. Floor ${result.medianDbfs.toStringAsFixed(1)} '
            'dBFS, threshold ${result.tHighDbfs.toStringAsFixed(1)} dBFS.',
          ),
        ),
      );
    }
  }

  Future<void> _toggleRecording() async {
    final controller = ref.read(recorderControllerProvider.notifier);
    final isRecording = ref.read(recorderControllerProvider).isRecording;
    if (isRecording) {
      await controller.stop();
      _ticker?.cancel();
      _ticker = null;
      if (mounted) setState(() {});
    } else {
      await controller.start();
      final post = ref.read(recorderControllerProvider);
      if (post.isRecording) {
        _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
          if (mounted) setState(() {});
        });
      }
    }
  }

  void _openLastNightTimeline() {
    final lastNight = nightOfMs(DateTime.now().millisecondsSinceEpoch);
    Navigator.of(context).pushNamed(timelineRoute, arguments: lastNight);
  }

  void _openManageStorage() =>
      Navigator.of(context).pushNamed(manageStorageRoute);

  void _openOemOnboarding() =>
      Navigator.of(context).pushNamed(oemOnboardingRoute);

  String _formatElapsed(Duration d) {
    final h = d.inHours.toString().padLeft(2, '0');
    final m = (d.inMinutes % 60).toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$h:$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<RecorderState>(recorderControllerProvider, (prev, next) {
      final msg = next.errorMessage;
      if (msg != null && msg != prev?.errorMessage) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
        Future.microtask(() {
          if (!mounted) return;
          ref.read(recorderControllerProvider.notifier).clearError();
        });
      }
    });

    final recorderState = ref.watch(recorderControllerProvider);
    final recording = recorderState.isRecording;
    final persistedAsync = ref.watch(persistedNoiseFloorProvider);
    final hasCalibration =
        (_lastCalibration ?? persistedAsync.valueOrNull) != null;

    final lastNight = nightOfMs(DateTime.now().millisecondsSinceEpoch);
    final lastNightEvents =
        ref.watch(eventsForNightProvider(lastNight)).valueOrNull ?? const [];
    final gapsCount =
        ref.watch(gapsForNightProvider(lastNight)).valueOrNull?.length ?? 0;
    final quota = ref.watch(quotaResultProvider).valueOrNull;

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            _Header(
              onStorage: _openManageStorage,
              onSettings: _openCalibration,
              onKeepAlive: _openOemOnboarding,
            ),
            Expanded(
              child: SingleChildScrollView(
                physics: const BouncingScrollPhysics(),
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    minHeight: MediaQuery.sizeOf(context).height - 200,
                  ),
                  child: Column(
                    children: [
                      if (quota != null && !quota.canRecord)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(18, 4, 18, 8),
                          child: _QuotaBanner(
                            reason: quota.blockReason,
                            onOpen: _openManageStorage,
                          ),
                        ),

                      // ---- hero ----------------------------------------
                      Padding(
                        padding: const EdgeInsets.fromLTRB(22, 14, 22, 8),
                        child: _Hero(
                          recording: recording,
                          paused: false,
                          hasCalibration: hasCalibration,
                          elapsed: recorderState.startedAt == null
                              ? Duration.zero
                              : DateTime.now()
                                  .difference(recorderState.startedAt!),
                          formatElapsed: _formatElapsed,
                          onToggle: hasCalibration ? _toggleRecording : null,
                          onCalibrate: _openCalibration,
                        ),
                      ),

                      // ---- last-night summary card ---------------------
                      if (lastNightEvents.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(18, 8, 18, 22),
                          child: _SummaryCard(
                            previous: recording,
                            night: lastNight,
                            events: lastNightEvents,
                            gaps: gapsCount,
                            onTap: _openLastNightTimeline,
                          ),
                        )
                      else
                        const SizedBox(height: 22),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Top bar: brand on the left, storage + settings on the right.
class _Header extends StatelessWidget {
  const _Header({
    required this.onStorage,
    required this.onSettings,
    required this.onKeepAlive,
  });

  final VoidCallback onStorage;
  final VoidCallback onSettings;

  /// Re-opens the OEM "keep recording alive" onboarding (Phase 10.1). The
  /// flow is auto-surfaced once on first Android launch; this is the
  /// re-accessible entry point so the user can revisit the battery /
  /// autostart steps any time.
  final VoidCallback onKeepAlive;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 16, 14, 6),
      child: Row(
        children: [
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: AppColors.accentDim,
              borderRadius: BorderRadius.circular(9),
              border: Border.all(color: AppColors.accentLine),
            ),
            child: const Icon(Icons.nightlight_round,
                size: 15, color: AppColors.accent),
          ),
          const SizedBox(width: 9),
          const Text(
            'Did I Snore?',
            style: TextStyle(
              fontSize: 15.5,
              fontWeight: FontWeight.w600,
              letterSpacing: -0.15,
              color: AppColors.text1,
            ),
          ),
          const Spacer(),
          _IconBtn(icon: Icons.shield_moon_outlined, onTap: onKeepAlive),
          _IconBtn(icon: Icons.sd_storage_outlined, onTap: onStorage),
          _IconBtn(icon: Icons.tune_rounded, onTap: onSettings),
        ],
      ),
    );
  }
}

class _IconBtn extends StatelessWidget {
  const _IconBtn({required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      onPressed: onTap,
      icon: Icon(icon, size: 19),
      color: AppColors.text2,
      splashRadius: 22,
    );
  }
}

/// The centered hero: greeting / live status, record button, status line,
/// privacy pill.
class _Hero extends StatelessWidget {
  const _Hero({
    required this.recording,
    required this.paused,
    required this.hasCalibration,
    required this.elapsed,
    required this.formatElapsed,
    required this.onToggle,
    required this.onCalibrate,
  });

  final bool recording;
  final bool paused;
  final bool hasCalibration;
  final Duration elapsed;
  final String Function(Duration) formatElapsed;
  final VoidCallback? onToggle;
  final VoidCallback onCalibrate;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const SizedBox(height: 8),
        // greeting / live header
        if (!recording)
          Column(
            children: const [
              Text('READY WHEN YOU ARE', style: AppText.eyebrow),
              SizedBox(height: 8),
              Text(
                'Good night',
                style: TextStyle(
                  fontSize: 25,
                  fontWeight: FontWeight.w600,
                  letterSpacing: -0.5,
                  color: AppColors.text1,
                ),
              ),
            ],
          )
        else
          Column(
            children: [
              Pill(
                label: paused ? 'Paused' : 'Recording',
                tone: PillTone.live,
                leading: const RecDot(),
              ),
              const SizedBox(height: 10),
              Text(
                formatElapsed(elapsed),
                style: const TextStyle(
                  fontFamily: AppFonts.mono,
                  fontSize: 46,
                  fontWeight: FontWeight.w500,
                  height: 1,
                  color: AppColors.text1,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
        const SizedBox(height: 22),
        RecordButton(
          recording: recording,
          enabled: hasCalibration,
          onTap: onToggle,
        ),
        const SizedBox(height: 22),
        Text(
          !hasCalibration
              ? 'Calibrate your room to start'
              : recording
                  ? 'Tap to stop'
                  : 'Tap to start recording',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w500,
            color: recording ? AppColors.live : AppColors.text1,
          ),
        ),
        const SizedBox(height: 12),
        if (!hasCalibration)
          TextButton.icon(
            onPressed: onCalibrate,
            icon: const Icon(Icons.tune_rounded, size: 16),
            label: const Text('Calibrate this room'),
            style: TextButton.styleFrom(foregroundColor: AppColors.accent),
          )
        else
          const Pill(
            label: 'Audio stays on this device',
            icon: Icons.lock_outline_rounded,
            tone: PillTone.accent,
          ),
        if (recording) ...[
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: const [
              Icon(Icons.circle, size: 9, color: Color(0xFFE9733B)),
              SizedBox(width: 7),
              Text(
                'A notification shows while the mic is on',
                style: TextStyle(fontSize: 12.5, color: AppColors.text3),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

/// Tappable summary of the most recent night → timeline.
class _SummaryCard extends StatelessWidget {
  const _SummaryCard({
    required this.previous,
    required this.night,
    required this.events,
    required this.gaps,
    required this.onTap,
  });

  final bool previous;
  final DateTime night;
  final List<Event> events;
  final int gaps;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final snore = events.where((e) => displayLabel(e) == 'Snoring').toList();
    final snoreMin =
        (snore.fold<int>(0, (a, e) => a + e.durationMs) / 60000).round();
    final ribbon = _ribbonPeaks(events, night);

    return Material(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: AppColors.line),
          ),
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(previous ? 'PREVIOUS NIGHT' : 'LAST NIGHT',
                      style: AppText.eyebrow),
                  const Spacer(),
                  const Text('View timeline',
                      style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          color: AppColors.accent)),
                  const Icon(Icons.chevron_right_rounded,
                      size: 18, color: AppColors.accent),
                ],
              ),
              const SizedBox(height: 14),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  _Stat(n: '${snoreMin}m', l: 'snoring'),
                  _Stat(n: '${snore.length}', l: 'snore runs'),
                  _Stat(n: '${events.length}', l: 'events'),
                  _Stat(n: '$gaps', l: 'gaps'),
                ],
              ),
              const SizedBox(height: 14),
              HeatStrip(peaks: ribbon, height: 26, gap: 1.6),
            ],
          ),
        ),
      ),
    );
  }

  /// Coarse whole-night intensity ribbon built from real event placement:
  /// bin events across [first, last] by start time, cell value = the
  /// loudest event in that bin (proxied by duration, normalized). Honest
  /// event-density signal — no fabricated loudness.
  static List<double> _ribbonPeaks(List<Event> events, DateTime night) {
    const cells = 64;
    final peaks = List<double>.filled(cells, 0);
    if (events.isEmpty) return peaks;
    final starts = events.map((e) => e.startedAt).toList()..sort();
    final first = starts.first;
    final last = starts.last;
    final span = (last - first).clamp(1, 1 << 62);
    var maxDur = 1;
    for (final e in events) {
      if (e.durationMs > maxDur) maxDur = e.durationMs;
    }
    for (final e in events) {
      final idx = (((e.startedAt - first) / span) * (cells - 1)).round();
      final v = (e.durationMs / maxDur).clamp(0.08, 1.0);
      for (var d = -1; d <= 1; d++) {
        final j = idx + d;
        if (j >= 0 && j < cells) {
          peaks[j] = peaks[j] > v ? peaks[j] : (d == 0 ? v : v * 0.5);
        }
      }
    }
    return peaks;
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.n, required this.l});

  final String n;
  final String l;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          n,
          style: const TextStyle(
            fontSize: 21,
            fontWeight: FontWeight.w600,
            height: 1,
            letterSpacing: -0.2,
            color: AppColors.text1,
            fontFeatures: [FontFeature.tabularFigures()],
          ),
        ),
        const SizedBox(height: 5),
        Text(l, style: const TextStyle(fontSize: 11.5, color: AppColors.text3)),
      ],
    );
  }
}

/// Inline quota-failed banner above the hero. Spec §9 line 936.
class _QuotaBanner extends StatelessWidget {
  const _QuotaBanner({required this.reason, required this.onOpen});

  final String? reason;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.liveDim,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.liveLine),
      ),
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline_rounded, color: AppColors.live),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Recording disabled',
                    style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: AppColors.live)),
                const SizedBox(height: 4),
                Text(
                  reason ??
                      'Low storage. Open Manage Storage to free space and '
                          'resume recording.',
                  style: const TextStyle(fontSize: 13.5, color: AppColors.text2),
                ),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: onOpen,
                  style: TextButton.styleFrom(
                    foregroundColor: AppColors.live,
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                  ),
                  child: const Text('Manage storage'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
