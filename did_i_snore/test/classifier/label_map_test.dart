/// Contract tests for `LabelMap`.
///
/// Pins the two non-obvious behaviours of the curated aggregation:
///
/// 1. **Within a bucket, take the max — never the sum.** YAMNet routinely
///    emits non-trivial probability on Snoring AND Snort for the same
///    frame; summing them would double-count and push genuine snoring up
///    against `Other`'s catch-all. IMPLEMENTATION.md §5.4 calls this out.
/// 2. **`topLabel` excludes `Other` from the contest.** The reject policy
///    (recorder) compares `maxCurated` to `Other` separately; the row's
///    `top_label` column should never be `Other` unless absolutely no
///    curated class registered, so the timeline UI never shows a sea of
///    "Other" pills.
///
/// We don't load the real CSV here. We build 521-element score / class-name
/// vectors by hand: filler names like `Class42` for indices we don't care
/// about, real AudioSet display names at the indices the test exercises.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:did_i_snore/classifier/label_map.dart';

/// YAMNet has 521 output classes (0..520). Tests use the same width so a
/// regression that changes the assumed length surfaces here too.
const int _yamnetClassCount = 521;

/// Build a 521-long class-name list with [overrides] applied at the given
/// indices and `'Class$i'` filler everywhere else. The filler strings are
/// guaranteed not to appear in [LabelMap.yamnetToCurated] (the curated
/// map's keys are AudioSet display names, none of which match `'Class$i'`),
/// so untouched indices reliably collapse to `Other`.
List<String> _classNames(Map<int, String> overrides) {
  final names = List<String>.generate(_yamnetClassCount, (i) => 'Class$i');
  overrides.forEach((i, name) => names[i] = name);
  return names;
}

/// Build a 521-long score vector with [overrides] applied; everything else
/// is 0.0.
List<double> _scores(Map<int, double> overrides) {
  final s = List<double>.filled(_yamnetClassCount, 0.0);
  overrides.forEach((i, v) => s[i] = v);
  return s;
}

void main() {
  group('LabelMap.aggregate', () {
    test('single-class hit emits only that bucket (zeros are omitted)', () {
      // Snoring is at idx 38 in the real CSV, but aggregation is index-free
      // — pick any slot, label it 'Snoring'.
      final names = _classNames({10: 'Snoring'});
      final scores = _scores({10: 0.8});

      final agg = LabelMap.aggregate(scores, names);

      expect(agg['Snoring'], 0.8);
      // The implementation only inserts when `scores[i] > 0`, so curated
      // buckets that never received a non-zero score (Speech, Cough, ...)
      // are absent. Likewise `Other` — every filler `Class$i` has score 0.
      expect(agg.length, 1,
          reason: 'only buckets with a non-zero contribution should appear; '
              'got $agg');
    });

    test('within-bucket: Snoring=0.5 + Snort=0.4 → Snoring=0.5 (max, not sum)',
        () {
      // The headline test from the brief. If this returns 0.9 the
      // aggregation is summing — that double-counts and breaks the reject
      // policy (a genuine snore would inflate `maxCurated` and a false
      // co-firing would too). IMPLEMENTATION.md §5.4 line 698-699 is
      // explicit: take max within bucket.
      final names = _classNames({10: 'Snoring', 20: 'Snort'});
      final scores = _scores({10: 0.5, 20: 0.4});

      final agg = LabelMap.aggregate(scores, names);

      expect(agg['Snoring'], 0.5,
          reason: 'Snoring + Snort must collapse via max, not sum');
      expect(agg.length, 1, reason: 'no other bucket should appear');
    });

    test('within-bucket: ordering does not matter (Snort first, Snoring second)',
        () {
      // Order of iteration matters in the implementation
      // (`(out[curated] ?? 0) < scores[i]` only overwrites going up). Pin
      // that the higher score still wins regardless of which AudioSet
      // class produced it.
      final names = _classNames({10: 'Snort', 20: 'Snoring'});
      final scores = _scores({10: 0.9, 20: 0.4});

      final agg = LabelMap.aggregate(scores, names);

      expect(agg['Snoring'], 0.9);
    });

    test('cross-bucket independence: Speech=0.6 + Snoring=0.4 stay separate',
        () {
      final names = _classNames({10: 'Speech', 20: 'Snoring'});
      final scores = _scores({10: 0.6, 20: 0.4});

      final agg = LabelMap.aggregate(scores, names);

      expect(agg['Speech'], 0.6);
      expect(agg['Snoring'], 0.4);
      expect(agg.containsKey('Other'), isFalse);
    });

    test('Other catch-all: unmapped classes fold to Other (max within Other)',
        () {
      // 'Vehicle' and 'Music' are real AudioSet names but not in the
      // curated map — both must collapse into the same `Other` bucket,
      // and the bucket itself takes the max.
      final names = _classNames({10: 'Vehicle', 20: 'Music'});
      final scores = _scores({10: 0.3, 20: 0.5});

      final agg = LabelMap.aggregate(scores, names);

      expect(agg['Other'], 0.5,
          reason: 'two unmapped classes at 0.3 and 0.5 → Other = 0.5');
    });

    test('all-zero input returns empty map (zeros are not inserted)', () {
      final names = _classNames({10: 'Snoring', 20: 'Speech'});
      final scores = _scores({}); // every entry 0.0

      final agg = LabelMap.aggregate(scores, names);

      // Pin the spec's documented behaviour: `(out[curated] ?? 0) <
      // scores[i]` is false when `scores[i] == 0`, so nothing gets
      // inserted. The recorder's reject policy treats a missing key as 0,
      // so this is fine — but downstream code that iterates `agg.entries`
      // depends on it.
      expect(agg, isEmpty);
    });

    test('every Snoring bucket source name routes to "Snoring"', () {
      // Two AudioSet classes (Snoring, Snort) feed Snoring. If anyone
      // ever renames the curated label to e.g. `'snore'`, this breaks
      // immediately — including this test means the rename is intentional.
      for (final src in ['Snoring', 'Snort']) {
        final names = _classNames({10: src});
        final scores = _scores({10: 0.7});
        expect(LabelMap.aggregate(scores, names)['Snoring'], 0.7,
            reason: '$src must route to Snoring');
      }
    });

    test('every Dog bucket source name routes to "Dog"', () {
      for (final src in ['Dog', 'Bark', 'Whimper (dog)']) {
        final names = _classNames({10: src});
        final scores = _scores({10: 0.7});
        expect(LabelMap.aggregate(scores, names)['Dog'], 0.7,
            reason: '$src must route to Dog');
      }
    });

    test('every Cat bucket source name routes to "Cat"', () {
      for (final src in ['Cat', 'Meow', 'Purr']) {
        final names = _classNames({10: src});
        final scores = _scores({10: 0.7});
        expect(LabelMap.aggregate(scores, names)['Cat'], 0.7,
            reason: '$src must route to Cat');
      }
    });

    test('every Speech bucket source name routes to "Speech"', () {
      for (final src in ['Speech', 'Conversation']) {
        final names = _classNames({10: src});
        final scores = _scores({10: 0.7});
        expect(LabelMap.aggregate(scores, names)['Speech'], 0.7,
            reason: '$src must route to Speech');
      }
    });

    test('plain "Whimper" (the human one) is NOT mapped to Dog', () {
      // The class map docstring is explicit about this — only "Whimper
      // (dog)" feeds Dog; bare "Whimper" (AudioSet idx 21, the human
      // distress one) collapses to Other.
      final names = _classNames({10: 'Whimper'});
      final scores = _scores({10: 0.7});

      final agg = LabelMap.aggregate(scores, names);

      expect(agg.containsKey('Dog'), isFalse);
      expect(agg['Other'], 0.7);
    });
  });

  group('LabelMap.topLabel', () {
    test('returns the highest curated bucket', () {
      final top = LabelMap.topLabel({
        'Snoring': 0.7,
        'Speech': 0.4,
        'Other': 0.1,
      });
      expect(top.label, 'Snoring');
      expect(top.score, 0.7);
    });

    test('excludes Other from the contest even when Other dominates', () {
      // The recorder gets the curated answer here; the reject policy
      // (which sees the raw map separately) decides whether to drop the
      // whole event. `topLabel` must never return Other when ANY curated
      // class has a non-zero score — otherwise the timeline shows
      // "Other" pills next to genuine signal.
      final top = LabelMap.topLabel({
        'Snoring': 0.6,
        'Other': 0.9,
      });
      expect(top.label, 'Snoring');
      expect(top.score, 0.6);
    });

    test('falls back to Other when no curated class has a non-zero score', () {
      final top = LabelMap.topLabel({'Other': 0.4});
      expect(top.label, 'Other');
      expect(top.score, 0.4);
    });

    test('falls back to Other = 0.0 when the input map is empty', () {
      // The aggregate-of-all-zeros case: aggregate returns {}, and the
      // recorder calls topLabel on it. Must not throw, must return a
      // sane sentinel.
      final top = LabelMap.topLabel(const {});
      expect(top.label, 'Other');
      expect(top.score, 0.0);
    });

    test('tie-breaks alphabetically by curated label name', () {
      // Implementation: tie-break is `entry.key.compareTo(bestLabel) < 0`
      // — i.e. earlier alphabetically wins. Pin this so a refactor that
      // accidentally changes the comparator (or removes the deterministic
      // tie-break entirely, leaving Map insertion order) trips this test.
      final top = LabelMap.topLabel({
        'Snoring': 0.5,
        'Cough': 0.5,
        'Speech': 0.5,
      });
      expect(top.label, 'Cough',
          reason: 'Cough < Snoring < Speech alphabetically');
      expect(top.score, 0.5);
    });

    test('tie-break independence from Map insertion order', () {
      // Same scores, different insertion order — must yield the same
      // answer. Caught a previous "first-seen wins" implementation.
      final top1 = LabelMap.topLabel({'Speech': 0.5, 'Cough': 0.5});
      final top2 = LabelMap.topLabel({'Cough': 0.5, 'Speech': 0.5});
      expect(top1.label, top2.label);
      expect(top1.label, 'Cough');
    });

    test('a curated bucket with score 0.0 does not beat the Other fallback',
        () {
      // The implementation seeds `bestScore = 0.0` and only updates on
      // strictly greater (or alphabetic tie at the current best). So
      // `{'Snoring': 0.0}` should fall through to the Other fallback —
      // pin that so a future change to `>=` doesn't silently surface
      // zero-score curated labels in the timeline.
      final top = LabelMap.topLabel({'Snoring': 0.0, 'Other': 0.0});
      expect(top.label, 'Other');
      expect(top.score, 0.0);
    });
  });

  group('LabelMap.yamnetToCurated', () {
    test('contains the 17 documented AudioSet source names', () {
      // The class map docstring claims all 17 names are present and
      // verified against the CSV. Pin the count so an accidental
      // deletion breaks here, not silently in the wild.
      const expected = {
        'Snoring', 'Snort',
        'Speech', 'Conversation',
        'Whispering',
        'Cough', 'Sneeze', 'Throat clearing',
        'Burping, eructation', 'Fart', 'Hiccup',
        'Cat', 'Meow', 'Purr',
        'Dog', 'Bark', 'Whimper (dog)',
      };
      expect(LabelMap.yamnetToCurated.keys.toSet(), expected);
    });

    test('every value is one of the 11 curated buckets (no typos)', () {
      // If someone fat-fingers `'Snoring' → 'snoring'` it ends up as a
      // de-facto new bucket and the recorder's reject policy (which
      // compares against a hardcoded set) silently breaks.
      const curatedBuckets = {
        'Snoring', 'Speech', 'Whisper', 'Cough', 'Sneeze',
        'Throat clearing', 'Belch', 'Fart', 'Hiccup', 'Cat', 'Dog',
      };
      for (final v in LabelMap.yamnetToCurated.values) {
        expect(curatedBuckets.contains(v), isTrue,
            reason: 'unexpected curated value: $v');
      }
    });
  });
}
