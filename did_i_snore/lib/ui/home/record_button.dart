/// The big circular Start/Stop control on the home screen.
///
/// Ported from the mockup's `RecordButton` (`screens-home.jsx`): a
/// breathing blurred halo, a static ring, and a gradient-filled circular
/// button with a mic (idle) / stop (recording) glyph. Idle = violet
/// accent; recording = warm "live" orange. When [enabled] is false (no
/// calibration yet) the button dims and ignores taps.
library;

import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

class RecordButton extends StatefulWidget {
  const RecordButton({
    super.key,
    required this.recording,
    required this.enabled,
    required this.onTap,
  });

  final bool recording;
  final bool enabled;
  final VoidCallback? onTap;

  @override
  State<RecordButton> createState() => _RecordButtonState();
}

class _RecordButtonState extends State<RecordButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _halo = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 4500),
  )..repeat(reverse: true);

  bool _pressed = false;

  @override
  void didUpdateWidget(RecordButton old) {
    super.didUpdateWidget(old);
    // Breathe faster while live (2.4s vs 4.5s), matching `.halo-live`.
    if (widget.recording != old.recording) {
      _halo.duration = Duration(
        milliseconds: widget.recording ? 2400 : 4500,
      );
      _halo
        ..reset()
        ..repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _halo.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Honor reduced-motion (accessibility) — and keep the infinite
    // breathing loop from blocking `pumpAndSettle` in widget tests.
    final reduceMotion = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    if (reduceMotion && _halo.isAnimating) {
      _halo.stop();
      _halo.value = 0.5;
    } else if (!reduceMotion && !_halo.isAnimating) {
      _halo.repeat(reverse: true);
    }
    final live = widget.recording;
    final ringColor = live ? AppColors.liveLine : AppColors.accentLine;
    final haloColor = live ? AppColors.live : AppColors.accent;
    final gradient = live
        ? AppColors.recordLiveGradient
        : AppColors.recordIdleGradient;

    return Opacity(
      opacity: widget.enabled ? 1.0 : 0.45,
      child: SizedBox(
        width: 232,
        height: 232,
        child: Stack(
          alignment: Alignment.center,
          children: [
            // breathing halo
            AnimatedBuilder(
              animation: _halo,
              builder: (context, _) {
                final t = Curves.easeInOut.transform(_halo.value);
                final scale = 0.82 + 0.22 * t;
                final opacity = (live ? 0.14 : 0.10) + 0.16 * t;
                return Transform.scale(
                  scale: scale,
                  child: Container(
                    width: 232,
                    height: 232,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: haloColor.withValues(alpha: opacity),
                      boxShadow: [
                        BoxShadow(
                          color: haloColor.withValues(alpha: opacity * 0.9),
                          blurRadius: 36,
                          spreadRadius: 4,
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
            // static ring
            Container(
              width: 196,
              height: 196,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: ringColor),
              ),
            ),
            // gradient circle button
            GestureDetector(
              onTapDown: widget.enabled ? (_) => setState(() => _pressed = true) : null,
              onTapCancel: () => setState(() => _pressed = false),
              onTapUp: (_) => setState(() => _pressed = false),
              onTap: widget.enabled ? widget.onTap : null,
              child: AnimatedScale(
                scale: _pressed ? 0.96 : 1.0,
                duration: const Duration(milliseconds: 100),
                child: Container(
                  width: 168,
                  height: 168,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(
                      center: const Alignment(0, -0.4),
                      radius: 0.85,
                      colors: gradient,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: (live ? AppColors.live : AppColors.accent)
                            .withValues(alpha: 0.55),
                        blurRadius: 40,
                        offset: const Offset(0, 12),
                      ),
                    ],
                  ),
                  child: Icon(
                    live ? Icons.stop_rounded : Icons.mic_none_rounded,
                    size: live ? 52 : 56,
                    color: Colors.white,
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
