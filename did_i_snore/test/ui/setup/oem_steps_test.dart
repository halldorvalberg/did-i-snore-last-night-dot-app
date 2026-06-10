/// Unit tests for the pure OEM→steps mapping (`lib/ui/setup/oem_steps.dart`).
///
/// The instruction copy is the load-bearing part of the onboarding feature,
/// and it's extracted from the widget precisely so it can be tested in
/// isolation. We assert:
///
/// - Every device gets the universal battery-optimization step first.
/// - Known-aggressive OEMs append exactly one matching vendor step, keyed
///   off manufacturer OR brand, case-insensitively.
/// - An unknown / stock OEM (Pixel, generic) returns ONLY the universal step.
/// - The reference device (Nothing / OneOS) is covered.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:did_i_snore/ui/setup/oem_steps.dart';

void main() {
  group('oemStepsFor', () {
    test('always starts with the universal battery step, marked universal', () {
      final steps = oemStepsFor('Google', brand: 'Pixel');
      expect(steps.first.universal, isTrue);
      expect(steps.first.settingsKey, isNull,
          reason: 'universal step goes through permission_handler, not a '
              'native deep-link');
    });

    test('unknown / stock OEM returns only the universal step', () {
      expect(oemStepsFor('Google', brand: 'Pixel').length, 1);
      expect(oemStepsFor('', brand: '').length, 1);
      expect(oemStepsFor('SomeUnheardOfVendor').length, 1);
      expect(hasOemSpecificSteps('Google', brand: 'Pixel'), isFalse);
    });

    test('Nothing / OneOS (the reference device) gets a vendor step', () {
      final steps = oemStepsFor('Nothing', brand: 'Nothing');
      expect(steps.length, 2);
      expect(steps[1].settingsKey, 'nothing');
      expect(steps[1].title.toLowerCase(), contains('nothing'));
      expect(steps[1].steps, isNotEmpty);
      expect(hasOemSpecificSteps('Nothing'), isTrue);
    });

    test('Samsung gets the never-sleeping-apps step', () {
      final steps = oemStepsFor('samsung', brand: 'Galaxy');
      expect(steps.length, 2);
      expect(steps[1].settingsKey, 'samsung');
      expect(steps[1].body.toLowerCase(), contains('sleep'));
    });

    test('Xiaomi matches on manufacturer and on Redmi/POCO brands', () {
      for (final make in [
        ('Xiaomi', ''),
        ('Xiaomi', 'Redmi'),
        ('Xiaomi', 'POCO'),
        ('', 'redmi'),
      ]) {
        final steps = oemStepsFor(make.$1, brand: make.$2);
        expect(steps.any((s) => s.settingsKey == 'xiaomi'), isTrue,
            reason: 'make $make should resolve to the Xiaomi step');
      }
    });

    test('Oppo and Realme share the same security-center step', () {
      expect(oemStepsFor('OPPO')[1].settingsKey, 'oppo');
      expect(oemStepsFor('realme')[1].settingsKey, 'oppo');
    });

    test('OnePlus, Vivo, Huawei each map to their own vendor step', () {
      expect(oemStepsFor('OnePlus')[1].settingsKey, 'oneplus');
      expect(oemStepsFor('vivo')[1].settingsKey, 'vivo');
      expect(oemStepsFor('HUAWEI')[1].settingsKey, 'huawei');
      // Honor rides the Huawei branch.
      expect(oemStepsFor('Honor')[1].settingsKey, 'huawei');
    });

    test('matching is case-insensitive and substring-based', () {
      expect(hasOemSpecificSteps('SAMSUNG'), isTrue);
      expect(hasOemSpecificSteps('samsung electronics co'), isTrue);
    });

    test('every vendor step carries a settingsKey and written steps', () {
      for (final make in [
        'Nothing',
        'samsung',
        'xiaomi',
        'oneplus',
        'oppo',
        'vivo',
        'huawei',
      ]) {
        final vendor = oemStepsFor(make).where((s) => !s.universal);
        for (final step in vendor) {
          expect(step.settingsKey, isNotNull,
              reason: '$make vendor step needs a deep-link key');
          expect(step.steps, isNotEmpty,
              reason: '$make vendor step needs written fallback steps');
          expect(step.title, isNotEmpty);
        }
      }
    });
  });
}
