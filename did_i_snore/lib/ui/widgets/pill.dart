/// Status pill — the small rounded chip the mockup uses for
/// "Audio stays on this device", "Recording", "Paused", etc.
///
/// Ported from `components.jsx` `Pill`. Three tones map onto the design's
/// neutral / accent / live color families.
library;

import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

enum PillTone { neutral, accent, live }

class Pill extends StatelessWidget {
  const Pill({
    super.key,
    required this.label,
    this.icon,
    this.leading,
    this.tone = PillTone.neutral,
  });

  final String label;
  final IconData? icon;

  /// Optional custom leading widget (e.g. the pulsing record dot) used
  /// instead of [icon].
  final Widget? leading;
  final PillTone tone;

  @override
  Widget build(BuildContext context) {
    final (bg, border, fg) = switch (tone) {
      PillTone.neutral => (AppColors.line, AppColors.lineStrong, AppColors.text2),
      PillTone.accent => (AppColors.accentDim, AppColors.accentLine, AppColors.accent),
      PillTone.live => (AppColors.liveDim, AppColors.liveLine, AppColors.live),
    };
    return Container(
      padding: const EdgeInsets.fromLTRB(9, 6, 11, 6),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (leading != null)
            Padding(padding: const EdgeInsets.only(right: 7), child: leading!)
          else if (icon != null) ...[
            Icon(icon, size: 14, color: fg),
            const SizedBox(width: 7),
          ],
          Text(
            label,
            style: TextStyle(
              color: fg,
              fontSize: 12.5,
              fontWeight: FontWeight.w500,
              height: 1,
            ),
          ),
        ],
      ),
    );
  }
}

/// The pulsing live-recording dot used inside a [Pill] (`rec-dot`).
class RecDot extends StatefulWidget {
  const RecDot({super.key, this.size = 7, this.color});

  final double size;
  final Color? color;

  @override
  State<RecDot> createState() => _RecDotState();
}

class _RecDotState extends State<RecDot> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Honor reduced-motion and keep the infinite pulse from blocking
    // `pumpAndSettle` in widget tests.
    final reduceMotion = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    if (reduceMotion && _c.isAnimating) {
      _c.stop();
      _c.value = 0;
    } else if (!reduceMotion && !_c.isAnimating) {
      _c.repeat(reverse: true);
    }
    return FadeTransition(
      opacity: Tween(begin: 1.0, end: 0.35).animate(
        CurvedAnimation(parent: _c, curve: Curves.easeInOut),
      ),
      child: Container(
        width: widget.size,
        height: widget.size,
        decoration: BoxDecoration(
          color: widget.color ?? AppColors.live,
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}
