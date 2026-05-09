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
import 'ui/player/player_screen.dart';
import 'ui/setup/calibration_screen.dart';
import 'ui/timeline/timeline_screen.dart';

/// Named route for the calibration screen. Argument-free; lives under
/// `routes:` in the route table.
const String calibrationRoute = '/setup/calibration';

/// Named route for the per-night timeline. Argument: `DateTime night`,
/// the local-day midnight-floor produced by `nightOf`.
const String timelineRoute = '/timeline';

/// Named route for the player. Argument: `Event` — the row to play.
const String playerRoute = '/player';

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
