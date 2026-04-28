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
      await tester.pumpAndSettle();

      expect(find.text('Did I Snore?'), findsOneWidget);
      expect(find.text('Bootstrap only'), findsOneWidget);
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
