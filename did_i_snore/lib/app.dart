/// Top-level app widget for did-i-snore-last-night.app.
///
/// Routes between [ConsentScreen] and [HomeScreen] based on
/// [consentStateProvider]. While the consent state is loading from prefs,
/// shows a centered spinner so we don't flash the consent screen for one
/// frame on cold boot.
///
/// Named routes (`routes:` for argument-free destinations,
/// `onGenerateRoute` for routes that take typed arguments) are
/// registered alongside the `home:` widget so secondary screens
/// reachable from Home — calibration, timeline, player — can be pushed
/// by name without each caller importing the screen file. The top-level
/// consent gate is unaffected; only post-consent navigation uses the
/// named-route table.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'consent/consent_screen.dart';
import 'consent/consent_state.dart';
import 'data/db.dart' show Event;
import 'ui/home/home_screen.dart';
import 'ui/manage_storage/manage_storage_screen.dart';
import 'ui/player/player_screen.dart';
import 'ui/setup/calibration_screen.dart';
import 'ui/setup/oem_onboarding.dart';
import 'ui/setup/oem_onboarding_state.dart';
import 'ui/theme/app_theme.dart';
import 'ui/timeline/timeline_screen.dart';

/// Named route for the calibration screen. Argument-free; lives under
/// `routes:` in the route table.
const String calibrationRoute = '/setup/calibration';

/// Named route for the per-night timeline. Argument: `DateTime night`,
/// the local-day midnight-floor produced by `nightOf`.
const String timelineRoute = '/timeline';

/// Named route for the player. Argument: `Event` — the row to play.
const String playerRoute = '/player';

/// Named route for Manage Storage (Phase 9). Argument-free; lives
/// under `routes:` in the route table.
const String manageStorageRoute = '/manage-storage';

/// Named route for the Android OEM onboarding screen (Phase 10.1).
/// Argument-free; lives under `routes:`. Reachable two ways: auto-surfaced
/// once after consent on first Android launch (via [_HomeGate]), and
/// re-openable from Home.
const String oemOnboardingRoute = '/setup/oem-onboarding';

class App extends ConsumerWidget {
  const App({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final consent = ref.watch(consentStateProvider);

    return MaterialApp(
      title: 'Did I Snore?',
      debugShowCheckedModeBanner: false,
      // Dark-only by design — used in a dark bedroom and a groggy morning.
      // The "Did I Snore?" design tokens live in `lib/ui/theme/`.
      theme: AppTheme.dark(),
      darkTheme: AppTheme.dark(),
      themeMode: ThemeMode.dark,
      home: switch (consent) {
        ConsentState.unknown => const _LoadingScreen(),
        ConsentState.notGiven => const ConsentScreen(),
        ConsentState.given => const _HomeGate(),
      },
      routes: {
        calibrationRoute: (_) => const CalibrationScreen(),
        manageStorageRoute: (_) => const ManageStorageScreen(),
        oemOnboardingRoute: (_) => const OemOnboardingScreen(),
      },
      onGenerateRoute: (settings) {
        switch (settings.name) {
          case timelineRoute:
            // The home screen pushes a `DateTime` for "last night";
            // anything else is a programmer error. We default to today
            // as a defensive fallback rather than throwing — losing
            // the date is less harmful than crashing the app.
            final arg = settings.arguments;
            final night = arg is DateTime
                ? arg
                : DateTime(
                    DateTime.now().year,
                    DateTime.now().month,
                    DateTime.now().day,
                  );
            return MaterialPageRoute(
              settings: settings,
              builder: (_) => TimelineScreen(night: night),
            );
          case playerRoute:
            final arg = settings.arguments;
            if (arg is! Event) {
              // Without an Event there is nothing to play; pop back.
              return MaterialPageRoute(
                settings: settings,
                builder: (_) => const _PlayerArgumentError(),
              );
            }
            return MaterialPageRoute(
              settings: settings,
              builder: (_) => PlayerScreen(event: arg),
            );
        }
        return null;
      },
    );
  }
}

/// Post-consent gate. Always renders [HomeScreen] (so the consent→home path
/// and the existing widget tests are unaffected), and — only on Android, and
/// only once — pushes the OEM onboarding screen over it on first reach.
///
/// Why a push-over-Home gate rather than swapping `home:`: Home is the right
/// resting place, the onboarding is a one-time interstitial the user
/// dismisses back to Home, and rendering Home underneath means the test host
/// (non-Android, where [shouldShowOemOnboardingProvider] is always false)
/// lands directly on Home with nothing pushed. The "seen" pref is flipped by
/// the onboarding screen's Done CTA, so this fires at most once.
class _HomeGate extends ConsumerStatefulWidget {
  const _HomeGate();

  @override
  ConsumerState<_HomeGate> createState() => _HomeGateState();
}

class _HomeGateState extends ConsumerState<_HomeGate> {
  /// Guards against pushing twice if the build re-runs while the async
  /// "seen" pref is still resolving.
  bool _pushed = false;

  @override
  Widget build(BuildContext context) {
    // Watch so that once the async "seen" pref resolves to `no` on Android,
    // we get a rebuild and schedule the one-time push.
    if (!_pushed && ref.watch(shouldShowOemOnboardingProvider)) {
      _pushed = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        Navigator.of(context).pushNamed(oemOnboardingRoute);
      });
    }
    return const HomeScreen();
  }
}

class _LoadingScreen extends StatelessWidget {
  const _LoadingScreen();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(child: CircularProgressIndicator()),
    );
  }
}

class _PlayerArgumentError extends StatelessWidget {
  const _PlayerArgumentError();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Player')),
      body: const Center(
        child: Text('No event selected.'),
      ),
    );
  }
}
