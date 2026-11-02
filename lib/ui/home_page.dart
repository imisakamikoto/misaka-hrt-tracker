import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../core/domain.dart';
import '../core/l10n.dart';
import '../data/models.dart';
import '../state/app_state.dart';
import 'widgets/common.dart';
import 'widgets/level_chart.dart';
import 'widgets/pixel_cat.dart';

class HomePage extends StatefulWidget {
  const HomePage({
    super.key,
    required this.onOpenPlan,
    required this.onOpenSupplies,
    required this.onOpenLabs,
    required this.onLogDose,
    required this.onOpenForecast,
  });

  final VoidCallback onOpenPlan;
  final VoidCallback onOpenSupplies;
  final VoidCallback onOpenLabs;
  final VoidCallback onLogDose;
  final VoidCallback onOpenForecast;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _windowDays = 7;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final l10n = context.l10n;
    final now = DateTime.now();
    final hour = now.hour;
    final greeting = hour < 12
        ? l10n.t('home.morning')
        : hour < 18
        ? l10n.t('home.afternoon')
        : l10n.t('home.evening');

    final today = todayDoses(plan: state.plan, doses: state.doses, now: now);
    final advisory = doseAdvisory(state.doses, now);
    final supplies = state.supplyStatuses
        .where((s) => s.daysLeft != null && s.daysLeft! <= state.supplyLeadDays)
        .toList();

    return CustomScrollView(
      slivers: [
        SliverAppBar.large(
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(greeting, style: Theme.of(context).textTheme.titleMedium),
              Text(
                DateFormat.MMMMEEEEd(Localizations.localeOf(context).toString())
                    .format(now),
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          actions: [
            IconButton(
              onPressed: () async {
                await state.recompute();
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(context.l10n.t('common.done'))),
                  );
                }
              },
              icon: const Icon(Icons.refresh),
              tooltip: l10n.t('common.retry'),
            ),
            const SizedBox(width: 4),
          ],
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 96),
          sliver: SliverList(
            delegate: SliverChildListDelegate([
              if (state.coreError != null)
                _CoreErrorBanner(message: state.coreError!),
              _LevelCard(state: state),
              if (advisory != null) ...[
                const SizedBox(height: 12),
                _AdvisoryBanner(kind: advisory.kind),
              ],
              const SizedBox(height: 8),
              SectionHeader(
                title: l10n.t('home.today'),
                action: TextButton(
                  onPressed: widget.onOpenPlan,
                  child: Text(l10n.t('plan.title')),
                ),
              ),
              _TodayCard(
                items: today,
                onLog: (item) => _logPlanned(state, item),
                onOpenPlan: widget.onOpenPlan,
              ),
              if (today.isNotEmpty) _NextDoseRow(state: state),
              SectionHeader(
                title: l10n.t('home.curve'),
                action: TextButton(
                  onPressed: widget.onOpenForecast,
                  child: Text(l10n.t('nav.forecast')),
                ),
              ),
              _CurveCard(
                state: state,
                windowDays: _windowDays,
                onWindowChanged: (d) => setState(() => _windowDays = d),
              ),
              SectionHeader(
                title: l10n.t('labs.title'),
                action: TextButton(
                  onPressed: widget.onOpenLabs,
                  child: Text(l10n.t('home.viewAll')),
                ),
              ),
              _LatestLabCard(state: state, onOpen: widget.onOpenLabs),
              if (supplies.isNotEmpty) ...[
                SectionHeader(
                  title: l10n.t('supplies.title'),
                  action: TextButton(
                    onPressed: widget.onOpenSupplies,
                    child: Text(l10n.t('home.viewAll')),
                  ),
                ),
                for (final status in supplies)
                  _SupplyWarning(status: status, onTap: widget.onOpenSupplies),
              ],
              if (state.pixelCats) ...[
                const SizedBox(height: 16),
                Center(
                  child: PixelCat(
                    style: state.catStyle,
                    level: state.levelNow,
                    low: state.targetLow,
                  ),
                ),
              ],
              const SizedBox(height: 8),
              Center(
                child: Text(
                  l10n.t('disclaimer.short'),
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
            ]),
          ),
        ),
      ],
    );
  }

  Future<void> _logPlanned(AppState state, TodayDose dose) async {
    final now = DateTime.now();
    final event = DoseEvent(
      id: state.newId('dose'),
      route: dose.item.route,
      timeH: hoursFromDateTime(now),
      doseMG: dose.item.doseMG,
      ester: dose.item.ester,
      extras: Map.of(dose.item.extras),
    );
    await state.addDose(event);
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(context.l10n.t('dose.saved'))));
  }
}

class _CoreErrorBanner extends StatelessWidget {
  const _CoreErrorBanner({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.memory, color: scheme.onErrorContainer),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              message,
              style: TextStyle(color: scheme.onErrorContainer),
            ),
          ),
        ],
      ),
    );
  }
}

class _LevelCard extends StatelessWidget {
  const _LevelCard({required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final level = state.levelNow;
    final unit = state.isTransfem ? 'pg/mL' : 'ng/dL';
    final inRange =
        level != null && level >= state.targetLow && level <= state.targetHigh;

    return Card(
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              scheme.surfaceContainerLow,
              Color.alphaBlend(
                scheme.primary.withValues(alpha: 0.06),
                scheme.surfaceContainerLow,
              ),
            ],
          ),
        ),
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  state.isTransfem ? Icons.spa_outlined : Icons.bolt_outlined,
                  size: 20,
                  color: scheme.primary,
                ),
                const SizedBox(width: 8),
                Text(
                  state.isTransfem ? 'Estradiol' : 'Testosterone',
                  style: text.titleSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const Spacer(),
                if (state.computing)
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
              ],
            ),
            const SizedBox(height: 14),
            // The estimate itself is always shown. `showPrediction` only
            // decides whether the chart looks ahead of now, exactly as in the
            // original app — hiding the number made an import look empty.
            if (level == null)
              Text(
                '—',
                style: text.displaySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              )
            else
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text(
                    level.toStringAsFixed(level >= 100 ? 0 : 1),
                    style: text.displaySmall?.copyWith(
                      fontSize: 56,
                      fontWeight: FontWeight.w300,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    unit,
                    style: text.titleMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            const SizedBox(height: 4),
            Text(
              l10n.t('home.current'),
              style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                _Pill(
                  label:
                      '${state.targetLow.toStringAsFixed(0)}–${state.targetHigh.toStringAsFixed(0)} $unit',
                  background: scheme.surfaceContainerHighest,
                  foreground: scheme.onSurfaceVariant,
                  icon: Icons.straighten,
                ),
                const SizedBox(width: 8),
                if (level != null)
                  _Pill(
                    label: l10n.t(inRange ? 'home.inRange' : 'home.outOfRange'),
                    background: inRange
                        ? scheme.secondaryContainer
                        : scheme.errorContainer,
                    foreground: inRange
                        ? scheme.onSecondaryContainer
                        : scheme.onErrorContainer,
                    icon: inRange
                        ? Icons.check_circle_outline
                        : Icons.error_outline,
                  ),
              ],
            ),
            if (state.cpaNow != null) ...[
              const SizedBox(height: 12),
              Text(
                'Cyproterone ${state.cpaNow!.toStringAsFixed(2)} ng/mL',
                style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({
    required this.label,
    required this.background,
    required this.foreground,
    this.icon,
  });

  final String label;
  final Color background;
  final Color foreground;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 14, color: foreground),
            const SizedBox(width: 4),
          ],
          Text(
            label,
            style: Theme.of(context).textTheme.labelMedium
                ?.copyWith(color: foreground),
          ),
        ],
      ),
    );
  }
}

class _AdvisoryBanner extends StatelessWidget {
  const _AdvisoryBanner({required this.kind});
  final String kind;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final l10n = context.l10n;
    final key = switch (kind) {
      'e2_cpa' => 'home.advisory.e2cpa',
      'cpa' => 'home.advisory.cpa',
      't' => 'home.advisory.t',
      _ => 'home.advisory.e2',
    };
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.tertiaryContainer,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline, color: scheme.onTertiaryContainer),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              l10n.t(key),
              style: TextStyle(color: scheme.onTertiaryContainer),
            ),
          ),
        ],
      ),
    );
  }
}

class _TodayCard extends StatelessWidget {
  const _TodayCard({
    required this.items,
    required this.onLog,
    required this.onOpenPlan,
  });

  final List<TodayDose> items;
  final void Function(TodayDose) onLog;
  final VoidCallback onOpenPlan;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    if (items.isEmpty) {
      return Card(
        child: EmptyState(
          icon: Icons.event_available_outlined,
          title: l10n.t('home.noPlan'),
          body: l10n.t('home.noPlanBody'),
          action: FilledButton.tonal(
            onPressed: onOpenPlan,
            child: Text(l10n.t('plan.add')),
          ),
        ),
      );
    }
    return Card(
      child: Column(
        children: [
          for (var i = 0; i < items.length; i++) ...[
            if (i > 0) const Divider(height: 1, indent: 16, endIndent: 16),
            _DoseTile(item: items[i], onLog: () => onLog(items[i])),
          ],
        ],
      ),
    );
  }
}

class _DoseTile extends StatelessWidget {
  const _DoseTile({required this.item, required this.onLog});
  final TodayDose item;
  final VoidCallback onLog;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final done = item.isDone;
    final notDay = !item.isDoseDay;

    return ListTile(
      leading: CircleAvatar(
        backgroundColor: done
            ? scheme.secondaryContainer
            : notDay
            ? scheme.surfaceContainerHighest
            : scheme.primaryContainer,
        foregroundColor: done
            ? scheme.onSecondaryContainer
            : notDay
            ? scheme.onSurfaceVariant
            : scheme.onPrimaryContainer,
        child: Icon(done ? Icons.check : _routeIcon(item.item.route), size: 20),
      ),
      title: Text(
        '${esterLabel(item.item.ester, l10n.lang)} · ${formatDose(item.item.doseMG)} mg',
        style: Theme.of(context).textTheme.bodyLarge?.copyWith(
          fontWeight: FontWeight.w600,
          color: notDay ? scheme.onSurfaceVariant : null,
        ),
      ),
      subtitle: Text(
        notDay
            ? l10n.t('plan.notDoseDay')
            : '${l10n.t('home.taken')} ${item.taken}/${item.due} · ${routeLabel(context, item.item.route)}',
        style: Theme.of(context).textTheme.bodySmall
            ?.copyWith(color: scheme.onSurfaceVariant),
      ),
      trailing: done
          ? Icon(Icons.check_circle, color: scheme.primary)
          : notDay
          ? null
          : FilledButton.tonal(
              onPressed: onLog,
              child: Text(l10n.t('home.taken')),
            ),
      onTap: done ? null : onLog,
    );
  }

  static IconData _routeIcon(DoseRoute route) => switch (route) {
    DoseRoute.injection => Icons.vaccines_outlined,
    DoseRoute.gel => Icons.water_drop_outlined,
    DoseRoute.patchApply => Icons.sticky_note_2_outlined,
    DoseRoute.sublingual => Icons.medication_liquid_outlined,
    DoseRoute.oral => Icons.medication_outlined,
    DoseRoute.patchRemove => Icons.remove_circle_outline,
  };
}

class _NextDoseRow extends StatelessWidget {
  const _NextDoseRow({required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final next = nextDoseAt(state.plan, state.doses, DateTime.now());
    if (next == null) return const SizedBox.shrink();
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final overdue = next.isBefore(DateTime.now());
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        children: [
          Icon(Icons.schedule, size: 16, color: scheme.onSurfaceVariant),
          const SizedBox(width: 6),
          Text(
            '${l10n.t(overdue ? 'home.overdue' : 'home.next')} · ${formatDateTime(context, next)}',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: overdue ? scheme.error : scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _CurveCard extends StatelessWidget {
  const _CurveCard({
    required this.state,
    required this.windowDays,
    required this.onWindowChanged,
  });

  final AppState state;
  final int windowDays;
  final ValueChanged<int> onWindowChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final sim = state.sim;
    final nowH = state.nowH;
    final windowStart = nowH - windowDays * 24;
    // With predictions switched off the chart stops at the present, the way the
    // original chart did; the logged history up to now is always drawn.
    final windowEnd = state.showPrediction ? nowH + 24 : nowH;

    final points = <Offset>[];
    final labs = <LabPoint>[];
    if (sim != null) {
      for (var i = 0; i < sim.timeH.length; i++) {
        final t = sim.timeH[i];
        if (t < windowStart || t > windowEnd) continue;
        final raw = state.isTransfem ? sim.e2PgMl[i] : sim.tNgDl[i];
        points.add(Offset(t, raw * (state.calibration?.factorAt(t) ?? 1)));
      }
      if (points.length > 400) {
        final step = (points.length / 400).ceil();
        final reduced = <Offset>[];
        for (var i = 0; i < points.length; i += step) {
          reduced.add(points[i]);
        }
        points
          ..clear()
          ..addAll(reduced);
      }
    }
    for (final lab in state.labs) {
      final h = lab.timeH;
      if (h < windowStart || h > windowEnd) continue;
      final isT = lab.unit.isTestosterone;
      if (isT != !state.isTransfem) continue;
      labs.add(LabPoint(hours: h, value: lab.unit.toModelUnit(lab.concValue)));
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 16, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: SegmentedButton<int>(
                segments: [
                  ButtonSegment(
                    value: 1,
                    label: Text(windowDays == 1 ? '1d' : '1d'),
                  ),
                  ButtonSegment(value: 3, label: Text('3d')),
                  ButtonSegment(value: 7, label: Text('7d')),
                  ButtonSegment(value: 30, label: Text('30d')),
                ],
                selected: {windowDays},
                showSelectedIcon: false,
                onSelectionChanged: (v) => onWindowChanged(v.first),
                style: ButtonStyle(
                  visualDensity: VisualDensity.compact,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
            ),
            const SizedBox(height: 8),
            if (points.isEmpty)
              EmptyState(
                icon: Icons.show_chart,
                title: l10n.t('home.noData'),
                body: l10n.t('home.noDataBody'),
              )
            else
              LevelChart(
                points: points,
                labs: labs,
                windowStart: windowStart,
                windowEnd: windowEnd,
                now: nowH,
                low: state.targetLow,
                high: state.targetHigh,
                unit: state.isTransfem ? 'pg/mL' : 'ng/dL',
                height: 240,
              ),
          ],
        ),
      ),
    );
  }
}

class _LatestLabCard extends StatelessWidget {
  const _LatestLabCard({required this.state, required this.onOpen});
  final AppState state;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final labs = state.labs;
    if (labs.isEmpty) {
      return Card(
        child: EmptyState(
          icon: Icons.science_outlined,
          title: l10n.t('home.noLabs'),
          body: l10n.t('labs.emptyBody'),
          action: FilledButton.tonal(
            onPressed: onOpen,
            child: Text(l10n.t('labs.add')),
          ),
        ),
      );
    }
    final latest = labs.reduce((a, b) => a.timeH >= b.timeH ? a : b);
    final modelled = state.sim == null ? null : state.levelAt(latest.timeH);
    final ratio = modelled == null || modelled <= 0
        ? null
        : latest.unit.toModelUnit(latest.concValue) / modelled;
    return Card(
      child: ListTile(
        onTap: onOpen,
        leading: const CircleAvatar(
          child: Icon(Icons.science_outlined, size: 20),
        ),
        title: Text('${formatDose(latest.concValue)} ${latest.unit.code}'),
        subtitle: Text(formatDateTime(context, latest.time)),
        trailing: ratio == null
            ? null
            : Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    '×${ratio.toStringAsFixed(2)}',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  Text(
                    l10n.t('labs.ratio'),
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

class _SupplyWarning extends StatelessWidget {
  const _SupplyWarning({required this.status, required this.onTap});
  final SupplyStatus status;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final days = status.daysLeft;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      color: scheme.tertiaryContainer,
      child: ListTile(
        onTap: onTap,
        leading: Icon(
          Icons.inventory_2_outlined,
          color: scheme.onTertiaryContainer,
        ),
        title: Text(
          '${esterLabel(status.supply.ester, l10n.lang)} · ${l10n.t('home.supplyLow')}',
          style: TextStyle(color: scheme.onTertiaryContainer),
        ),
        subtitle: Text(
          l10n
              .t('home.supplyLowBody')
              .replaceAll(
                '{days}',
                days == null ? '—' : math.max(0, days).ceil().toString(),
              ),
          style: TextStyle(
            color: scheme.onTertiaryContainer.withValues(alpha: 0.8),
          ),
        ),
      ),
    );
  }
}
