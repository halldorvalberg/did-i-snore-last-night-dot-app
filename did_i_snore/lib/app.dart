/// Top-level app widget for did-i-snore-last-night.app.
///
/// Routes between [ConsentScreen] and [HomeScreen] based on
/// [consentStateProvider]. While the consent state is loading from prefs,
/// shows a centered spinner so we don't flash the consent screen for one
/// frame on cold boot.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'consent/consent_screen.dart';
import 'consent/consent_state.dart';
import 'ui/home/home_screen.dart';

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
