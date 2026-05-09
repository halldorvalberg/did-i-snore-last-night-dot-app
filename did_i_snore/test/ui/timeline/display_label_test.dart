/// Tests for the display-label helper.
///
/// Spec: `docs/IMPLEMENTATION.md` §8 lines 893–900. Priority order:
/// `userLabel` > `topLabel` > `'Other'`. Critically, the helper does
/// NOT decode `labelsJson` — that's pre-computed at `markReady`.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:did_i_snore/data/db.dart';
import 'package:did_i_snore/ui/timeline/display_label.dart';

Event _row({
  String? topLabel,
  String? userLabel,
}) {
  return Event(
    id: 1,
    startedAt: 0,
    endedAt: 1,
    durationMs: 1,
    createdAt: 0,
    schemaVersion: 1,
    state: 'ready',
    topLabel: topLabel,
    labelsJson: null,
    audioPath: 'events/x.opus',
    peaksPath: null,
    starred: false,
    userLabel: userLabel,
    deletedAt: null,
  );
}

void main() {
  group('displayLabel', () {
    test('userLabel wins when set', () {
      final e = _row(topLabel: 'Snoring', userLabel: 'My override');
      expect(displayLabel(e), 'My override');
    });

    test('topLabel falls through when userLabel is null', () {
      final e = _row(topLabel: 'Snoring');
      expect(displayLabel(e), 'Snoring');
    });

    test('"Other" fallback when both topLabel and userLabel are null', () {
      final e = _row();
      expect(displayLabel(e), 'Other');
    });

    test('empty userLabel string is still preferred over topLabel', () {
      // The helper checks `userLabel != null`, not non-empty. This is
      // intentional: an empty user override is still a user choice.
      final e = _row(topLabel: 'Snoring', userLabel: '');
      expect(displayLabel(e), '');
    });
  });
}
