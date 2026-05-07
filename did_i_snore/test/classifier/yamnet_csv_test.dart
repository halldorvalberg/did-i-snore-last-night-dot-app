/// Host-runnable parser tests for `Yamnet.displayNameFromCsvRow`.
///
/// `yamnet_test.dart` exercises end-to-end load + classify and is skipped
/// on Linux (no native tflite). The CSV parser, however, is pure Dart and
/// can run on any host — and a regression here would silently route
/// "Burping, eructation" to `Other` instead of `Belch` (the row count
/// check in `Yamnet.load()` does NOT catch a mis-parse, since the row
/// count is unchanged). These tests pin the contract directly.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:did_i_snore/classifier/label_map.dart';
import 'package:did_i_snore/classifier/yamnet.dart';

void main() {
  group('Yamnet.displayNameFromCsvRow', () {
    test('plain row: comma-free display name comes through unchanged', () {
      // Row 0 of the canonical class map.
      expect(
        Yamnet.displayNameFromCsvRow('0,/m/09x0r,Speech'),
        'Speech',
      );
    });

    test('row 53: "Burping, eructation" parses with internal comma intact',
        () {
      // Verbatim from assets/models/yamnet_class_map.csv. The pre-fix
      // implementation would have returned `"Burping` and silently routed
      // this entry to `Other` instead of `Belch`.
      expect(
        Yamnet.displayNameFromCsvRow('53,/m/03q5_w,"Burping, eructation"'),
        'Burping, eructation',
      );
    });

    test('parsed name matches the LabelMap.yamnetToCurated key for Belch',
        () {
      // Belt-and-braces: the parser output must be byte-identical to the
      // key in LabelMap, otherwise the lookup falls through to `Other`.
      final parsed =
          Yamnet.displayNameFromCsvRow('53,/m/03q5_w,"Burping, eructation"');
      expect(LabelMap.yamnetToCurated[parsed], 'Belch');
    });

    test('row with trailing whitespace: name is trimmed', () {
      // Some CSV writers append \r before \n — after split('\n') a trailing
      // \r can remain on the row. The parser trims whitespace.
      expect(
        Yamnet.displayNameFromCsvRow('53,/m/03q5_w,"Burping, eructation"\r'),
        'Burping, eructation',
      );
    });

    test('malformed row (one comma) throws FormatException', () {
      // Defensive contract: a row missing the second comma is not a valid
      // class-map row and the parser refuses it rather than silently
      // returning garbage.
      expect(
        () => Yamnet.displayNameFromCsvRow('0,no-second-comma'),
        throwsA(isA<FormatException>()),
      );
    });

    test('canonical curated keys all parse cleanly', () {
      // Synthetic rows that mirror canonical CSV format, including the two
      // quoted-display-name keys present in LabelMap.yamnetToCurated.
      // (Whimper (dog) is the only other parenthesized one.) Confirms no
      // collateral damage from the quote-stripping path on common rows.
      const samples = <String, String>{
        '0,/m/09x0r,Speech': 'Speech',
        '38,/m/01h8n0,Conversation': 'Conversation',
        '42,/m/02zsn,Whispering': 'Whispering',
        '47,/m/0463cq4,"Burping, eructation"': 'Burping, eructation',
        '54,/t/dd00038,Hiccup': 'Hiccup',
        '75,/m/05tny_,Whimper (dog)': 'Whimper (dog)',
      };
      samples.forEach((row, expected) {
        expect(
          Yamnet.displayNameFromCsvRow(row),
          expected,
          reason: 'row: $row',
        );
      });
    });
  });
}
