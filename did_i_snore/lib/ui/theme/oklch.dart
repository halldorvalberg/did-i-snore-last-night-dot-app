/// OKLCH → [Color] conversion.
///
/// The "Did I Snore?" design system (the Claude-design mockup we're
/// matching) specifies most of its non-neutral colors in CSS `oklch()` —
/// the live-recording orange, the star amber, the record/play button
/// gradients, and the 13 per-category hues, which are all
/// `oklch(L C {hue})` with a parametric hue axis.
///
/// Rather than hand-converting ~20 colors to hex (and losing the
/// parametric hue for categories), we port the standard OKLab/OKLCH →
/// linear-sRGB → gamma-sRGB pipeline. This is the same math browsers use,
/// so the Flutter output matches the HTML mockup pixel-for-pixel.
///
/// Reference: Björn Ottosson, "A perceptual color space for image
/// processing" (oklab), and the CSS Color 4 oklch definition.
library;

import 'dart:math' as math;
import 'dart:ui' show Color;

/// Builds a [Color] from OKLCH components.
///
/// - [l] lightness, 0..1.
/// - [c] chroma, 0..~0.4 (unbounded in theory; clamped via sRGB gamut).
/// - [hueDeg] hue angle in degrees, 0..360.
/// - [alpha] 0..1 opacity (the `/ a` part of `oklch(... / a)`).
///
/// Out-of-gamut results are clamped per-channel to [0, 1], matching the
/// browser's naive clip (the mockup's colors are all in-gamut anyway).
Color oklch(double l, double c, double hueDeg, [double alpha = 1.0]) {
  final hueRad = hueDeg * math.pi / 180.0;
  final a = c * math.cos(hueRad);
  final b = c * math.sin(hueRad);

  // OKLab → LMS (cube-rooted), then cube to linear LMS.
  final lp = l + 0.3963377774 * a + 0.2158037573 * b;
  final mp = l - 0.1055613458 * a - 0.0638541728 * b;
  final sp = l - 0.0894841775 * a - 1.2914855480 * b;

  final lLin = lp * lp * lp;
  final mLin = mp * mp * mp;
  final sLin = sp * sp * sp;

  // LMS → linear sRGB.
  final rLin = 4.0767416621 * lLin - 3.3077115913 * mLin + 0.2309699292 * sLin;
  final gLin = -1.2684380046 * lLin + 2.6097574011 * mLin - 0.3413193965 * sLin;
  final bLin = -0.0041960863 * lLin - 0.7034186147 * mLin + 1.7076147010 * sLin;

  return Color.fromARGB(
    (alpha.clamp(0.0, 1.0) * 255.0).round(),
    _toByte(rLin),
    _toByte(gLin),
    _toByte(bLin),
  );
}

/// Linear-sRGB channel → gamma-encoded 0..255 byte.
int _toByte(double linear) {
  final clamped = linear.clamp(0.0, 1.0);
  final encoded = clamped <= 0.0031308
      ? 12.92 * clamped
      : 1.055 * math.pow(clamped, 1.0 / 2.4) - 0.055;
  return (encoded * 255.0).round().clamp(0, 255);
}
