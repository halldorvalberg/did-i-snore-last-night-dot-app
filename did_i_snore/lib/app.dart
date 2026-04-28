/// Top-level app widget for did-i-snore-last-night.app.
///
/// Routes between [ConsentScreen] and [HomeScreen] based on
/// [consentStateProvider]. While the consent state is loading from prefs,
/// shows a centered spinner so we don't flash the consent screen for one
/// frame on cold boot.
///
/// Named routes (`routes:`) are added alongside the `home:` widget so
/// secondary screens reachable from Home — calibration today, more in later
/// phases — can be pushed by name without each caller importing the screen
/// file. The top-level consent gate is unaffected; only post-consent
/// navigation uses the named-route table.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'consent/consent_screen.dart';
import 'consent/consent_state.dart';
import 'ui/home/home_screen.dart';
import 'ui/setup/calibration_screen.dart';

/// Named route for the calibration screen. Exposed as a constant so callers
/// (Home, Settings → Recalibrate) don't sprinkle string literals.
const String calibrationRoute = '/setup/calibration';

class App extends ConsumerWidget {
  const App({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final consent = ref.watch(consentStateProvider);

    return MaterialApp(
      title: 'Did I Snore?',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          // Muted, calm slate-blue. Deliberately not vibrant — this is a
          // sleep-companion app, not a kid's game.
          seedColor: const Color(0xFF4F6D8A),
          brightness: Brightness.light,
        ),
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF4F6D8A),
          brightness: Brightness.dark,
        ),
      ),
      home: switch (consent) {
        ConsentState.unknown => const _LoadingScreen(),
        ConsentState.notGiven => const ConsentScreen(),
        ConsentState.given => const HomeScreen(),
      },
      routes: {
        calibrationRoute: (_) => const CalibrationScreen(),
      },
    );
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
