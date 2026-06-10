/// Phase 0 smoke tests.
///
/// Verifies the consent state provider observes empty prefs as `notGiven`,
/// and that `App` renders the consent screen in that case.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:did_i_snore/app.dart';
import 'package:did_i_snore/consent/consent_state.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets(
    'shows consent screen on first launch with empty prefs',
    (tester) async {
      await tester.pumpWidget(const ProviderScope(child: App()));
      // Pump past the async load of SharedPreferences.
      await tester.pumpAndSettle();

      expect(find.text('What this app records'), findsOneWidget);
      expect(find.text('Next'), findsOneWidget);
    },
  );

  testWidgets(
    'shows home screen when consent is already granted',
    (tester) async {
      SharedPreferences.setMockInitialValues({consentPrefsKey: true});

      await tester.pumpWidget(const ProviderScope(child: App()));
      // The redesigned home has ambient breathing/pulse animations that
      // never settle, so `pumpAndSettle` would time out — pump a couple
      // of frames to clear the async prefs load instead.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // Phase 8 + design retrofit: the title bar ("Did I Snore?") stays;
      // when not recording the hero shows the "Good night" greeting.
      // (Prefs are empty here → no calibration → the record button is
      // disabled and the hero prompts to calibrate.)
      expect(find.text('Did I Snore?'), findsOneWidget);
      expect(find.text('Good night'), findsOneWidget);
      expect(find.text('Calibrate your room to start'), findsOneWidget);
    },
  );

  test('ConsentController.setGiven persists and flips state', () async {
    SharedPreferences.setMockInitialValues({});
    final container = ProviderContainer();
    // Eagerly mount the provider so the constructor's async `_load()` starts.
    container.read(consentStateProvider);

    // Yield until prefs load completes — the controller's _load awaits a
    // single Future from SharedPreferences.getInstance(), so two
    // microtask hops is enough.
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(container.read(consentStateProvider), ConsentState.notGiven);

    await container.read(consentStateProvider.notifier).setGiven();
    expect(container.read(consentStateProvider), ConsentState.given);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(consentPrefsKey), true);

    container.dispose();
  });
}
