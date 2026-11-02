import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../core/domain.dart';
import '../core/l10n.dart';
import '../data/models.dart';
import '../state/app_state.dart';
import 'dose_page.dart';
import 'widgets/common.dart';
import 'widgets/level_chart.dart';

class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key});

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  Ester? _filter;
  bool _showHeatmap = false;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;

    final events =
        state.doses.where((e) => _filter == null || e.ester == _filter).toList()
          ..sort((a, b) => b.timeH.compareTo(a.timeH));

    final groups = <int, List<DoseEvent>>{};
    for (final e in events) {
      groups.putIfAbsent(dayNumberFromHours(e.timeH), () => []).add(e);
    }

    final counts = <int, int>{};
    for (final e in state.doses) {
      final day = dayNumberFromHours(e.timeH);
      counts[day] = (counts[day] ?? 0) + 1;
    }

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          SliverAppBar.large(
            title: Text(l10n.t('history.title')),
            actions: [
              PopupMenuButton<Ester?>(
                icon: const Icon(Icons.filter_list),
                tooltip: l10n.t('history.filter'),
                onSelected: (v) => setState(() => _filter = v),
                itemBuilder: (context) => [
                  PopupMenuItem(
                    value: null,
                    child: Text(l10n.t('history.allDrugs')),
                  ),
                  for (final ester in Ester.values)
                    if (state.doses.any((e) => e.ester == ester))
                      PopupMenuItem(
                        value: ester,
                        child: Text(esterLabel(ester, l10n.lang)),
                      ),
                ],
              ),
              IconButton(
                onPressed: () => setState(() => _showHeatmap = !_showHeatmap),
                icon: Icon(_showHeatmap ? Icons.grid_off : Icons.grid_on),
                tooltip: l10n.t('history.heatmap'),
              ),
            ],
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 96),
            sliver: SliverList(
              delegate: SliverChildListDelegate([
                if (_filter != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Row(
                      children: [
                        FilterChip(
                          label: Text(esterLabel(_filter!, l10n.lang)),
                          selected: true,
                          onSelected: (_) => setState(() => _filter = null),
                          onDeleted: () => setState(() => _filter = null),
                        ),
                      ],
                    ),
                  ),
                if (_showHeatmap)
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            l10n.t('history.heatmap'),
                            style: Theme.of(context).textTheme.titleSmall,
                          ),
                          const SizedBox(height: 12),
                          DoseHeatmap(counts: counts, weeks: 16),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              Text(
                                l10n.t('history.heatmapLess'),
                                style: Theme.of(context).textTheme.labelSmall,
                              ),
                              const SizedBox(width: 8),
                              for (final alpha in [0.0, 0.25, 0.45, 0.7, 1.0])
                                Container(
                                  width: 12,
                                  height: 12,
                                  margin: const EdgeInsets.only(right: 4),
                                  decoration: BoxDecoration(
                                    color: alpha == 0
                                        ? scheme.surfaceContainerHighest
                                        : scheme.primary.withValues(
                                            alpha: alpha,
                                          ),
                                    borderRadius: BorderRadius.circular(3),
                                  ),
                                ),
                              const SizedBox(width: 8),
                              Text(
                                l10n.t('history.heatmapMore'),
                                style: Theme.of(context).textTheme.labelSmall,
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                if (events.isEmpty)
                  Card(
                    child: EmptyState(
                      icon: Icons.history,
                      title: l10n.t('history.empty'),
                      body: l10n.t('history.emptyBody'),
                    ),
                  )
                else
                  for (final entry in groups.entries) ...[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(4, 20, 4, 8),
                      child: Text(
                        _dayLabel(context, entry.key),
                        style: Theme.of(context).textTheme.titleSmall
                            ?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ),
                    Card(
                      child: Column(
                        children: [
                          for (var i = 0; i < entry.value.length; i++) ...[
                            if (i > 0)
                              const Divider(
                                height: 1,
                                indent: 16,
                                endIndent: 16,
                              ),
                            _DoseRow(event: entry.value[i]),
                          ],
                        ],
                      ),
                    ),
                  ],
              ]),
            ),
          ),
        ],
      ),
    );
  }

  String _dayLabel(BuildContext context, int dayNumber) {
    final date = DateTime.fromMillisecondsSinceEpoch(dayNumber * 86400000);
    final today = localDay(DateTime.now());
    final l10n = context.l10n;
    if (dayNumber == today) return l10n.t('common.today');
    if (dayNumber == today - 1) return l10n.t('common.yesterday');
    return DateFormat.yMMMEd(Localizations.localeOf(context).toString())
        .format(date);
  }
}

class _DoseRow extends StatelessWidget {
  const _DoseRow({required this.event});
  final DoseEvent event;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final state = context.read<AppState>();
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      onTap: () async {
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => DosePage(existing: event),
            fullscreenDialog: true,
          ),
        );
      },
      leading: CircleAvatar(
        backgroundColor: scheme.surfaceContainerHighest,
        child: Icon(
          _icon(event.route),
          size: 20,
          color: scheme.onSurfaceVariant,
        ),
      ),
      title: Text(describeDose(context, event, hideSite: state.hideSiteLabel)),
      subtitle: Text(
        '${DateFormat.Hm(Localizations.localeOf(context).toString()).format(event.time)} · ${routeLabel(context, event.route)}',
        style: Theme.of(context).textTheme.bodySmall
            ?.copyWith(color: scheme.onSurfaceVariant),
      ),
      trailing: PopupMenuButton<String>(
        icon: const Icon(Icons.more_vert),
        onSelected: (value) async {
          if (value == 'edit') {
            await Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => DosePage(existing: event),
                fullscreenDialog: true,
              ),
            );
          } else if (value == 'duplicate') {
            final copy = event.copyWith(
              id: state.newId('dose'),
              timeH: hoursFromDateTime(DateTime.now()),
              updatedAt: DateTime.now().millisecondsSinceEpoch,
            );
            await state.addDose(copy);
          } else if (value == 'delete') {
            final ok = await ConfirmDialog.show(
              context,
              title: context.l10n.t('dose.deleteConfirm'),
              confirmLabel: context.l10n.t('common.delete'),
              destructive: true,
            );
            if (ok) await state.deleteDose(event.id);
          }
        },
        itemBuilder: (context) => [
          PopupMenuItem(value: 'edit', child: Text(l10n.t('common.edit'))),
          PopupMenuItem(
            value: 'duplicate',
            child: Text(l10n.lang.startsWith('zh') ? '复制到现在' : 'Duplicate now'),
          ),
          PopupMenuItem(
            value: 'delete',
            child: Text(
              l10n.t('common.delete'),
              style: TextStyle(color: scheme.error),
            ),
          ),
        ],
      ),
    );
  }

  static IconData _icon(DoseRoute route) => switch (route) {
    DoseRoute.injection => Icons.vaccines_outlined,
    DoseRoute.gel => Icons.water_drop_outlined,
    DoseRoute.patchApply => Icons.sticky_note_2_outlined,
    DoseRoute.sublingual => Icons.medication_liquid_outlined,
    DoseRoute.oral => Icons.medication_outlined,
    DoseRoute.patchRemove => Icons.remove_circle_outline,
  };
}
