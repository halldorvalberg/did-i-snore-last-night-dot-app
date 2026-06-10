/// Per-category visual style — icon + hue for each curated label.
///
/// Ported from the mockup's `CATEGORY` map (`app/icons.jsx`). Each curated
/// label gets a Lucide-ish glyph and a low-chroma OKLCH hue so events are
/// differentiable at a glance without being garish. The mockup used Lucide
/// line icons; we map to the closest built-in Material Symbols so we don't
/// add an icon-font dependency (privacy stance: every dep is audited — a
/// decorative icon pack isn't worth it). Swap to `lucide_icons` later if a
/// closer match matters.
///
/// Colors are derived from [hue] exactly as the mockup's `CatGlyph` did:
/// - glyph tint  = oklch(0.72 0.11 hue)
/// - glyph bg    = oklch(0.32 0.05 hue / 0.5)
/// - timeline dot= oklch(0.72 0.11 hue)
///
/// The label keys are the curated set from `LabelMap` / README, plus
/// `Other` as the fallback bucket.
library;

import 'package:flutter/material.dart';

import 'app_colors.dart';
import 'oklch.dart';

@immutable
class CategoryStyle {
  const CategoryStyle(this.icon, this.hue);

  final IconData icon;

  /// OKLCH hue angle (degrees) for this category.
  final double hue;

  /// Glyph foreground tint when category colors are on.
  Color get tint => oklch(0.72, 0.11, hue);

  /// Soft glyph background tile.
  Color get tileBg => oklch(0.32, 0.05, hue, 0.5);

  /// Timeline rail node color (slightly brighter dot).
  Color get dot => oklch(0.72, 0.11, hue);

  /// Large player-header glyph background.
  Color get playerBg => oklch(0.30, 0.06, hue, 0.55);

  /// Large player-header glyph tint.
  Color get playerTint => oklch(0.74, 0.12, hue);

  /// Looks up the style for a curated label, falling back to [other].
  static CategoryStyle of(String? label) => _map[label] ?? other;

  static const CategoryStyle other =
      CategoryStyle(Icons.help_outline_rounded, 0);

  /// label → style. Keys match the curated label set exactly.
  static const Map<String, CategoryStyle> _map = {
    'Snoring': CategoryStyle(Icons.nightlight_round, 285),
    'Speech': CategoryStyle(Icons.chat_bubble_outline_rounded, 230),
    'Cough': CategoryStyle(Icons.air_rounded, 25),
    'Sneeze': CategoryStyle(Icons.water_drop_outlined, 200),
    'Snort': CategoryStyle(Icons.air_rounded, 320),
    'Belch': CategoryStyle(Icons.volume_up_outlined, 95),
    'Fart': CategoryStyle(Icons.cyclone_rounded, 130),
    'Throat clearing': CategoryStyle(Icons.campaign_outlined, 55),
    'Hiccup': CategoryStyle(Icons.monitor_heart_outlined, 350),
    'Whisper': CategoryStyle(Icons.hearing_rounded, 260),
    'Cat': CategoryStyle(Icons.pets_rounded, 40),
    'Dog': CategoryStyle(Icons.cruelty_free_rounded, 15),
    'Other': other,
  };

  /// Neutral (category-colors-off) glyph colors, for users who turn the
  /// hue differentiation off. Mirrors the mockup's `useColor=false` path.
  static const Color neutralTint = Color(0xFFCFCAD9);
  static Color get neutralBg => AppColors.line;
}
