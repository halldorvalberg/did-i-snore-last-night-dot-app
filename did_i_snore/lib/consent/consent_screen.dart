/// Pre-permission consent flow.
///
/// 5-step PageView walking the user through what's recorded, where it goes,
/// what isn't collected, what the OS recording indicators look like, and a
/// final "Continue" that triggers the OS microphone permission prompt.
///
/// English-only for v1 — strings are intentionally hardcoded. i18n is v2.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import 'consent_state.dart';

class ConsentScreen extends ConsumerStatefulWidget {
  const ConsentScreen({super.key});

  @override
  ConsumerState<ConsentScreen> createState() => _ConsentScreenState();
}

class _ConsentScreenState extends ConsumerState<ConsentScreen> {
  final _pageController = PageController();
  int _page = 0;
  bool _requesting = false;

  static const int _totalPages = 5;

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _next() {
    if (_page < _totalPages - 1) {
      _pageController.nextPage(
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    }
  }

  void _back() {
    if (_page > 0) {
      _pageController.previousPage(
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    }
  }

  Future<void> _requestMicAndContinue() async {
    if (_requesting) return;
    setState(() => _requesting = true);
    final status = await Permission.microphone.request();
    if (!mounted) return;
    setState(() => _requesting = false);

    if (status.isGranted) {
      await ref.read(consentStateProvider.notifier).setGiven();
      // The consent provider flip causes `App` to swap to HomeScreen.
    } else {
      // Push the explainer; user can retry or cancel out of the consent flow.
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => const _MicDeniedScreen(),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            _ProgressBar(current: _page, total: _totalPages),
            Expanded(
              child: PageView(
                controller: _pageController,
                onPageChanged: (i) => setState(() => _page = i),
                children: const [
                  _ConsentPage(
                    title: 'What this app records',
                    body:
                        'Did I Snore listens for sounds while you sleep, with '
                        'your phone resting on the bedside table.\n\n'
                        'It only saves the noisy moments — snores, coughs, '
                        'talking, the dog barking. Long stretches of silence '
                        'are thrown away.',
                  ),
                  _ConsentPage(
                    title: 'Where the data goes',
                    body:
                        'Recordings stay on this device. Always.\n\n'
                        'No account. No sign-in. No cloud sync. No backup '
                        'service. The audio never leaves your phone — there '
                        'is no server for it to leave to.',
                  ),
                  _ConsentPage(
                    title: "What's not collected",
                    body: 'No analytics.\n'
                        'No crash reporters.\n'
                        'No advertising IDs.\n'
                        'No third-party SDKs that phone home.\n\n'
                        'The app does not connect to the network. At all.',
                  ),
                  _ConsentPage(
                    title: "What you'll see while it's recording",
                    body: 'On iOS, an orange dot in the status bar.\n'
                        'On Android, a persistent notification.\n\n'
                        'Both are unavoidable mic indicators built into the '
                        'operating system. They are there by design — so you '
                        'always know when an app is listening.',
                  ),
                  _ConsentPage(
                    title: 'Ready to grant microphone access',
                    body:
                        'Next, your phone will ask whether to allow Did I '
                        'Snore to use the microphone. That dialog comes from '
                        'the operating system, not from us.\n\n'
                        'Tap Continue to bring it up. If you say no, the app '
                        "won't be able to do anything — but no audio will be "
                        'captured either.',
                  ),
                ],
              ),
            ),
            _NavBar(
              page: _page,
              total: _totalPages,
              requesting: _requesting,
              onBack: _back,
              onNext: _next,
              onContinue: _requestMicAndContinue,
            ),
          ],
        ),
      ),
    );
  }
}

class _ProgressBar extends StatelessWidget {
  const _ProgressBar({required this.current, required this.total});

  final int current;
  final int total;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 8),
      child: Row(
        children: List.generate(total, (i) {
          final active = i <= current;
          return Expanded(
            child: Container(
              height: 4,
              margin: EdgeInsets.only(right: i == total - 1 ? 0 : 6),
              decoration: BoxDecoration(
                color: active
                    ? scheme.primary
                    : scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          );
        }),
      ),
    );
  }
}

class _ConsentPage extends StatelessWidget {
  const _ConsentPage({required this.title, required this.body});

  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 24),
          Text(
            body,
            style: theme.textTheme.bodyLarge?.copyWith(height: 1.5),
          ),
        ],
      ),
    );
  }
}

class _NavBar extends StatelessWidget {
  const _NavBar({
    required this.page,
    required this.total,
    required this.requesting,
    required this.onBack,
    required this.onNext,
    required this.onContinue,
  });

  final int page;
  final int total;
  final bool requesting;
  final VoidCallback onBack;
  final VoidCallback onNext;
  final VoidCallback onContinue;

  @override
  Widget build(BuildContext context) {
    final isLast = page == total - 1;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
      child: Row(
        children: [
          if (page > 0)
            OutlinedButton(
              onPressed: requesting ? null : onBack,
              child: const Text('Back'),
            )
          else
            const SizedBox.shrink(),
          const Spacer(),
          if (isLast)
            FilledButton(
              onPressed: requesting ? null : onContinue,
              child: requesting
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Continue'),
            )
          else
            FilledButton(
              onPressed: onNext,
              child: const Text('Next'),
            ),
        ],
      ),
    );
  }
}

/// Shown when the OS-level mic permission dialog returns denied.
///
/// Offers a "Try again" that re-requests the permission, and a "Cancel" that
/// pops back to the consent flow without persisting consent. The user can
/// re-launch the app to retry from the start. Once the OS marks the
/// permission as permanently denied, `request()` is a no-op — at that point
/// the only path is the system Settings app, but for a cold first run that's
/// rarely the situation.
class _MicDeniedScreen extends ConsumerStatefulWidget {
  const _MicDeniedScreen();

  @override
  ConsumerState<_MicDeniedScreen> createState() => _MicDeniedScreenState();
}

class _MicDeniedScreenState extends ConsumerState<_MicDeniedScreen> {
  bool _requesting = false;

  Future<void> _retry() async {
    if (_requesting) return;
    setState(() => _requesting = true);
    final status = await Permission.microphone.request();
    if (!mounted) return;
    setState(() => _requesting = false);

    if (status.isGranted) {
      await ref.read(consentStateProvider.notifier).setGiven();
      if (!mounted) return;
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 8),
              Text(
                "We can't continue without the microphone",
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 24),
              Text(
                'Did I Snore exists to record sounds. Without microphone '
                "access, there's nothing it can do.\n\n"
                'If you change your mind, you can grant access in your '
                "phone's Settings under Did I Snore -> Permissions, or tap "
                'Try again below to re-open the OS prompt.',
                style: theme.textTheme.bodyLarge?.copyWith(height: 1.5),
              ),
              const Spacer(),
              Row(
                children: [
                  OutlinedButton(
                    onPressed: _requesting
                        ? null
                        : () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                  const Spacer(),
                  FilledButton(
                    onPressed: _requesting ? null : _retry,
                    child: _requesting
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('Try again'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
