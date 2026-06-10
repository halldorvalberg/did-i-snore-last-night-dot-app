/// Shape & spacing tokens for the "Did I Snore?" design system.
///
/// The mockup's shape language is large, soft radii and generous spacing.
/// These constants are the radii/sizes that recur across screens; one-off
/// values stay inline at their use site.
library;

abstract final class AppRadii {
  /// Cards, the night-summary panel, storage cards (`border-radius: 20`).
  static const double card = 20;

  /// Event tiles (`18`).
  static const double tile = 18;

  /// Gap tiles, popovers, footer buttons, snackbar (`16`).
  static const double medium = 16;

  /// Icon buttons, small chips, date-picker chips (`14`).
  static const double small = 14;

  /// Category glyph tiles use radius ≈ 0.3 × size; this is the player's
  /// big-glyph radius (`26`).
  static const double glyph = 26;

  /// Fully rounded pills / circular affordances.
  static const double pill = 999;
}

abstract final class AppSpace {
  static const double screenH = 18; // default horizontal screen padding
  static const double tileGap = 9; // gap between tiles in a group
  static const double groupGap = 18; // gap between hour groups
}
