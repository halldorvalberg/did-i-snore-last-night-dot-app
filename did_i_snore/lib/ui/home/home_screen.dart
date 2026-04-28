/// Phase 0 placeholder Home screen.
///
/// Real Home is built in Phase 8 (single big Start/Stop button, elapsed time,
/// "View last night's events" link). This stub exists so the consent flow
/// has somewhere to land, and so we can confirm end-to-end that prefs +
/// router work.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../consent/consent_state.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Did I Snore?'),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const _PhaseBadge(),
              const SizedBox(height: 24),
              Text(
                'Bootstrap only',
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'Recording arrives in Phase 2. Today the app proves the '
                'consent flow, the no-network privacy lockdown, and the '
                'build pipeline.',
                style: theme.textTheme.bodyLarge?.copyWith(height: 1.5),
              ),
              const Spacer(),
              if (kDebugMode)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: () =>
                        ref.read(consentStateProvider.notifier).reset(),
                    icon: const Icon(Icons.refresh),
                    label: const Text('Reset consent (debug)'),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PhaseBadge extends StatelessWidget {
  const _PhaseBadge();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: scheme.tertiaryContainer,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        'PHASE 0 - BOOTSTRAP',
        style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: scheme.onTertiaryContainer,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.6,
            ),
      ),
    );
  }
}
