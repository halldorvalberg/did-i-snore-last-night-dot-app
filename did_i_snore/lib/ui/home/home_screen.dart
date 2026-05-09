/// Home screen — Phase 8 build out.
///
/// Spec: `docs/IMPLEMENTATION.md` §8 line 887. The screen has three jobs:
///
/// 1. The **big primary button** — Start/Stop recording. Disabled until
///    calibration is persisted; surfaces controller errors as SnackBars.
/// 2. The **elapsed time display** — `hh:mm:ss` while `isRecording`,
///    refreshed by a per-second `Timer.periodic` (we deliberately do not
///    use a stream provider for clock ticks; spec line 889 calls it
///    overkill).
/// 3. The **"View last night's events" tile** — visible only when the
///    night-of-now timeline has at least one event row. Pushes the
///    timeline route.
///
/// Phase 3 calibration UI (the "Calibrate this room" button + saved-floor
/// readout) is preserved. The screen is the single launching surface for
/// both calibration and recording in v1.
///
/// **No `print()`** — errors flow through `RecorderState.errorMessage`
/// and a SnackBar; debug telemetry will land in Phase 11.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app.dart';
import '../../consent/consent_state.dart';
import '../../recorder/calibrator.dart';
import '../../recorder/calibrator_provider.dart';
import '../../recorder/recorder_controller_provider.dart';
import '../providers.dart';
import '../timeline/night_of.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  /// Latest calibration returned from the calibration screen. Null until
  /// the user has run calibration this session. Display-only; calibrator
  /// engine persists the canonical value separately.
  NoiseFloor? _lastCalibration;

  /// Drives the elapsed-time readout. Created on `start`, cancelled on
  /// `stop`. setState in the tick body is the cheap way to repaint just
  /// the elapsed-time `Text`; rebuilding the entire `build()` once a
  /// second is acceptable on the home screen (one button + a couple of
  /// labels). For the timeline scroll path we'd care about precision
  /// here, but not for this widget tree.
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    // Listen to controller errors and surface them as SnackBars. Using
    // `ref.listen` from initState would fail; we attach the listener in
    // `build()` instead (Riverpod's idiomatic way).
  }

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
      // The on-disk value just changed; drop the cached future so any
      // subsequent watcher re-reads from SharedPreferences.
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
      // The controller flips `isRecording` on success only; only kick
      // the ticker if the start actually took.
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
    Navigator.of(context).pushNamed(
      timelineRoute,
      arguments: lastNight,
    );
  }

  String _formatElapsed(Duration d) {
    final h = d.inHours.toString().padLeft(2, '0');
    final m = (d.inMinutes % 60).toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$h:$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Surface controller errors as SnackBars; clear the one-shot field
    // back to null afterwards so the next non-null transition re-fires.
    ref.listen<RecorderState>(recorderControllerProvider, (prev, next) {
      final msg = next.errorMessage;
      if (msg != null && msg != prev?.errorMessage) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(msg)),
        );
        // Schedule the clear after the listener returns so we don't
        // mutate state during a build.
        Future.microtask(() {
          if (!mounted) return;
          ref.read(recorderControllerProvider.notifier).clearError();
        });
      }
    });

    final recorderState = ref.watch(recorderControllerProvider);
    // Priority: this session's just-saved value > persisted value > nothing.
    // Loading and error states render nothing — no spinner, no flicker.
    final persistedAsync = ref.watch(persistedNoiseFloorProvider);
    final NoiseFloor? displayedFloor =
        _lastCalibration ?? persistedAsync.valueOrNull;
    final bool hasCalibration = displayedFloor != null;

    final lastNight = nightOfMs(DateTime.now().millisecondsSinceEpoch);
    final lastNightEvents = ref.watch(eventsForNightProvider(lastNight));

    return Scaffold(
      appBar: AppBar(
        title: const Text('Did I Snore?'),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // ---- recording controls ---------------------------------
              _RecordButton(
                isRecording: recorderState.isRecording,
                hasCalibration: hasCalibration,
                onPressed: hasCalibration ? _toggleRecording : null,
              ),
              if (recorderState.isRecording &&
                  recorderState.startedAt != null) ...[
                const SizedBox(height: 16),
                Center(
                  child: Text(
                    _formatElapsed(
                      DateTime.now().difference(recorderState.startedAt!),
                    ),
                    style: theme.textTheme.headlineMedium?.copyWith(
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Center(
                  child: Text(
                    'Recording…',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ] else if (!hasCalibration) ...[
                const SizedBox(height: 12),
                Center(
                  child: Text(
                    'Calibrate this room before recording.',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 24),

              // ---- last night's events ---------------------------------
              if (!recorderState.isRecording &&
                  (lastNightEvents.valueOrNull?.isNotEmpty ?? false)) ...[
                Card(
                  clipBehavior: Clip.antiAlias,
                  child: ListTile(
                    leading: const Icon(Icons.list_alt_outlined),
                    title: const Text("View last night's events"),
                    subtitle: Text(
                      '${lastNightEvents.value!.length} event'
                      '${lastNightEvents.value!.length == 1 ? '' : 's'}',
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: _openLastNightTimeline,
                  ),
                ),
                const SizedBox(height: 24),
              ],

              // ---- calibration UI (Phase 3, preserved) -----------------
              const _PhaseBadge(),
              const SizedBox(height: 16),
              FilledButton.tonalIcon(
                onPressed: _openCalibration,
                icon: const Icon(Icons.tune),
                label: Text(
                  hasCalibration ? 'Recalibrate this room' : 'Calibrate this room',
                ),
              ),
              if (displayedFloor != null) ...[
                const SizedBox(height: 12),
                Text(
                  'Calibrated: floor '
                  '${displayedFloor.medianDbfs.toStringAsFixed(1)} dBFS, '
                  'threshold '
                  '${displayedFloor.tHighDbfs.toStringAsFixed(1)} dBFS.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],

              const Spacer(),
              if (kDebugMode)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: () =>
                        ref.read(consentStateProvider.notifier).reset(),
                    icon: const Icon(Icons.refresh),
                    label: const Text('Reset consent (debug)'),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Big primary Start/Stop button. Pulled out so the home screen's
/// `build()` reads as "controls, then status, then list" rather than a
/// 60-line `FilledButton` invocation in the middle of the column.
class _RecordButton extends StatelessWidget {
  const _RecordButton({
    required this.isRecording,
    required this.hasCalibration,
    required this.onPressed,
  });

  final bool isRecording;
  final bool hasCalibration;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return SizedBox(
      height: 88,
      child: FilledButton.icon(
        style: FilledButton.styleFrom(
          backgroundColor:
              isRecording ? scheme.errorContainer : scheme.primary,
          foregroundColor:
              isRecording ? scheme.onErrorContainer : scheme.onPrimary,
          textStyle: theme.textTheme.titleLarge,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
        ),
        onPressed: onPressed,
        icon: Icon(isRecording ? Icons.stop : Icons.fiber_manual_record),
        label: Text(isRecording ? 'Stop recording' : 'Start recording'),
      ),
    );
  }
}

class _PhaseBadge extends StatelessWidget {
  const _PhaseBadge();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: scheme.tertiaryContainer,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          'PHASE 8 - UI',
          style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: scheme.onTertiaryContainer,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.6,
              ),
        ),
      ),
    );
  }
}
