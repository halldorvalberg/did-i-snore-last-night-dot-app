/// Consent state for did-i-snore-last-night.app.
///
/// Tracks whether the user has completed the in-app consent flow that
/// precedes the OS-level microphone permission prompt. Persisted to
/// SharedPreferences under a versioned key so a future copy/policy change
/// can re-prompt without ambiguity.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Tri-state consent.
///
/// `unknown` is the loading state while we read from prefs — distinguishing
/// it from `notGiven` lets the router show a spinner instead of flashing the
/// consent screen for one frame on cold boot.
enum ConsentState { unknown, notGiven, given }

/// Versioned key. Bump suffix when the consent copy or policy changes
/// substantively enough that we need users to re-confirm.
const String consentPrefsKey = 'consent_given_v1';

class ConsentController extends StateNotifier<ConsentState> {
  ConsentController() : super(ConsentState.unknown) {
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final given = prefs.getBool(consentPrefsKey) ?? false;
    state = given ? ConsentState.given : ConsentState.notGiven;
  }

  /// Persist consent and flip state to `given`.
  ///
  /// Called from the consent screen only after the OS microphone permission
  /// has actually been granted — we don't record consent based purely on the
  /// user clicking "Continue", because they may still deny at the OS dialog.
  Future<void> setGiven() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(consentPrefsKey, true);
    state = ConsentState.given;
  }

  /// Debug-only: clear the consent pref and return to `notGiven`. Wired up
  /// from a debug button on the Home screen so we can re-test the flow
  /// without a fresh install.
  Future<void> reset() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(consentPrefsKey);
    state = ConsentState.notGiven;
  }
}

final consentStateProvider =
    StateNotifierProvider<ConsentController, ConsentState>(
  (ref) => ConsentController(),
);
