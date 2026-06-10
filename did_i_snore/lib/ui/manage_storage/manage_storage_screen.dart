/// Manage Storage screen — Phase 9.
///
/// Spec: `docs/IMPLEMENTATION.md` §9 lines 929–938. Quota refuses to
/// touch starred events, so a user who has accumulated dozens of
/// starred snores from a noisy week can fill the disk with content
/// the janitor will not auto-prune. This screen is the recovery path:
///
/// 1. **Header card** — total used + free chip + the
///    `RetentionCfg.minFreeDiskMb` threshold the recorder gate will
///    trip on.
/// 2. **Per-night breakdown** — one card per night sorted newest
///    first; each card has "Delete all unstarred from this night."
/// 3. **Star-management list** — every starred event with a per-event
///    unstar toggle. The escape hatch when the over-starred backlog
///    is the actual problem.
///
/// **Quota-failed banner.** Above the header card, when
/// `quotaResultProvider.canRecord` is false, render a red banner with
/// the block reason and a "Free space now" button that scrolls to the
/// per-night list. Mirrors the inline banner the home screen shows
/// above the record button — both renderings read the same provider.
///
/// **Soft-delete only.** Every "delete" path on this screen calls
/// `EventRepo.softDelete`; the janitor's hard-delete pass eventually
/// reclaims disk. Undo via the SnackBar reverses the soft-delete in
/// the same atomic way the timeline / player do.
///
/// **No `dart:io` calls in build paths.** File-size lookups happen in
/// `manageStorageStateProvider` (the FutureProvider's body); the
/// screen reads pre-aggregated `int` totals.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../config/constants.dart';
import '../../data/db.dart' show Event;
import '../../janitor/quota.dart' show QuotaResult;
import '../providers.dart';
import '../timeline/display_label.dart';
import 'night_summary.dart';

class ManageStorageScreen extends ConsumerStatefulWidget {
  const ManageStorageScreen({super.key});

  @override
  ConsumerState<ManageStorageScreen> createState() =>
      _ManageStorageScreenState();
}

class _ManageStorageScreenState extends ConsumerState<ManageStorageScreen> {
  /// Drives "Free space now" from the quota banner. Anchors the
  /// per-night breakdown in the scroll view; tapping the banner CTA
  /// scrolls the breakdown into view. Created in `initState` so the
  /// `Scrollable.ensureVisible` call has a frame-stable target.
  final GlobalKey _breakdownAnchorKey = GlobalKey();
  final ScrollController _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _scrollToBreakdown() async {
    final ctx = _breakdownAnchorKey.currentContext;
    if (ctx == null) return;
    await Scrollable.ensureVisible(
      ctx,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
      alignment: 0,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // `quotaResultProvider` is async (it runs `df` + a possible
    // synchronous prune). While loading we render the rest of the
    // screen optimistically — there's no point blocking the snapshot
    // on the quota gate; the banner just blinks in once quota
    // resolves.
    final quotaAsync = ref.watch(quotaResultProvider);
    final snapshotAsync = ref.watch(manageStorageStateProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Manage storage'),
      ),
      body: SafeArea(
        child: snapshotAsync.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                'Could not load storage information: $e',
                style: theme.textTheme.bodyMedium,
                textAlign: TextAlign.center,
              ),
            ),
          ),
          data: (snapshot) => _ManageStorageBody(
            snapshot: snapshot,
            quota: quotaAsync.valueOrNull,
            scrollController: _scrollController,
            breakdownAnchorKey: _breakdownAnchorKey,
            onFreeSpaceNow: _scrollToBreakdown,
          ),
        ),
      ),
    );
  }
}

class _ManageStorageBody extends ConsumerWidget {
  const _ManageStorageBody({
    required this.snapshot,
    required this.quota,
    required this.scrollController,
    required this.breakdownAnchorKey,
    required this.onFreeSpaceNow,
  });

  final ManageStorageSnapshot snapshot;

  /// Null while the quota provider is still resolving; the banner
  /// stays hidden in that case (we don't render "recording disabled"
  /// optimistically). Once resolved, `quota.canRecord` flips it on.
  final QuotaResult? quota;
  final ScrollController scrollController;
  final GlobalKey breakdownAnchorKey;
  final Future<void> Function() onFreeSpaceNow;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final showBanner = quota != null && !quota!.canRecord;
    return ListView(
      controller: scrollController,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      children: [
        if (showBanner)
          _QuotaBanner(
            reason: quota!.blockReason,
            onFreeSpaceNow: onFreeSpaceNow,
          ),
        const SizedBox(height: 12),
        _StorageHeader(
          totalUsedBytes: snapshot.totalUsedBytes,
          freeBytes: snapshot.freeBytes,
        ),
        const SizedBox(height: 24),
        // Section anchor: the quota banner's "Free space now" CTA
        // ensures THIS widget is visible. We keep it as a zero-height
        // placeholder above the per-night list so the heading also
        // ends up on screen, not just the first card.
        SizedBox(key: breakdownAnchorKey, height: 0),
        _SectionHeading(text: 'Recordings by night'),
        const SizedBox(height: 8),
        if (snapshot.nights.isEmpty)
          _EmptyHint(text: 'No recorded events yet.')
        else
          for (final night in snapshot.nights)
            _NightCard(
              summary: night,
              onDeleteUnstarred: () => _deleteUnstarred(context, ref, night),
            ),
        const SizedBox(height: 24),
        _SectionHeading(text: 'Starred events'),
        const SizedBox(height: 8),
        if (snapshot.starredEvents.isEmpty)
          _EmptyHint(
            text: 'No starred events. Quota is free to prune unstarred '
                'recordings as needed.',
          )
        else
          for (final ev in snapshot.starredEvents)
            _StarredEventTile(
              event: ev,
              onUnstar: () => _unstar(context, ref, ev),
            ),
      ],
    );
  }

  // ---- mutations -------------------------------------------------------

  Future<void> _deleteUnstarred(
    BuildContext context,
    WidgetRef ref,
    NightSummary night,
  ) async {
    if (night.unstarredCount == 0) return;
    final dateText = DateFormat.yMMMd().format(night.night);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete unstarred events?'),
        content: Text(
          'Soft-delete ${night.unstarredCount} unstarred event'
          '${night.unstarredCount == 1 ? '' : 's'} from $dateText. '
          'Starred events stay. You can undo for a few seconds after.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (!context.mounted) return;

    final repo = ref.read(eventRepoProvider);
    // Filter starred OUT — explicit guard backing the spec's hard
    // promise. The bulk action MUST never touch a starred row, even
    // if some upstream caller composes a list that mixes them in.
    final targets =
        night.events.where((e) => !e.starred).map((e) => e.id).toList();
    for (final id in targets) {
      await repo.softDelete(id);
    }
    ref.invalidate(manageStorageStateProvider);
    ref.invalidate(quotaResultProvider);
    if (!context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          'Deleted ${targets.length} event${targets.length == 1 ? '' : 's'}.',
        ),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () async {
            for (final id in targets) {
              await repo.undelete(id);
            }
            ref.invalidate(manageStorageStateProvider);
          },
        ),
      ),
    );
  }

  Future<void> _unstar(
    BuildContext context,
    WidgetRef ref,
    Event ev,
  ) async {
    final repo = ref.read(eventRepoProvider);
    await repo.setStarred(ev.id, false);
    ref.invalidate(manageStorageStateProvider);
  }
}

/// Sticky top banner. Renders only when `quotaResultProvider.canRecord`
/// is false — the recorder service refused `start()` because free disk
/// is below `RetentionCfg.minFreeDiskMb` *and* the auto-prune pass had
/// no unstarred events left to soft-delete. Provides the user a direct
/// path to the per-night "delete unstarred" action.
class _QuotaBanner extends StatelessWidget {
  const _QuotaBanner({
    required this.reason,
    required this.onFreeSpaceNow,
  });

  final String? reason;
  final Future<void> Function() onFreeSpaceNow;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.errorContainer,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.error_outline, color: scheme.onErrorContainer),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Recording disabled',
                    style: Theme.of(context)
                        .textTheme
                        .titleMedium
                        ?.copyWith(color: scheme.onErrorContainer),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    reason ??
                        'Low storage. Free space below to resume '
                            'recording.',
                    style: Theme.of(context)
                        .textTheme
                        .bodyMedium
                        ?.copyWith(color: scheme.onErrorContainer),
                  ),
                  const SizedBox(height: 8),
                  FilledButton.tonal(
                    onPressed: () => onFreeSpaceNow(),
                    child: const Text('Free space now'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Total + free chip. The chip is green when `freeBytes >
/// manageStorageFreeBytesThreshold`, red at-or-below — the same gate
/// the recorder controller uses, so what the user sees here matches
/// what the recorder will refuse on.
class _StorageHeader extends StatelessWidget {
  const _StorageHeader({
    required this.totalUsedBytes,
    required this.freeBytes,
  });

  final int totalUsedBytes;
  final int freeBytes;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final threshold = manageStorageFreeBytesThreshold;
    final ok = freeBytes > threshold;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Used by recordings',
              style: theme.textTheme.labelLarge?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              _formatBytes(totalUsedBytes),
              style: theme.textTheme.headlineSmall,
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Chip(
                  label: Text(
                    'Free: ${_formatBytes(freeBytes)}',
                  ),
                  backgroundColor: ok
                      ? scheme.secondaryContainer
                      : scheme.errorContainer,
                  labelStyle: TextStyle(
                    color: ok
                        ? scheme.onSecondaryContainer
                        : scheme.onErrorContainer,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Threshold: ${RetentionCfg.minFreeDiskMb} MB',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                    textAlign: TextAlign.right,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionHeading extends StatelessWidget {
  const _SectionHeading({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(
      text,
      style: theme.textTheme.titleMedium?.copyWith(
        fontWeight: FontWeight.w700,
      ),
    );
  }
}

class _EmptyHint extends StatelessWidget {
  const _EmptyHint({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
      child: Text(
        text,
        style: theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

class _NightCard extends StatelessWidget {
  const _NightCard({
    required this.summary,
    required this.onDeleteUnstarred,
  });

  final NightSummary summary;
  final VoidCallback onDeleteUnstarred;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    // Locale-aware: spec line 908. `intl`'s default formatters render
    // sensibly on non-English device locales; English is the v1
    // copy locale, but the date itself respects the OS setting.
    final dateText = DateFormat.yMMMd().format(summary.night);
    return Card(
      clipBehavior: Clip.antiAlias,
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              dateText,
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            Text(
              '${summary.events.length} event'
              '${summary.events.length == 1 ? '' : 's'} · '
              '${_formatBytes(summary.totalBytes)} · '
              '${summary.starredCount} starred / '
              '${summary.unstarredCount} unstarred',
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed:
                    summary.unstarredCount == 0 ? null : onDeleteUnstarred,
                icon: const Icon(Icons.delete_sweep_outlined),
                label: Text(
                  summary.unstarredCount == 0
                      ? 'No unstarred to delete'
                      : 'Delete all unstarred',
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StarredEventTile extends StatelessWidget {
  const _StarredEventTile({
    required this.event,
    required this.onUnstar,
  });

  final Event event;
  final VoidCallback onUnstar;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final start = DateTime.fromMillisecondsSinceEpoch(event.startedAt);
    final timeText = DateFormat.Hm().format(start);
    final dateText = DateFormat.yMMMd().format(start);
    final label = displayLabel(event);
    final durationText = _formatDuration(event.durationMs);

    return Card(
      clipBehavior: Clip.antiAlias,
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: ListTile(
        leading: Icon(Icons.star, color: scheme.primary),
        title: Text(label, overflow: TextOverflow.ellipsis),
        subtitle: Text(
          '$dateText · $timeText · $durationText',
          style: theme.textTheme.bodySmall?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
        trailing: TextButton(
          onPressed: onUnstar,
          child: const Text('Unstar'),
        ),
      ),
    );
  }
}

/// Bytes → human-readable string. Single source so the header chip and
/// the per-night card render the same rounding for the same input.
/// Uses 1024-step (binary) prefixes since file sizes are what we're
/// reporting; switch to 1000-step if a future spec mandates SI.
String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  const kb = 1024;
  const mb = 1024 * 1024;
  const gb = 1024 * 1024 * 1024;
  if (bytes < mb) return '${(bytes / kb).toStringAsFixed(1)} KB';
  if (bytes < gb) return '${(bytes / mb).toStringAsFixed(1)} MB';
  return '${(bytes / gb).toStringAsFixed(2)} GB';
}

/// Duration ms → "1.2 s" / "12 s" / "1m 30s". Mirrors the timeline
/// `EventTile._formatDuration`; pulled out here so the screen does
/// not have to import the timeline tile.
String _formatDuration(int ms) {
  if (ms < 1000) return '$ms ms';
  final seconds = ms / 1000.0;
  if (seconds < 10) return '${seconds.toStringAsFixed(1)} s';
  if (seconds < 60) return '${seconds.toStringAsFixed(0)} s';
  final minutes = seconds ~/ 60;
  final remSeconds = (seconds % 60).round();
  return '${minutes}m ${remSeconds}s';
}
