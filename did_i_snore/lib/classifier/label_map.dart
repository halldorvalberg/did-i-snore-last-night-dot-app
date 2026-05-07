/// AudioSet → curated label mapping and per-event aggregation.
///
/// The curated set is intentionally small (Snoring, Speech, Cough, Sneeze,
/// Belch, Fart, Throat clearing, Hiccup, Whisper, Cat, Dog, Other). Anything
/// not in [LabelMap.yamnetToCurated] collapses to `Other` so that future
/// curated-set changes don't require re-classifying — the full YAMNet
/// score map is what gets persisted; the curated map is derived on demand.
library;

class LabelMap {
  /// Explicit AudioSet display-name → curated bucket. All 17 source names
  /// have been verified present in `assets/models/yamnet_class_map.csv`.
  ///
  /// Note: the bare `Whimper` (AudioSet idx 21, the human/distress one) is
  /// intentionally NOT mapped — only `Whimper (dog)` (idx 75) feeds Dog.
  static const Map<String, String> yamnetToCurated = {
    'Snoring': 'Snoring',
    'Snort': 'Snoring',
    'Speech': 'Speech',
    'Conversation': 'Speech',
    'Whispering': 'Whisper',
    'Cough': 'Cough',
    'Sneeze': 'Sneeze',
    'Throat clearing': 'Throat clearing',
    'Burping, eructation': 'Belch',
    'Fart': 'Fart',
    'Hiccup': 'Hiccup',
    'Cat': 'Cat',
    'Meow': 'Cat',
    'Purr': 'Cat',
    'Dog': 'Dog',
    'Bark': 'Dog',
    'Whimper (dog)': 'Dog',
  };

  /// Collapse 521 per-class scores into the curated map.
  ///
  /// Within a curated bucket we take the **max**, never the sum:
  /// summing Snoring + Snort would double-count when YAMNet emits
  /// non-trivial probability on both for the same frame.
  ///
  /// Classes mapped to `Other` (i.e. the ~500 AudioSet entries not in
  /// [yamnetToCurated]) are folded the same way so the recorder's reject
  /// policy can compare `maxCurated` vs `Other` directly.
  ///
  /// True zeros are left out of the result map (the comparison
  /// `(out[curated] ?? 0) < scores[i]` only updates when `scores[i] > 0`).
  static Map<String, double> aggregate(
    List<double> scores,
    List<String> classNames,
  ) {
    final out = <String, double>{};
    for (var i = 0; i < classNames.length; i++) {
      final curated = yamnetToCurated[classNames[i]] ?? 'Other';
      if ((out[curated] ?? 0) < scores[i]) out[curated] = scores[i];
    }
    return out;
  }

  /// Pick the deterministic top label for the storage `top_label` column.
  ///
  /// `Other` is excluded from the contest — the recorder treats
  /// "everything-curated-was-low" as a separate signal via the reject
  /// policy in §5.3, not as a label worth surfacing. If no curated class
  /// has a score > 0, falls back to `('Other', otherScore)`; the recorder
  /// uses that together with [LabelCfg.minTopCuratedForKeep] /
  /// [LabelCfg.maxOtherForKeep] to decide whether to drop the event.
  ///
  /// Tie-breaking is by label name (alphabetical) so the same input
  /// always yields the same row — useful for fixture-based tests.
  static ({String label, double score}) topLabel(Map<String, double> labels) {
    String? bestLabel;
    double bestScore = 0.0;
    for (final entry in labels.entries) {
      if (entry.key == 'Other') continue;
      if (entry.value > bestScore ||
          (entry.value == bestScore &&
              bestLabel != null &&
              entry.key.compareTo(bestLabel) < 0)) {
        bestScore = entry.value;
        bestLabel = entry.key;
      }
    }
    if (bestLabel == null) {
      return (label: 'Other', score: labels['Other'] ?? 0.0);
    }
    return (label: bestLabel, score: bestScore);
  }
}
