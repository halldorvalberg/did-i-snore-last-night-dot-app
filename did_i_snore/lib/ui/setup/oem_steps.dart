/// OEM-specific battery / autostart instructions — Phase 10.1.
///
/// This file is the **pure, testable core** of the OEM onboarding flow.
/// It maps a device manufacturer/brand string (as reported by
/// `device_info_plus` `AndroidDeviceInfo.manufacturer` / `.brand`) onto a
/// small, ordered list of [OemStep]s the UI renders verbatim. No Flutter,
/// no platform channels, no I/O — so the mapping can be unit-tested in
/// isolation (`test/ui/setup/oem_steps_test.dart`).
///
/// Why a data structure and not `if (brand == 'samsung') Text(...)` buried
/// in `build`: the instruction copy is the load-bearing part of this
/// feature (the whole screen exists so the user follows the right steps on
/// their exact phone), and it changes per OEM/ROM version as vendors move
/// Settings activities around. Keeping it as data means we can diff it,
/// test it, and regenerate the UI from it without touching widget code.
///
/// The instruction text is based on `docs/IMPLEMENTATION.md` §10.1. Each
/// OEM's [OemStep.settingsKey] is the token the native deep-link handler
/// (`MainActivity.kt`, channel `app.didisnorelastnight/oem`) switches on to
/// try the vendor's autostart/battery activity, always falling back to this
/// app's app-details screen if the activity can't be resolved.
library;

/// One actionable instruction block in the onboarding flow.
class OemStep {
  const OemStep({
    required this.title,
    required this.body,
    required this.steps,
    this.settingsKey,
    this.universal = false,
  });

  /// Short heading, e.g. "Allow background activity".
  final String title;

  /// One-line "why" shown under the title.
  final String body;

  /// The concrete tap-path the user follows once the settings screen
  /// opens (the native deep-link drops them close, but OEMs differ enough
  /// that we always show the written path as the source of truth).
  final List<String> steps;

  /// Token passed to the native `openOemSettings` deep-link. `null` means
  /// "no vendor deep-link" — used for the universal battery-optimization
  /// step, which goes through `permission_handler` instead, and as a
  /// signal to the UI to omit the "Open settings" button.
  final String? settingsKey;

  /// True only for the universal battery-optimization whitelist step,
  /// which the UI renders specially (live permission status + system
  /// dialog request) rather than as a deep-link card.
  final bool universal;
}

/// The universal first step shown on **every** Android device: request the
/// battery-optimization whitelist. This is the single most important step
/// for OneOS / the Nothing Phone 3a, which is aggressive about Doze.
///
/// The UI requests `Permission.ignoreBatteryOptimizations` (system dialog)
/// for this step rather than deep-linking, so [OemStep.settingsKey] is null.
const OemStep batteryOptimizationStep = OemStep(
  title: 'Allow unrestricted background activity',
  body: 'Android may pause the recorder overnight to save power. This '
      'exempts the app so the mic stays alive while you sleep.',
  steps: [
    'Tap the button below and choose "Allow" when Android asks to let the '
        'app run in the background without restrictions.',
  ],
  universal: true,
);

/// Returns the ordered onboarding steps for a device.
///
/// Always starts with [batteryOptimizationStep]. For known-aggressive OEMs
/// it appends one or more vendor-specific autostart/background steps. For an
/// unknown / stock OEM (Pixel, generic) it returns just the universal step —
/// stock Android needs nothing more.
///
/// [manufacturer] and [brand] are matched case-insensitively against
/// substrings, because vendors report inconsistently (e.g. manufacturer
/// "Xiaomi" but brand "Redmi"/"POCO"; manufacturer "Nothing" but brand
/// "Nothing"). Passing both is preferred; passing only one is fine.
List<OemStep> oemStepsFor(String manufacturer, {String brand = ''}) {
  final hay = '${manufacturer.toLowerCase()} ${brand.toLowerCase()}';
  bool has(String needle) => hay.contains(needle);

  final steps = <OemStep>[batteryOptimizationStep];

  // Nothing / OneOS — the actual reference device (Nothing Phone 3a,
  // Android 16). OneOS layers an extra app-battery-management toggle on top
  // of stock Doze; the unrestricted setting there is what keeps the FGS
  // alive overnight. Nothing reports manufacturer "Nothing", brand
  // "Nothing".
  if (has('nothing')) {
    steps.add(const OemStep(
      title: 'Nothing OS — app battery management',
      body: 'OneOS / Nothing OS can still sleep the app even after the step '
          'above. Set it to unrestricted here too.',
      settingsKey: 'nothing',
      steps: [
        'Settings → Battery → App battery management (or "Battery '
            'optimisation").',
        'Find "Did I Snore?" in the list.',
        'Set it to "Don\'t optimise" / "Unrestricted".',
        'If there is an "Auto-start" or "Allow background activity" toggle '
            'on the app\'s info page, turn it on as well.',
      ],
    ));
  }

  // Samsung One UI.
  if (has('samsung')) {
    steps.add(const OemStep(
      title: 'Samsung — never-sleeping app',
      body: 'One UI puts unused apps to "deep sleep". Add the app to the '
          'never-sleeping list so it is exempt.',
      settingsKey: 'samsung',
      steps: [
        'Settings → Battery → Background usage limits.',
        'Open "Never sleeping apps".',
        'Tap "+" / Add and select "Did I Snore?".',
        'Make sure the app is NOT in "Sleeping" or "Deep sleeping apps".',
      ],
    ));
  }

  // Xiaomi / Redmi / POCO (MIUI / HyperOS).
  if (has('xiaomi') || has('redmi') || has('poco')) {
    steps.add(const OemStep(
      title: 'Xiaomi (MIUI / HyperOS) — autostart + no restrictions',
      body: 'MIUI kills background apps unless Autostart is on and the '
          'battery saver is set to no restrictions.',
      settingsKey: 'xiaomi',
      steps: [
        'Settings → Apps → Manage apps → "Did I Snore?".',
        'Set "Battery saver" to "No restrictions".',
        'Turn "Autostart" ON.',
        'In recent-apps, swipe up gently and tap the lock icon on the app '
            'card so MIUI won\'t clear it.',
      ],
    ));
  }

  // OnePlus (OxygenOS) — shares the ColorOS lineage with Oppo/Realme but
  // its battery path is worded differently, so it gets its own step.
  if (has('oneplus')) {
    steps.add(const OemStep(
      title: 'OnePlus — don\'t optimise',
      body: 'OxygenOS optimises background apps by default. Exempt this '
          'one and allow it to auto-launch.',
      settingsKey: 'oneplus',
      steps: [
        'Settings → Battery → Battery optimisation → "Did I Snore?".',
        'Choose "Don\'t optimise".',
        'Settings → Apps → "Did I Snore?" → Battery → enable "Allow '
            'background activity" and "Auto-launch".',
      ],
    ));
  }

  // Oppo / Realme (ColorOS / Realme UI) — same security-center activity.
  if (has('oppo') || has('realme')) {
    steps.add(const OemStep(
      title: 'Oppo / Realme — startup manager + don\'t optimise',
      body: 'ColorOS / Realme UI blocks auto-launch and optimises battery '
          'aggressively. Allow both here.',
      settingsKey: 'oppo',
      steps: [
        'Settings → Battery → Battery optimisation → "Did I Snore?" → '
            '"Don\'t optimise".',
        'Open the Startup Manager (Phone Manager → Privacy permissions → '
            'Startup manager) and allow "Did I Snore?".',
        'On the app\'s info page, enable "Allow background activity".',
      ],
    ));
  }

  // Vivo / iQOO (FuntouchOS / OriginOS).
  if (has('vivo') || has('iqoo')) {
    steps.add(const OemStep(
      title: 'Vivo — high background power + autostart',
      body: 'Funtouch / OriginOS restricts background power and auto-start '
          'separately. Allow both.',
      settingsKey: 'vivo',
      steps: [
        'Settings → Battery → High background power consumption → allow '
            '"Did I Snore?".',
        'Settings → Apps → Auto-start / Permission manager → enable '
            '"Did I Snore?".',
        'Lock the app in recent-apps so it survives a memory clean.',
      ],
    ));
  }

  // Huawei / Honor (EMUI / MagicOS).
  if (has('huawei') || has('honor')) {
    steps.add(const OemStep(
      title: 'Huawei — manage manually',
      body: 'EMUI\'s "App launch" must be set to manual, with all three '
          'sub-toggles on, or the recorder is killed.',
      settingsKey: 'huawei',
      steps: [
        'Settings → Battery → App launch → "Did I Snore?".',
        'Turn OFF "Manage automatically".',
        'Enable all three: "Auto-launch", "Secondary launch", "Run in '
            'background".',
      ],
    ));
  }

  return steps;
}

/// True if [manufacturer]/[brand] is one of the OEMs we have a vendor
/// step for — i.e. `oemStepsFor` returns more than just the universal
/// battery step. Lets the UI decide whether to render the "OEM-specific"
/// section header at all.
bool hasOemSpecificSteps(String manufacturer, {String brand = ''}) {
  return oemStepsFor(manufacturer, brand: brand).length > 1;
}
