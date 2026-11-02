import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../core/domain.dart';
import '../../core/l10n.dart';
import '../../data/models.dart';
import '../../state/app_state.dart';
import '../dose_page.dart';
import '../widgets/common.dart';

/// History as a table.
///
/// The phone list is one card per dose; on a window the same data is easier to
/// scan as rows under a day heading, with the actions appearing on the row the
/// pointer is over.
class DesktopHistoryPage extends StatefulWidget {
  const DesktopHistoryPage({super.key});

  @override
  State<DesktopHistoryPage> createState() => _DesktopHistoryPageState();
}

class _DesktopHistoryPageState extends State<DesktopHistoryPage> {
  Ester? _filter;

  static const _timeWidth = 96.0;
  static const _doseWidth = 120.0;
  static const _routeWidth = 160.0;
  static const _actionsWidth = 96.0;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    final all = state.doses.reversed.toList();
    final esters = <Ester>{for (final e in all) e.ester}.toList()
      ..sort((a, b) => a.label.compareTo(b.label));
    final events = all.where((e) => _filter == null || e.ester == _filter).toList();

    final groups = <int, List<DoseEvent>>{};
    for (final event in events) {
      groups.putIfAbsent(dayNumberFromHours(event.timeH), () => []).add(event);
    }
    final days = groups.keys.toList()..sort((a, b) => b.compareTo(a));

    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 28, 32, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l10n.t('history.title'),
                      style: text.headlineMedium?.copyWith(
                        letterSpacing: -0.6,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '${events.length} · ${days.length} ${l10n.t('common.days')}',
                      style: text.bodyMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              PopupMenuButton<Ester?>(
                initialValue: _filter,
                onSelected: (value) => setState(() => _filter = value),
                itemBuilder: (context) => [
                  PopupMenuItem<Ester?>(
                    value: null,
                    child: Text(l10n.t('history.allDrugs')),
                  ),
                  for (final ester in esters)
                    PopupMenuItem<Ester?>(
                      value: ester,
                      child: Text(esterLabel(ester, l10n.lang)),
                    ),
                ],
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.filter_list, size: 18),
                      const SizedBox(width: 8),
                      Text(
                        _filter == null
                            ? l10n.t('history.allDrugs')
                            : esterLabel(_filter!, l10n.lang),
                        style: text.labelLarge,
                      ),
                      const SizedBox(width: 4),
                      const Icon(Icons.arrow_drop_down, size: 20),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          _TableHeader(
            timeWidth: _timeWidth,
            doseWidth: _doseWidth,
            routeWidth: _routeWidth,
            actionsWidth: _actionsWidth,
          ),
          const SizedBox(height: 4),
          Expanded(
            child: events.isEmpty
                ? Center(
                    child: EmptyState(
                      icon: Icons.history,
                      title: l10n.t('history.empty'),
                      body: l10n.t('history.emptyBody'),
                    ),
                  )
                : Scrollbar(
                    child: ListView.builder(
                      padding: const EdgeInsets.only(bottom: 32),
                      itemCount: days.length,
                      itemBuilder: (context, index) {
                        final day = days[index];
                        final rows = groups[day]!
                          ..sort((a, b) => b.timeH.compareTo(a.timeH));
                        return _DayGroup(
                          day: day,
                          events: rows,
                          timeWidth: _timeWidth,
                          doseWidth: _doseWidth,
                          routeWidth: _routeWidth,
                          actionsWidth: _actionsWidth,
                          onEdit: (event) => _edit(context, event),
                          onDelete: (event) => _delete(context, state, event),
                        );
                      },
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Future<void> _edit(BuildContext context, DoseEvent event) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => DosePage(existing: event),
        fullscreenDialog: true,
      ),
    );
  }

  Future<void> _delete(
    BuildContext context,
    AppState state,
    DoseEvent event,
  ) async {
    final l10n = context.l10n;
    final ok = await ConfirmDialog.show(
      context,
      title: l10n.t('dose.deleteConfirm'),
      confirmLabel: l10n.t('common.delete'),
      destructive: true,
    );
    if (!ok) return;
    await state.deleteDose(event.id);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(l10n.t('dose.deleted'))),
    );
  }
}

class _TableHeader extends StatelessWidget {
  const _TableHeader({
    required this.timeWidth,
    required this.doseWidth,
    required this.routeWidth,
    required this.actionsWidth,
  });

  final double timeWidth;
  final double doseWidth;
  final double routeWidth;
  final double actionsWidth;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final text = Theme.of(context).textTheme.copyWith(
      labelMedium: Theme.of(context).textTheme.labelMedium?.copyWith(
        color: Theme.of(context).colorScheme.onSurfaceVariant,
        fontWeight: FontWeight.w600,
      ),
    );
    final style = text.labelMedium;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: Theme.of(context).colorScheme.outlineVariant,
          ),
        ),
      ),
      child: Row(
        children: [
          SizedBox(width: timeWidth, child: Text(l10n.t('desktop.colTime'), style: style)),
          Expanded(child: Text(l10n.t('dose.drug'), style: style)),
          SizedBox(
            width: doseWidth,
            child: Text(
              l10n.t('desktop.colDose'),
              textAlign: TextAlign.right,
              style: style,
            ),
          ),
          SizedBox(width: 16),
          SizedBox(
            width: routeWidth,
            child: Text(l10n.t('desktop.colRoute'), style: style),
          ),
          SizedBox(
            width: actionsWidth,
            child: Text(
              l10n.t('desktop.colActions'),
              textAlign: TextAlign.right,
              style: style,
            ),
          ),
        ],
      ),
    );
  }
}

class _DayGroup extends StatelessWidget {
  const _DayGroup({
    required this.day,
    required this.events,
    required this.timeWidth,
    required this.doseWidth,
    required this.routeWidth,
    required this.actionsWidth,
    required this.onEdit,
    required this.onDelete,
  });

  final int day;
  final List<DoseEvent> events;
  final double timeWidth;
  final double doseWidth;
  final double routeWidth;
  final double actionsWidth;
  final ValueChanged<DoseEvent> onEdit;
  final ValueChanged<DoseEvent> onDelete;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final date = dayFromNumber(day);
    final isToday = day == dayNumberFromHours(hoursFromDateTime(DateTime.now()));
    final label = isToday
        ? l10n.t('common.today')
        : DateFormat.MMMMEEEEd(
            Localizations.localeOf(context).toString(),
          ).format(date);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 20, 12, 8),
          child: Row(
            children: [
              Text(
                label,
                style: text.titleSmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
              const SizedBox(width: 12),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  '${events.length}',
                  style: text.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ),
        for (final event in events)
          _DoseRow(
            key: ValueKey(event.id),
            event: event,
            timeWidth: timeWidth,
            doseWidth: doseWidth,
            routeWidth: routeWidth,
            actionsWidth: actionsWidth,
            onEdit: () => onEdit(event),
            onDelete: () => onDelete(event),
          ),
      ],
    );
  }
}

class _DoseRow extends StatefulWidget {
  const _DoseRow({
    super.key,
    required this.event,
    required this.timeWidth,
    required this.doseWidth,
    required this.routeWidth,
    required this.actionsWidth,
    required this.onEdit,
    required this.onDelete,
  });

  final DoseEvent event;
  final double timeWidth;
  final double doseWidth;
  final double routeWidth;
  final double actionsWidth;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  State<_DoseRow> createState() => _DoseRowState();
}

class _DoseRowState extends State<_DoseRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final event = widget.event;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onEdit,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 100),
          margin: const EdgeInsets.symmetric(vertical: 1),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          decoration: BoxDecoration(
            color: _hovered
                ? scheme.surfaceContainerHigh
                : Colors.transparent,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              SizedBox(
                width: widget.timeWidth,
                child: Text(
                  DateFormat.Hm(
                    Localizations.localeOf(context).toString(),
                  ).format(event.time),
                  style: text.bodyMedium?.copyWith(
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
              Expanded(
                child: Row(
                  children: [
                    Icon(
                      _iconFor(event.route),
                      size: 18,
                      color: scheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 10),
                    Flexible(
                      child: Text(
                        describeDose(
                          context,
                          event,
                          hideSite: false,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.bodyLarge,
                      ),
                    ),
                  ],
                ),
              ),
              SizedBox(
                width: widget.doseWidth,
                child: Text(
                  '${formatDose(event.doseMG)} mg',
                  textAlign: TextAlign.right,
                  style: text.bodyLarge?.copyWith(
                    fontWeight: FontWeight.w600,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
              const SizedBox(width: 16),
              SizedBox(
                width: widget.routeWidth,
                child: Text(
                  routeLabel(context, event.route),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: text.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
              SizedBox(
                width: widget.actionsWidth,
                child: AnimatedOpacity(
                  duration: const Duration(milliseconds: 100),
                  opacity: _hovered ? 1 : 0,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      IconButton(
                        onPressed: widget.onEdit,
                        icon: const Icon(Icons.edit_outlined, size: 18),
                        tooltip: l10n.t('common.edit'),
                        visualDensity: VisualDensity.compact,
                      ),
                      IconButton(
                        onPressed: widget.onDelete,
                        icon: const Icon(Icons.delete_outline, size: 18),
                        tooltip: l10n.t('common.delete'),
                        visualDensity: VisualDensity.compact,
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static IconData _iconFor(DoseRoute route) => switch (route) {
    DoseRoute.injection => Icons.vaccines_outlined,
    DoseRoute.gel => Icons.water_drop_outlined,
    DoseRoute.patchApply => Icons.sticky_note_2_outlined,
    DoseRoute.sublingual => Icons.medication_liquid_outlined,
    DoseRoute.oral => Icons.medication_outlined,
    DoseRoute.patchRemove => Icons.remove_circle_outline,
  };
}
