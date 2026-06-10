/// OEM onboarding screen — Phase 10.1 (`docs/IMPLEMENTATION.md` §10.1).
///
/// The whole product is "keep the mic alive overnight"; the most common way
/// that fails is the OS killing the recorder foreground service to save
/// power. This screen walks the user through the two things that prevent it:
///
/// 1. **Universal step** — request the battery-optimization whitelist via
///    `permission_handler` (`Permission.ignoreBatteryOptimizations`), which
///    pops the system "allow unrestricted background activity?" dialog. The
///    card reflects live status: a green check once granted, an action
///    button while not. This single step is what matters most on OneOS
///    (the Nothing Phone 3a reference device).
/// 2. **OEM-specific steps** — for known-aggressive vendors (Nothing/OneOS,
///    Samsung, Xiaomi, OnePlus, Oppo/Realme, Vivo, Huawei) an extra card per
///    vendor with the written tap-path and an "Open settings" button that
///    deep-links into the right Settings activity through the native
///    `app.didisnorelastnight/oem` channel — falling back to app-details if
///    the vendor activity can't be resolved.
///
/// The OEM→steps mapping lives in `oem_steps.dart` as the pure, unit-tested
/// `oemStepsFor(...)`; this widget only renders it. The native deep-link is
/// in `oem_channel.dart`. The "seen once" persistence + first-launch gate
/// are in `oem_onboarding_state.dart`.
///
/// **Done CTA** marks onboarding seen and pops. The §10.1 "Test recording
/// (5 min)" verification is offered as a *secondary* action that pops back
/// to Home so the user can run a real recording tonight — we intentionally
/// don't fake a 5-minute timer here; the honest verification is an actual
/// overnight (the Phase 1 smoke test), and Home is where recording starts.
///
/// Styled with the dark design system (`lib/ui/theme/`) — `AppColors.bg`,
/// surface cards, the violet accent, Hanken Grotesk / IBM Plex Mono, big
/// radii — to match Home. **No `print()`** — failures surface as SnackBars.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import '../theme/app_colors.dart';
import '../theme/app_dimens.dart';
import '../theme/app_theme.dart';
import '../widgets/pill.dart';
import 'oem_channel.dart';
import 'oem_onboarding_state.dart';
import 'oem_steps.dart';

class OemOnboardingScreen extends ConsumerStatefulWidget {
  const OemOnboardingScreen({super.key, this.oemChannel = const OemChannel()});

  /// Injectable so widget tests can render without the platform channel.
  final OemChannel oemChannel;

  @override
  ConsumerState<OemOnboardingScreen> createState() =>
      _OemOnboardingScreenState();
}

class _OemOnboardingScreenState extends ConsumerState<OemOnboardingScreen>
    with WidgetsBindingObserver {
  /// Live battery-optimization-whitelist status. `null` while the first
  /// status read is in flight. Refreshed on resume because the user grants
  /// it in a system dialog / Settings, then returns to us.
  bool? _batteryWhitelisted;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refreshBatteryStatus();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // The user leaves to a system dialog / Settings to grant the whitelist,
    // then comes back — re-read so the card flips to the granted state.
    if (state == AppLifecycleState.resumed) _refreshBatteryStatus();
  }

  Future<void> _refreshBatteryStatus() async {
    final status = await Permission.ignoreBatteryOptimizations.status;
    if (!mounted) return;
    setState(() => _batteryWhitelisted = status.isGranted);
  }

  Future<void> _requestBatteryWhitelist() async {
    // Pops the system "allow unrestricted background activity?" dialog.
    await Permission.ignoreBatteryOptimizations.request();
    await _refreshBatteryStatus();
  }

  Future<void> _openOemSettings(OemStep step) async {
    final result = await widget.oemChannel.openOemSettings(step.settingsKey);
    if (!mounted) return;
    // Only message the user when we couldn't deep-link to the vendor
    // screen — then the on-screen written steps are their only guide.
    final message = switch (result) {
      OemSettingsResult.oem => null,
      OemSettingsResult.appDetails =>
        'Opened app settings — follow the steps below from there.',
      OemSettingsResult.batterySettings =>
        'Opened battery settings — follow the steps below from there.',
      OemSettingsResult.none =>
        'Could not open settings automatically — follow the steps below '
            'in your phone\'s Settings app.',
    };
    if (message != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message)),
      );
    }
  }

  Future<void> _markDoneAndPop() async {
    await ref.read(oemOnboardingSeenProvider.notifier).markSeen();
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final make = ref.watch(deviceMakeProvider).valueOrNull ?? DeviceMake.unknown;
    final steps = oemStepsFor(make.manufacturer, brand: make.brand);
    // First step is always the universal battery whitelist; the rest are
    // vendor cards.
    final vendorSteps = steps.where((s) => !s.universal).toList();

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            _Header(onClose: () => Navigator.of(context).maybePop()),
            Expanded(
              child: SingleChildScrollView(
                physics: const BouncingScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(
                    AppSpace.screenH, 4, AppSpace.screenH, 28),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const _Intro(),
                    const SizedBox(height: 18),

                    // ---- Step 1: universal battery whitelist -------------
                    _BatteryStep(
                      granted: _batteryWhitelisted,
                      onRequest: _requestBatteryWhitelist,
                    ),

                    // ---- OEM-specific steps ------------------------------
                    if (vendorSteps.isNotEmpty) ...[
                      const SizedBox(height: 24),
                      Padding(
                        padding: const EdgeInsets.only(left: 2, bottom: 10),
                        child: Text(
                          'STEPS FOR YOUR ${_makeLabel(make)}',
                          style: AppText.eyebrow,
                        ),
                      ),
                      for (final step in vendorSteps) ...[
                        _OemStepCard(
                          step: step,
                          onOpen: () => _openOemSettings(step),
                        ),
                        const SizedBox(height: AppSpace.tileGap),
                      ],
                    ],

                    const SizedBox(height: 18),
                    _DoneButton(onTap: _markDoneAndPop),
                    const SizedBox(height: 12),
                    Center(
                      child: TextButton(
                        onPressed: _markDoneAndPop,
                        style: TextButton.styleFrom(
                          foregroundColor: AppColors.text2,
                        ),
                        child: const Text('I\'ll test it tonight'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Display label for the device's make — falls back to "device" when we
  /// couldn't read it (non-Android / plugin failure) so the header still
  /// reads naturally.
  String _makeLabel(DeviceMake make) {
    final m = make.manufacturer.trim();
    if (m.isEmpty) return 'DEVICE';
    return m.toUpperCase();
  }
}

/// Top bar: title + a close affordance (the screen is reachable both as a
/// first-launch gate and re-opened from Home, so it always offers a way out).
class _Header extends StatelessWidget {
  const _Header({required this.onClose});

  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 16, 12, 6),
      child: Row(
        children: [
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: AppColors.accentDim,
              borderRadius: BorderRadius.circular(9),
              border: Border.all(color: AppColors.accentLine),
            ),
            child: const Icon(Icons.shield_moon_outlined,
                size: 15, color: AppColors.accent),
          ),
          const SizedBox(width: 9),
          const Text(
            'Keep recording alive',
            style: TextStyle(
              fontSize: 15.5,
              fontWeight: FontWeight.w600,
              letterSpacing: -0.15,
              color: AppColors.text1,
            ),
          ),
          const Spacer(),
          IconButton(
            onPressed: onClose,
            icon: const Icon(Icons.close_rounded, size: 20),
            color: AppColors.text2,
            splashRadius: 22,
          ),
        ],
      ),
    );
  }
}

/// The "why" intro above the steps.
class _Intro extends StatelessWidget {
  const _Intro();

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: const [
        SizedBox(height: 6),
        Text('BEFORE YOUR FIRST NIGHT', style: AppText.eyebrow),
        SizedBox(height: 10),
        Text(
          'Your phone may kill the recorder overnight',
          style: TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.w600,
            letterSpacing: -0.4,
            height: 1.15,
            color: AppColors.text1,
          ),
        ),
        SizedBox(height: 10),
        Text(
          'To save power, Android can pause apps running in the background. '
          'For a sleep recorder that means missing audio — or nothing at '
          'all. These steps tell the system to leave the app alone while '
          'you sleep. The first one matters most.',
          style: TextStyle(fontSize: 14.5, height: 1.45, color: AppColors.text2),
        ),
      ],
    );
  }
}

/// Step 1 card — universal battery-optimization whitelist. Shows a live
/// granted/ungranted state: a green check pill when granted, an action
/// button (and warning accent) when not.
class _BatteryStep extends StatelessWidget {
  const _BatteryStep({required this.granted, required this.onRequest});

  /// `null` while the first status read is in flight.
  final bool? granted;
  final VoidCallback onRequest;

  @override
  Widget build(BuildContext context) {
    final isGranted = granted == true;
    return _CardShell(
      // Lift the accent on the most-important step when it's not done.
      highlighted: granted == false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _StepBadge(
                done: isGranted,
                child: Icon(
                  isGranted ? Icons.check_rounded : Icons.bolt_rounded,
                  size: 16,
                  color: isGranted ? AppColors.bg : AppColors.accent,
                ),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Text(
                  batteryOptimizationStep.title,
                  style: const TextStyle(
                    fontSize: 15.5,
                    fontWeight: FontWeight.w600,
                    color: AppColors.text1,
                  ),
                ),
              ),
              if (isGranted)
                Pill(
                  label: 'Done',
                  tone: PillTone.accent,
                  leading: Icon(Icons.check_circle_rounded,
                      size: 14, color: AppColors.star),
                ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            batteryOptimizationStep.body,
            style: const TextStyle(
                fontSize: 13.5, height: 1.4, color: AppColors.text2),
          ),
          if (!isGranted) ...[
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: onRequest,
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.accent,
                  foregroundColor: AppColors.bg,
                  padding: const EdgeInsets.symmetric(vertical: 13),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(AppRadii.medium),
                  ),
                  textStyle: const TextStyle(
                      fontSize: 14.5, fontWeight: FontWeight.w600),
                ),
                child: const Text('Allow background activity'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// One OEM-specific card: title, "why", numbered steps, "Open settings".
class _OemStepCard extends StatelessWidget {
  const _OemStepCard({required this.step, required this.onOpen});

  final OemStep step;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    return _CardShell(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _StepBadge(
                done: false,
                child: const Icon(Icons.tune_rounded,
                    size: 15, color: AppColors.accent),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Text(
                  step.title,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    height: 1.2,
                    color: AppColors.text1,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 9),
          Text(
            step.body,
            style: const TextStyle(
                fontSize: 13, height: 1.4, color: AppColors.text2),
          ),
          const SizedBox(height: 12),
          for (var i = 0; i < step.steps.length; i++)
            Padding(
              padding: EdgeInsets.only(
                  bottom: i == step.steps.length - 1 ? 0 : 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${i + 1}',
                    style: const TextStyle(
                      fontFamily: AppFonts.mono,
                      fontSize: 12.5,
                      color: AppColors.accent,
                      height: 1.35,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      step.steps[i],
                      style: const TextStyle(
                          fontSize: 13.5, height: 1.35, color: AppColors.text1),
                    ),
                  ),
                ],
              ),
            ),
          if (step.settingsKey != null) ...[
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: onOpen,
                icon: const Icon(Icons.open_in_new_rounded, size: 16),
                label: const Text('Open settings'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.accent,
                  side: const BorderSide(color: AppColors.accentLine),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(AppRadii.medium),
                  ),
                  textStyle: const TextStyle(
                      fontSize: 14, fontWeight: FontWeight.w600),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Shared surface card with optional accent highlight (used for the
/// most-important, not-yet-done battery step).
class _CardShell extends StatelessWidget {
  const _CardShell({required this.child, this.highlighted = false});

  final Widget child;
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadii.card),
        border: Border.all(
          color: highlighted ? AppColors.accentLine : AppColors.line,
        ),
      ),
      padding: const EdgeInsets.all(16),
      child: child,
    );
  }
}

/// Small rounded badge at the head of each step. Filled accent when done.
class _StepBadge extends StatelessWidget {
  const _StepBadge({required this.child, required this.done});

  final Widget child;
  final bool done;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 30,
      height: 30,
      decoration: BoxDecoration(
        color: done ? AppColors.accent : AppColors.accentDim,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
            color: done ? Colors.transparent : AppColors.accentLine),
      ),
      child: Center(child: child),
    );
  }
}

/// Primary "Done" CTA — marks onboarding seen and returns.
class _DoneButton extends StatelessWidget {
  const _DoneButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: FilledButton(
        onPressed: onTap,
        style: FilledButton.styleFrom(
          backgroundColor: AppColors.surface2,
          foregroundColor: AppColors.text1,
          padding: const EdgeInsets.symmetric(vertical: 15),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadii.medium),
            side: const BorderSide(color: AppColors.lineStrong),
          ),
          textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
        child: const Text('Done — back to recording'),
      ),
    );
  }
}
