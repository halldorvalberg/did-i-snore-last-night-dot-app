/// Calibration screen — phase 3.1.
///
/// Visualises the room's noise floor in real time so the user can see "is
/// this room actually quiet enough?" rather than staring at an opaque 30 s
/// timer. Three layers of feedback:
///
/// 1. A live RMS bar (10 Hz, ~32 px tall), mapping current dBFS onto a
///    -90..-10 dBFS visual range.
/// 2. A 30-second sliding history strip drawn with `CustomPainter` from the
///    same -90..-10 range. Includes a horizontal reference line at the
///    estimated quiet floor.
/// 3. A status card walking through `Listening...` → `Looking quiet — keep
///    going (Xs / 10s)` → `Quiet enough — you can save`, gated only on
///    `state.contiguousQuietMs` and `state.canSave`.
///
/// The widget owns no audio state. The single source of truth is
/// `calibrationStateProvider` (a `StreamProvider<CalibrationState>`); the
/// `Calibrator` engine itself lives in `lib/recorder/calibrator.dart` and
/// only receives lifecycle calls (`start`, `stop`, `save`, `reset`) from
/// here.
///
/// Mic permission is assumed to have been granted in the consent flow
/// (`lib/consent/`); if it hasn't, we surface a brief message rather than
/// silently consuming the calibrator's error stream.
///
/// Routing: registered at `/setup/calibration` in `lib/app.dart`'s route
/// table. On save, pops with the resulting `NoiseFloor` so the home screen
/// (or settings → Recalibrate) can read the new thresholds.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../recorder/calibrator.dart';
import '../../recorder/calibrator_provider.dart';

/// Visual mapping for both the live RMS bar and the history strip.
/// `dBFS` outside this range is clamped — sub--90 is effectively silence,
/// above -10 is comfortably louder than anything that should occur during
/// calibration.
const double _visMinDbfs = -90.0;
const double _visMaxDbfs = -10.0;

/// Number of milliseconds of contiguous quiet required to enable Save.
/// Mirrored from the calibrator's `canSave` threshold; kept here to render
/// the "Xs / 10s" countdown without re-deriving it.
const int _requiredQuietMs = 10000;

class CalibrationScreen extends ConsumerStatefulWidget {
  const CalibrationScreen({super.key});

  @override
  ConsumerState<CalibrationScreen> createState() => _CalibrationScreenState();
}

class _CalibrationScreenState extends ConsumerState<CalibrationScreen>
    with WidgetsBindingObserver {
  /// True once we've kicked off `calibrator.start()`. Guards against
  /// double-start if `initState` reruns due to provider re-resolution.
  bool _started = false;

  /// True if the app was sent to background mid-calibration. We pause the
  /// calibrator on `paused` and prompt the user to retry on `resumed`,
  /// because silent background calibration is exactly the failure mode the
  /// spec is preventing — the user may have walked into a different room.
  bool _wasBackgrounded = false;

  /// True while a save is in flight. Disables the buttons so a double-tap
  /// can't fire two `calibrator.save()` calls.
  bool _saving = false;

  /// True if mic permission turns out to be denied. Toggled from a
  /// permission re-check; happy path leaves this false.
  bool _permissionDenied = false;

  /// Cached calibrator reference. Captured the first time the widget builds
  /// so `dispose()` (which runs after the element is unmounted and `ref`
  /// can no longer be used) still has something to stop. Resolving the
  /// provider via `ref.read` from `dispose()` throws because the
  /// `ConsumerStatefulElement` has already detached.
  Calibrator? _calibrator;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Start on the next frame — `initState` cannot await, and we don't want
    // to block first paint on the platform's permission probe.
    WidgetsBinding.instance.addPostFrameCallback((_) => _bootstrap());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Capture the calibrator once we have an inherited-widget context.
    // `_calibrator` is null on the very first call into `dispose()` only
    // if the widget never built — which can't happen since `dispose()`
    // implies a build did happen. But we treat null defensively anyway.
    _calibrator ??= ref.read(calibratorProvider);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // Best-effort stop. The calibrator must tolerate `stop()` even if we
    // never started (e.g. permission denied path), so this is unguarded.
    _calibrator?.stop();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      // App is going away. Stop the mic; we'll prompt for retry on resume.
      _wasBackgrounded = true;
      _calibrator?.stop();
    } else if (state == AppLifecycleState.resumed && _wasBackgrounded) {
      _wasBackgrounded = false;
      _promptResumeAfterBackground();
    }
  }

  /// Returns the cached calibrator, falling back to a fresh `ref.read` if
  /// the cache hasn't been populated yet (e.g. extreme cold-path race
  /// before `didChangeDependencies` ran).
  Calibrator _calibratorOrRead() => _calibrator ?? ref.read(calibratorProvider);

  /// First-frame bootstrap. Verifies the mic permission (it should already
  /// be granted from the consent flow) and kicks off the calibrator.
  Future<void> _bootstrap() async {
    if (_started) return;
    final granted = await Permission.microphone.isGranted;
    if (!mounted) return;
    if (!granted) {
      setState(() => _permissionDenied = true);
      return;
    }
    _started = true;
    await _calibratorOrRead().start();
  }

  /// Reset and restart. Used by both the in-screen "Cancel and try again"
  /// button and the post-background resume prompt.
  Future<void> _resetAndRestart() async {
    final calibrator = _calibratorOrRead();
    await calibrator.reset();
    await calibrator.start();
  }

  Future<void> _promptResumeAfterBackground() async {
    final retry = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Calibration paused'),
        content: const Text(
          "Calibration was interrupted while the app was in the background. "
          "Quiet rooms aren't quiet remotely — let's start over.",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Leave'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Restart'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (retry == true) {
      await _resetAndRestart();
    } else {
      Navigator.of(context).maybePop();
    }
  }

  Future<void> _onSave(CalibrationState snapshot) async {
    if (_saving || !snapshot.canSave) return;
    setState(() => _saving = true);
    try {
      final floor = await _calibratorOrRead().save();
      if (!mounted) return;
      Navigator.of(context).pop<NoiseFloor>(floor);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Couldn't save calibration: $e")),
      );
      setState(() => _saving = false);
    }
  }

  Future<void> _onCancelAndRetry() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Start over?'),
        content: const Text(
          'This will discard the current sample and begin listening again. '
          "You'll stay on this screen.",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Keep going'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Start over'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await _resetAndRestart();
    }
  }

  /// Android system back / iOS swipe-back handler. Confirms before leaving,
  /// so a stray gesture doesn't kill a 9-second-quiet streak. The `onPopInvoked`
  /// API leaves the system gesture in our hands when `canPop` is false.
  Future<void> _onWillPop() async {
    final leave = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Leave calibration?'),
        content: const Text(
          "You haven't saved a noise floor yet. Leaving now keeps the "
          'previous calibration, if any.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Stay'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Leave'),
          ),
        ],
      ),
    );
    if (leave == true && mounted) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final stream = ref.watch(calibrationStateProvider);

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _onWillPop();
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Calibrate this room'),
        ),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
            child: _permissionDenied
                ? _PermissionDeniedView(
                    onOpenSettings: () => openAppSettings(),
                  )
                : stream.when(
                    loading: () => const _InitialLoading(),
                    error: (err, _) => _ErrorView(
                      message: '$err',
                      onRetry: _resetAndRestart,
                    ),
                    data: (state) => _CalibrationBody(
                      state: state,
                      saving: _saving,
                      onSave: () => _onSave(state),
                      onCancelAndRetry: _onCancelAndRetry,
                      theme: theme,
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}

/// Body of the screen when the stream has produced at least one snapshot.
/// Pure presentational — receives the latest `CalibrationState` and
/// callbacks; no Riverpod reads here.
class _CalibrationBody extends StatelessWidget {
  const _CalibrationBody({
    required this.state,
    required this.saving,
    required this.onSave,
    required this.onCancelAndRetry,
    required this.theme,
  });

  final CalibrationState state;
  final bool saving;
  final VoidCallback onSave;
  final VoidCallback onCancelAndRetry;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    final secondsHeld = (state.contiguousQuietMs / 1000).floor();
    final secondsRequired = (_requiredQuietMs / 1000).floor();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _Header(),
        const SizedBox(height: 24),
        Semantics(
          liveRegion: true,
          label: 'Microphone level: ${state.rmsDbfs.round()} decibels, '
              'quiet for $secondsHeld seconds out of $secondsRequired.',
          excludeSemantics: true,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _LiveRmsBar(
                rmsDbfs: state.rmsDbfs,
                floorDbfs: state.estimatedFloorDbfs,
                colorScheme: theme.colorScheme,
              ),
              const SizedBox(height: 20),
              _HistoryStrip(
                history: state.historyDbfs,
                floorDbfs: state.estimatedFloorDbfs,
                colorScheme: theme.colorScheme,
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        _StatusCard(state: state),
        const Spacer(),
        Row(
          children: [
            TextButton(
              onPressed: saving ? null : onCancelAndRetry,
              child: const Text('Cancel and try again'),
            ),
            const Spacer(),
            FilledButton(
              onPressed: state.canSave && !saving ? onSave : null,
              child: saving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Save calibration'),
            ),
          ],
        ),
        const SizedBox(height: 8),
      ],
    );
  }
}

class _Header extends StatelessWidget {
  const _Header();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Calibrate this room',
          style: theme.textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          'Stay still and quiet for 10 seconds.',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

class _InitialLoading extends StatelessWidget {
  const _InitialLoading();

  @override
  Widget build(BuildContext context) {
    return const Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _Header(),
        Expanded(child: Center(child: CircularProgressIndicator())),
      ],
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onRetry});

  final String message;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _Header(),
        const SizedBox(height: 32),
        Card(
          color: theme.colorScheme.errorContainer,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Microphone unavailable.',
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: theme.colorScheme.onErrorContainer,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  message,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onErrorContainer,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        Align(
          alignment: Alignment.centerRight,
          child: FilledButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh),
            label: const Text('Try again'),
          ),
        ),
      ],
    );
  }
}

class _PermissionDeniedView extends StatelessWidget {
  const _PermissionDeniedView({required this.onOpenSettings});

  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _Header(),
        const SizedBox(height: 32),
        Text(
          "Microphone permission isn't granted on this device. "
          "Calibration needs the mic to listen to your room.",
          style: theme.textTheme.bodyLarge?.copyWith(height: 1.5),
        ),
        const Spacer(),
        Align(
          alignment: Alignment.centerRight,
          child: FilledButton.icon(
            onPressed: onOpenSettings,
            icon: const Icon(Icons.settings),
            label: const Text('Open settings'),
          ),
        ),
      ],
    );
  }
}

/// Live RMS dBFS bar. Animates fill-width over 100 ms so the bar tracks the
/// 10 Hz state stream without strobing.
class _LiveRmsBar extends StatelessWidget {
  const _LiveRmsBar({
    required this.rmsDbfs,
    required this.floorDbfs,
    required this.colorScheme,
  });

  final double rmsDbfs;
  final double floorDbfs;
  final ColorScheme colorScheme;

  @override
  Widget build(BuildContext context) {
    final fraction = _normaliseDbfs(rmsDbfs);
    final floorFraction = _normaliseDbfs(floorDbfs);
    final isQuiet = rmsDbfs <= floorDbfs;
    final fillColor =
        isQuiet ? colorScheme.surfaceContainerHighest : colorScheme.primary;

    return SizedBox(
      height: 32,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final w = constraints.maxWidth;
          return Stack(
            children: [
              // Track.
              Container(
                decoration: BoxDecoration(
                  color: colorScheme.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              // Animated fill.
              AnimatedContainer(
                duration: const Duration(milliseconds: 100),
                width: (w * fraction).clamp(0.0, w),
                decoration: BoxDecoration(
                  color: fillColor,
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              // Floor tick.
              Positioned(
                left: (w * floorFraction).clamp(0.0, w - 2),
                top: 0,
                bottom: 0,
                child: Container(
                  width: 2,
                  color: colorScheme.onSurface.withValues(alpha: 0.55),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// 30-second sliding-history strip. `CustomPainter` so we don't pull in a
/// chart dependency for ≤ 300 floats.
class _HistoryStrip extends StatelessWidget {
  const _HistoryStrip({
    required this.history,
    required this.floorDbfs,
    required this.colorScheme,
  });

  final List<double> history;
  final double floorDbfs;
  final ColorScheme colorScheme;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 80,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Container(
          color: colorScheme.surfaceContainerLow,
          child: CustomPaint(
            painter: _HistoryStripPainter(
              history: history,
              floorDbfs: floorDbfs,
              lineColor: colorScheme.primary,
              fillColor: colorScheme.primary.withValues(alpha: 0.18),
              floorColor: colorScheme.onSurface.withValues(alpha: 0.45),
            ),
            size: Size.infinite,
          ),
        ),
      ),
    );
  }
}

class _HistoryStripPainter extends CustomPainter {
  _HistoryStripPainter({
    required this.history,
    required this.floorDbfs,
    required this.lineColor,
    required this.fillColor,
    required this.floorColor,
  });

  final List<double> history;
  final double floorDbfs;
  final Color lineColor;
  final Color fillColor;
  final Color floorColor;

  @override
  void paint(Canvas canvas, Size size) {
    // Reference line at the estimated floor — drawn first so the line overlays.
    final floorY = _yForDbfs(floorDbfs, size.height);
    final floorPaint = Paint()
      ..color = floorColor
      ..strokeWidth = 1.0;
    canvas.drawLine(
      Offset(0, floorY),
      Offset(size.width, floorY),
      floorPaint,
    );

    if (history.isEmpty) return;

    // Map up to 300 points across the width. Older samples are at the left,
    // matching the stream's "oldest -> newest" guarantee.
    final n = history.length;
    final step = n > 1 ? size.width / (n - 1) : 0.0;

    final linePath = Path();
    final fillPath = Path()..moveTo(0, size.height);

    for (var i = 0; i < n; i++) {
      final x = step * i;
      final y = _yForDbfs(history[i], size.height);
      if (i == 0) {
        linePath.moveTo(x, y);
        fillPath.lineTo(x, y);
      } else {
        linePath.lineTo(x, y);
        fillPath.lineTo(x, y);
      }
    }
    fillPath
      ..lineTo(step * (n - 1), size.height)
      ..close();

    canvas.drawPath(fillPath, Paint()..color = fillColor);
    canvas.drawPath(
      linePath,
      Paint()
        ..color = lineColor
        ..strokeWidth = 2.0
        ..style = PaintingStyle.stroke
        ..strokeJoin = StrokeJoin.round,
    );
  }

  static double _yForDbfs(double dbfs, double height) {
    final f = _normaliseDbfs(dbfs);
    // Louder (higher dBFS) → top of strip.
    return height * (1.0 - f);
  }

  @override
  bool shouldRepaint(_HistoryStripPainter old) {
    return old.history != history ||
        old.floorDbfs != floorDbfs ||
        old.lineColor != lineColor ||
        old.fillColor != fillColor ||
        old.floorColor != floorColor;
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.state});

  final CalibrationState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final secondsHeld = (state.contiguousQuietMs / 1000).floor();
    final secondsRequired = (_requiredQuietMs / 1000).floor();

    String message;
    IconData icon;
    if (state.canSave) {
      message = 'Quiet enough — you can save';
      icon = Icons.check_circle_outline;
    } else if (state.contiguousQuietMs > 0) {
      message =
          'Looking quiet — keep going (${secondsHeld}s / ${secondsRequired}s)';
      icon = Icons.hourglass_bottom;
    } else {
      message = 'Listening...';
      icon = Icons.hearing;
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: theme.colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 200),
        transitionBuilder: (child, anim) =>
            FadeTransition(opacity: anim, child: child),
        child: Row(
          // ValueKey forces AnimatedSwitcher to swap on phase transitions
          // even though the surrounding container is identical.
          key: ValueKey(message),
          children: [
            Icon(icon, color: theme.colorScheme.onSecondaryContainer),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                message,
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: theme.colorScheme.onSecondaryContainer,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Maps a dBFS value into [0, 1] over the visual range. Defined at top-level
/// (not method-local) so the painter and the live bar both use the same
/// projection — divergence between the two would produce a misaligned floor
/// tick.
double _normaliseDbfs(double dbfs) {
  if (dbfs.isNaN) return 0.0;
  final clamped = dbfs.clamp(_visMinDbfs, _visMaxDbfs);
  return (clamped - _visMinDbfs) / (_visMaxDbfs - _visMinDbfs);
}

