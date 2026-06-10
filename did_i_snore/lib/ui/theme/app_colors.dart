/// Color tokens for the "Did I Snore?" dark design system.
///
/// One source of truth for every color in the app. Names and values are a
/// 1:1 port of the CSS custom properties in the Claude-design mockup
/// (`:root { --bg … }`). Neutrals are hex; the chromatic colors that the
/// mockup expressed in `oklch()` are reproduced via [oklch] so the hue
/// math stays identical.
///
/// The app is **dark-only** (it's used in a dark bedroom at night and in a
/// groggy morning) — there is no light variant of these tokens.
library;

import 'dart:ui' show Color;

import 'oklch.dart';

abstract final class AppColors {
  // ---- surfaces & lines (neutral, hex straight from the mockup) --------
  /// Page background behind the app shell.
  static const Color bg = Color(0xFF15131A);

  /// Translucent bg for sticky/blurred headers (`--bg-blur`).
  static const Color bgBlur = Color(0xD115131A); // rgba(21,19,26,0.82)

  /// Card / tile background (`--surface`).
  static const Color surface = Color(0xFF1D1A24);

  /// Raised surface — pressed tiles, popovers, snackbar (`--surface-2`).
  static const Color surface2 = Color(0xFF262230);

  /// Hairline divider / border (`--line`, white @ 7%).
  static const Color line = Color(0x12FFFFFF);

  /// Stronger hairline (`--line-strong`, white @ 14%).
  static const Color lineStrong = Color(0x24FFFFFF);

  // ---- text ------------------------------------------------------------
  /// Primary text (`--text-1`).
  static const Color text1 = Color(0xFFECEAF2);

  /// Secondary text (`--text-2`).
  static const Color text2 = Color(0xFF9A95A8);

  /// Tertiary / muted text, mono captions (`--text-3`).
  static const Color text3 = Color(0xFF6A6577);

  // ---- accent (violet) -------------------------------------------------
  /// Brand accent (`--accent`, `#8b7cf0`).
  static const Color accent = Color(0xFF8B7CF0);

  /// Accent fill at low opacity (`--accent-dim`, accent @ 16%).
  static const Color accentDim = Color(0x288B7CF0);

  /// Accent hairline (`--accent-line`, accent @ 32%).
  static const Color accentLine = Color(0x528B7CF0);

  /// Hue angle of the accent in OKLCH (violet) — used to derive the
  /// record/play button gradients so they track the accent.
  static const double accentHue = 285.0;

  // ---- live / recording (warm orange, the "mic is hot" color) ----------
  /// Live indicator (`--live`, `oklch(0.71 0.17 38)`).
  static final Color live = oklch(0.71, 0.17, 38);

  /// Live fill at low opacity (`--live-dim`).
  static final Color liveDim = oklch(0.62, 0.18, 38, 0.16);

  /// Live hairline (`--live-line`).
  static final Color liveLine = oklch(0.66, 0.18, 38, 0.40);

  // ---- star (amber, "kept forever") ------------------------------------
  /// Star color (`--star`, `oklch(0.82 0.13 84)`).
  static final Color star = oklch(0.82, 0.13, 84);

  /// Star fill at low opacity (`--star-dim`).
  static final Color starDim = oklch(0.70, 0.12, 84, 0.14);

  /// Star hairline (`--star-line`).
  static final Color starLine = oklch(0.74, 0.12, 84, 0.34);

  // ---- destructive (swipe-to-delete background) ------------------------
  /// Delete-action red (`oklch(0.5 0.16 28)` from the swipe row).
  static final Color danger = oklch(0.50, 0.16, 28);

  // ---- gradients (record / play buttons) -------------------------------
  /// Record button (idle) — violet radial, top stop → bottom stop.
  static final List<Color> recordIdleGradient = [
    oklch(0.66, 0.15, accentHue),
    oklch(0.55, 0.15, accentHue - 3),
  ];

  /// Record button (live) — warm orange radial.
  static final List<Color> recordLiveGradient = [
    oklch(0.60, 0.16, 38),
    oklch(0.50, 0.15, 35),
  ];

  /// Play button — same violet as the idle record button.
  static List<Color> get playGradient => recordIdleGradient;
}
