/// Per-night timeline. Spec: `docs/IMPLEMENTATION.md` §8 line 888.
///
/// Reads `eventsForNightProvider(night)` and `gapsForNightProvider(night)`
/// (Phase 8 + Phase 10 wire-ups respectively); groups events by hour
/// with sticky hour headers, and interleaves `GapTile`s between
/// adjacent events whose timestamps straddle a gap.
///
/// **Constructor argument, not `ModalRoute.of`.** Type-safe, less
/// boilerplate, and the `onGenerateRoute` registration in `app.dart`
/// already does the unwrap. Callers pass `DateTime` (the night
/// midnight-floor produced by `nightOf`).
///
/// **Long-press → bottom sheet.** Star/Unstar and Delete are shortcut
/// actions; full editing lives in the player. Soft-delete is via the
/// repo's `softDelete` and surfaces an undo SnackBar (5-second auto
/// dismiss; the repo `undelete` reverses it).
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../data/db.dart' show Event, RecordingGap;
import '../../app.dart';
import '../providers.dart';
import 'event_tile.dart';
import 'gap_tile.dart';

class TimelineScreen extends ConsumerWidget {
  const TimelineScreen({super.key, required this.night});

  /// Local-day midnight-floor of the night to display. Produced by
  /// `nightOf(Event)` or `nightOfMs(int)`; never an arbitrary
  /// `DateTime`.
  final DateTime night;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final eventsAsync = ref.watch(eventsForNightProvider(night));
    final gapsAsync = ref.watch(gapsForNightProvider(night));
    final docsAsync = ref.watch(docsDirProvider);

    final dateText = DateFormat.MMMd().format(night);

    return Scaffold(
      appBar: AppBar(
        title: Text("Night of $dateText"),
      ),
      body: SafeArea(
        child: docsAsync.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(
            child: Text(
              'Could not resolve storage: $e',
              style: theme.textTheme.bodyMedium,
            ),
          ),
          data: (docsDir) => eventsAsync.when(
            loading: () =>
                const Center(child: CircularProgressIndicator()),
            error: (e, _) => Center(
              child: Text(
                'Failed to load events: $e',
                style: theme.textTheme.bodyMedium,
              ),
            ),
            data: (events) {
              if (events.isEmpty) {
                return _EmptyState(date: dateText);
              }
              final gaps = gapsAsync.valueOrNull ?? const <RecordingGap>[];
              return _TimelineList(
                events: events,
                gaps: gaps,
                docsDir: docsDir,
              );
            },
          ),
        ),
      ),
    );
  }
}

class _TimelineList extends ConsumerWidget {
  const _TimelineList({
    required this.events,
    required this.gaps,
    required this.docsDir,
  });

  final List<Event> events;
  final List<RecordingGap> gaps;
  final Directory docsDir;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Build a flat list of tiles: hour headers, event tiles, and gap
    // tiles interleaved between consecutive events whose timestamps
    // bracket a gap. Phase 8 ships with `gaps` empty (Phase 10
    // populates the table); the interleave logic exists so Phase 10 is
    // a single-provider change instead of a screen rewrite.
    final entries = <_Row>[];
    int? lastHour;
    for (var i = 0; i < events.length; i++) {
      final ev = events[i];
      final dt = DateTime.fromMillisecondsSinceEpoch(ev.startedAt);
      if (lastHour == null || dt.hour != lastHour) {
        lastHour = dt.hour;
        entries.add(_Row.header(_hourLabel(dt.hour)));
      }
      entries.add(_Row.event(ev));

      // Insert gaps that fall between this event's end and the next
      // event's start.
      final next = i + 1 < events.length ? events[i + 1] : null;
      if (next != null) {
        final between = gaps.where(
          (g) =>
              g.startedAt >= ev.endedAt &&
              g.endedAt <= next.startedAt,
        );
        for (final g in between) {
          entries.add(_Row.gap(g));
        }
      }
    }

    return ListView.builder(
      itemCount: entries.length,
      itemBuilder: (ctx, i) {
        final row = entries[i];
        switch (row.kind) {
          case _RowKind.header:
            return _HourHeader(text: row.headerText!);
          case _RowKind.event:
            final ev = row.event!;
            return EventTile(
              event: ev,
              docsDir: docsDir,
              onTap: () => Navigator.of(ctx).pushNamed(
                playerRoute,
                arguments: ev,
              ),
              onStarToggle: () async {
                final repo = ref.read(eventRepoProvider);
                await repo.setStarred(ev.id, !ev.starred);
              },
              onDelete: () => _confirmDelete(ctx, ref, ev),
            );
          case _RowKind.gap:
            return GapTile(gap: row.gap!);
        }
      },
    );
  }

  Future<void> _confirmDelete(
    BuildContext context,
    WidgetRef ref,
    Event ev,
  ) async {
    final repo = ref.read(eventRepoProvider);
    await repo.softDelete(ev.id);
    if (!context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: const Text('Event deleted'),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () async {
            await repo.undelete(ev.id);
          },
        ),
      ),
    );
  }

  static String _hourLabel(int hour) =>
      '${hour.toString().padLeft(2, '0')}:00';
}

class _HourHeader extends StatelessWidget {
  const _HourHeader({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      color: scheme.surface,
      child: Text(
        text,
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: scheme.onSurfaceVariant,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.5,
            ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.date});
  final String date;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.nights_stay_outlined,
            size: 48,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(height: 12),
          Text(
            'No events for $date',
            style: theme.textTheme.titleMedium,
          ),
          const SizedBox(height: 4),
          Text(
            'Either it was a quiet night, or recording wasn\'t running.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

/// Lightweight tagged union for the flattened list. Avoids stuffing
/// three sibling types into a `dynamic` and pattern-matching at render
/// time.
enum _RowKind { header, event, gap }

class _Row {
  final _RowKind kind;
  final String? headerText;
  final Event? event;
  final RecordingGap? gap;

  const _Row._(this.kind, {this.headerText, this.event, this.gap});

  factory _Row.header(String text) =>
      _Row._(_RowKind.header, headerText: text);
  factory _Row.event(Event e) => _Row._(_RowKind.event, event: e);
  factory _Row.gap(RecordingGap g) => _Row._(_RowKind.gap, gap: g);
}
