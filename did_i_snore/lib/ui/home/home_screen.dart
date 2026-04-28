/// Phase 0 placeholder Home screen, now extended in Phase 3 with a
/// "Calibrate this room" entry point.
///
/// Real Home is built in Phase 8 (single big Start/Stop button, elapsed time,
/// "View last night's events" link). This stub keeps the consent flow and
/// router wiring honest, plus serves as the launch surface for calibration
/// while the full home arrives later.
///
/// On a successful calibration, the screen records the most recent
/// `NoiseFloor` for display ("Calibrated: floor X dBFS, threshold Y dBFS").
/// Persisting it to disk is the calibrator engine's job, not ours; the local
/// state here is purely a UX courtesy so the user gets immediate feedback
/// after pressing Save.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app.dart';
import '../../consent/consent_state.dart';
import '../../recorder/calibrator.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  /// Latest calibration returned from the calibration screen. Null until
  /// the user has run calibration this session. Display-only; calibrator
  /// engine persists the canonical value separately.
  NoiseFloor? _lastCalibration;

  Future<void> _openCalibration() async {
    final result = await Navigator.of(context).pushNamed<Object?>(
      calibrationRoute,
    );
    if (!mounted) return;
    if (result is NoiseFloor) {
      setState(() => _lastCalibration = result);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Calibration saved. Floor ${result.medianDbfs.toStringAsFixed(1)} '
            'dBFS, threshold ${result.tHighDbfs.toStringAsFixed(1)} dBFS.',
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
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
              const SizedBox(height: 28),
              FilledButton.icon(
                onPressed: _openCalibration,
                icon: const Icon(Icons.tune),
                label: const Text('Calibrate this room'),
              ),
              if (_lastCalibration != null) ...[
                const SizedBox(height: 12),
                Text(
                  'Calibrated: floor '
                  '${_lastCalibration!.medianDbfs.toStringAsFixed(1)} dBFS, '
                  'threshold '
                  '${_lastCalibration!.tHighDbfs.toStringAsFixed(1)} dBFS.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
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
