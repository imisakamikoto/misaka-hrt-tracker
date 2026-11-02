import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../core/domain.dart';
import '../../core/l10n.dart';
import '../../data/models.dart';
import '../../state/app_state.dart';
import '../widgets/common.dart';
import '../widgets/level_chart.dart';

/// The desktop dashboard.
///
/// Phones stack everything into one column; a window has room for a board: the
/// curve and today's level on the left, what to do next on the right.
class DesktopOverview extends StatefulWidget {
  const DesktopOverview({
    super.key,
    required this.onLogDose,
    required this.onOpenSection,
    required this.onNewDose,
  });

  final VoidCallback onLogDose;
  final ValueChanged<int> onOpenSection;

  /// Kept separate from [onLogDose] so the empty state can say "add" while the
  /// toolbar says "log".
  final VoidCallback onNewDose;

  @override
  State<DesktopOverview> createState() => _DesktopOverviewState();
}

class _DesktopOverviewState extends State<DesktopOverview> {
  int _windowDays = 7;
  bool _seenAdvisory = false;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final now = DateTime.now();
    final hour = now.hour;
    final greeting = hour < 12
        ? l10n.t('home.morning')
        : hour < 18
        ? l10n.t('home.afternoon')
        : l10n.t('home.evening');

    final today = todayDoses(plan: state.plan, doses: state.doses, now: now);
    final advisory = doseAdvisory(state.doses, now);
    final warnings = state.supplyStatuses
        .where((s) => s.daysLeft != null && s.daysLeft! <= state.supplyLeadDays)
        .toList();
    final lastDose = state.doses
        .where((e) => e.timeH <= state.nowH)
        .lastOrNull;

    return Scrollbar(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(32, 28, 32, 40),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1360),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _Greeting(
                  greeting: greeting,
                  subtitle: _subtitle(context, state, lastDose),
                  trailing: state.computing
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : null,
                ),
                if (state.coreError != null) ...[
                  const SizedBox(height: 16),
                  _InlineNotice(
                    icon: Icons.memory,
                    background: scheme.errorContainer,
                    foreground: scheme.onErrorContainer,
                    message: state.coreError!,
                  ),
                ],
                if (advisory != null) ...[
                  const SizedBox(height: 16),
                  _InlineNotice(
                    icon: Icons.info_outline,
                    background: scheme.tertiaryContainer,
                    foreground: scheme.onTertiaryContainer,
                    message: l10n.t(_advisoryKey(advisory)),
                    onDismiss: _seenAdvisory
                        ? null
                        : () => setState(() => _seenAdvisory = true),
                  ),
                ],
                const SizedBox(height: 24),
                LayoutBuilder(
                  builder: (context, constraints) {
                    final wide = constraints.maxWidth >= 1040;
                    final left = Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _LevelBoard(state: state),
                        const SizedBox(height: 24),
                        _CurvePanel(
                          state: state,
                          windowDays: _windowDays,
                          onWindowChanged: (days) =>
                              setState(() => _windowDays = days),
                        ),
                      ],
                    );
                    final right = Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _TodayPanel(
                          items: today,
                          isTransfem: state.isTransfem,
                          onLog: (item) => _logPlanned(state, item),
                          onOpenPlan: () => widget.onOpenSection(4),
                        ),
                        const SizedBox(height: 16),
                        _NextDosePanel(state: state, onOpenPlan: () => widget.onOpenSection(4)),
                        const SizedBox(height: 16),
                        _LabPanel(state: state, onOpenLabs: () => widget.onOpenSection(3)),
                        if (warnings.isNotEmpty) ...[
                          const SizedBox(height: 16),
                          _SupplyPanel(
                            warnings: warnings,
                            onOpen: () => widget.onOpenSection(5),
                          ),
                        ],
                      ],
                    );

                    if (!wide) {
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [left, const SizedBox(height: 24), right],
                      );
                    }
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(flex: 7, child: left),
                        const SizedBox(width: 24),
                        SizedBox(width: 360, child: right),
                      ],
                    );
                  },
                ),
                const SizedBox(height: 28),
                Center(
                  child: Text(
                    l10n.t('disclaimer.short'),
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _subtitle(BuildContext context, AppState state, DoseEvent? lastDose) {
    final l10n = context.l10n;
    final date = DateFormat.MMMMEEEEd(
      Localizations.localeOf(context).toString(),
    ).format(DateTime.now());
    if (lastDose == null) return date;
    final ago = _humanDuration(DateTime.now().difference(lastDose.time), l10n);
    return '$date  ·  ${l10n.t('desktop.lastDose').replaceAll('{when}', ago)}';
  }

  static String _humanDuration(Duration d, L10n l10n) {
    if (d.inMinutes < 60) {
      return '${d.inMinutes} ${l10n.t('common.minutes')}';
    }
    if (d.inHours < 24) {
      final minutes = d.inMinutes % 60;
      return minutes == 0
          ? '${d.inHours} ${l10n.t('common.hours')}'
          : '${d.inHours} ${l10n.t('common.hours')} $minutes ${l10n.t('common.minutes')}';
    }
    return '${d.inDays} ${l10n.t('common.days')}';
  }

  static String _advisoryKey(DoseAdvisoryWarning warning) => switch (warning.kind) {
    'e2_cpa' => 'home.advisory.e2cpa',
    'cpa' => 'home.advisory.cpa',
    't' => 'home.advisory.t',
    _ => 'home.advisory.e2',
  };

  Future<void> _logPlanned(AppState state, TodayDose dose) async {
    final event = DoseEvent(
      id: state.newId('dose'),
      route: dose.item.route,
      timeH: hoursFromDateTime(DateTime.now()),
      doseMG: dose.item.doseMG,
      ester: dose.item.ester,
      extras: Map.of(dose.item.extras),
    );
    await state.addDose(event);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(context.l10n.t('dose.saved'))),
    );
  }
}

class _Greeting extends StatelessWidget {
  const _Greeting({
    required this.greeting,
    required this.subtitle,
    this.trailing,
  });

  final String greeting;
  final String subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                greeting,
                style: text.headlineMedium?.copyWith(
                  fontWeight: FontWeight.w400,
                  letterSpacing: -0.6,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                subtitle,
                style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
        ?trailing,
      ],
    );
  }
}

class _InlineNotice extends StatelessWidget {
  const _InlineNotice({
    required this.icon,
    required this.background,
    required this.foreground,
    required this.message,
    this.onDismiss,
  });

  final IconData icon;
  final Color background;
  final Color foreground;
  final String message;
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 8, 14),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Icon(icon, size: 20, color: foreground),
          const SizedBox(width: 12),
          Expanded(
            child: Text(message, style: TextStyle(color: foreground)),
          ),
          if (onDismiss != null)
            IconButton(
              onPressed: onDismiss,
              icon: Icon(Icons.close, size: 18, color: foreground),
              tooltip: context.l10n.t('common.close'),
            ),
        ],
      ),
    );
  }
}

/// The number the whole app exists for, with the target band drawn to scale.
class _LevelBoard extends StatelessWidget {
  const _LevelBoard({required this.state});
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
                scheme.primary.withValues(alpha: 0.07),
                scheme.surfaceContainerLow,
              ),
            ],
          ),
        ),
        padding: const EdgeInsets.fromLTRB(28, 24, 28, 24),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              flex: 4,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        state.isTransfem
                            ? Icons.spa_outlined
                            : Icons.bolt_outlined,
                        size: 18,
                        color: scheme.primary,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        state.isTransfem ? 'Estradiol' : 'Testosterone',
                        style: text.titleSmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(width: 12),
                      if (level != null)
                        _Pill(
                          label: l10n.t(
                            inRange ? 'home.inRange' : 'home.outOfRange',
                          ),
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
                  const SizedBox(height: 18),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      Text(
                        level == null
                            ? '—'
                            : level.toStringAsFixed(level >= 100 ? 0 : 1),
                        style: text.displayMedium?.copyWith(
                          fontSize: 68,
                          height: 1,
                          fontWeight: FontWeight.w300,
                          letterSpacing: -2,
                          color: level == null
                              ? scheme.onSurfaceVariant
                              : scheme.onSurface,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        unit,
                        style: text.titleMedium?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    l10n.t('home.current'),
                    style: text.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 18),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _Pill(
                        label:
                            '${l10n.t('desktop.targetBand')} · ${state.targetLow.toStringAsFixed(0)}–${state.targetHigh.toStringAsFixed(0)}',
                        background: scheme.surfaceContainerHighest,
                        foreground: scheme.onSurfaceVariant,
                        icon: Icons.straighten,
                      ),
                      if (state.cpaNow != null)
                        _Pill(
                          label: 'CPA ${state.cpaNow!.toStringAsFixed(2)} ng/mL',
                          background: scheme.surfaceContainerHighest,
                          foreground: scheme.onSurfaceVariant,
                          icon: Icons.science_outlined,
                        ),
                      if (state.calibration != null)
                        _Pill(
                          label:
                              '×${state.calibration!.scale.toStringAsFixed(2)}',
                          background: scheme.surfaceContainerHighest,
                          foreground: scheme.onSurfaceVariant,
                          icon: Icons.tune,
                        ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 32),
            Expanded(
              flex: 3,
              child: _TargetGauge(
                level: level,
                low: state.targetLow,
                high: state.targetHigh,
                unit: unit,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A scale with the target band shaded and the current estimate marked.
class _TargetGauge extends StatelessWidget {
  const _TargetGauge({
    required this.level,
    required this.low,
    required this.high,
    required this.unit,
  });

  final double? level;
  final double low;
  final double high;
  final String unit;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final maxValue = math.max(high * 1.6, (level ?? high) * 1.15);
    final ratio = level == null ? null : (level! / maxValue).clamp(0.0, 1.0);
    final lowRatio = (low / maxValue).clamp(0.0, 1.0);
    final highRatio = (high / maxValue).clamp(0.0, 1.0);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          unit,
          style: text.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 20),
        LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth;
            return SizedBox(
              height: 56,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Positioned(
                    left: 0,
                    right: 0,
                    top: 22,
                    child: Container(
                      height: 10,
                      decoration: BoxDecoration(
                        color: scheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(999),
                      ),
                    ),
                  ),
                  Positioned(
                    left: lowRatio * width,
                    width: math.max(8, (highRatio - lowRatio) * width),
                    top: 22,
                    child: Container(
                      height: 10,
                      decoration: BoxDecoration(
                        color: scheme.primary.withValues(alpha: 0.55),
                        borderRadius: BorderRadius.circular(999),
                      ),
                    ),
                  ),
                  if (ratio != null)
                    Positioned(
                      left: (ratio * width - 7).clamp(0.0, width - 14),
                      top: 15,
                      child: Column(
                        children: [
                          Container(
                            width: 14,
                            height: 24,
                            decoration: BoxDecoration(
                              color: scheme.onSurface,
                              borderRadius: BorderRadius.circular(4),
                              border: Border.all(
                                color: scheme.surface,
                                width: 2,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  Positioned(
                    left: lowRatio * width,
                    top: 40,
                    child: Text(
                      low.toStringAsFixed(0),
                      style: text.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  Positioned(
                    left: (highRatio * width - 28).clamp(0.0, width - 32),
                    top: 40,
                    child: Text(
                      high.toStringAsFixed(0),
                      style: text.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
        const SizedBox(height: 6),
        Text(
          '0 — ${maxValue.toStringAsFixed(0)} $unit',
          style: text.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
        ),
      ],
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
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: foreground,
            ),
          ),
        ],
      ),
    );
  }
}

class _CurvePanel extends StatelessWidget {
  const _CurvePanel({
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
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final sim = state.sim;
    final nowH = state.nowH;
    final windowStart = nowH - windowDays * 24;
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
      if (points.length > 900) {
        final step = (points.length / 900).ceil();
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
      if (lab.unit.isTestosterone == state.isTransfem) continue;
      labs.add(LabPoint(hours: h, value: lab.unit.toModelUnit(lab.concValue)));
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(l10n.t('home.curve'), style: text.titleMedium),
                      const SizedBox(height: 2),
                      Text(
                        l10n.t('home.range'),
                        style: text.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                SegmentedButton<int>(
                  segments: const [
                    ButtonSegment(value: 1, label: Text('1d')),
                    ButtonSegment(value: 3, label: Text('3d')),
                    ButtonSegment(value: 7, label: Text('7d')),
                    ButtonSegment(value: 30, label: Text('30d')),
                  ],
                  selected: {windowDays},
                  showSelectedIcon: false,
                  onSelectionChanged: (value) => onWindowChanged(value.first),
                  style: ButtonStyle(
                    visualDensity: VisualDensity.compact,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
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
                height: 340,
              ),
          ],
        ),
      ),
    );
  }
}

class _TodayPanel extends StatelessWidget {
  const _TodayPanel({
    required this.items,
    required this.isTransfem,
    required this.onLog,
    required this.onOpenPlan,
  });

  final List<TodayDose> items;
  final bool isTransfem;
  final void Function(TodayDose) onLog;
  final VoidCallback onOpenPlan;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(child: Text(l10n.t('home.today'), style: text.titleMedium)),
                TextButton(
                  onPressed: onOpenPlan,
                  child: Text(l10n.t('plan.title')),
                ),
              ],
            ),
            if (items.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 20),
                child: Column(
                  children: [
                    Icon(
                      Icons.event_available_outlined,
                      size: 32,
                      color: scheme.onSurfaceVariant,
                    ),
                    const SizedBox(height: 10),
                    Text(l10n.t('home.noPlan'), style: text.bodyMedium),
                    const SizedBox(height: 4),
                    Text(
                      l10n.t('home.noPlanBody'),
                      textAlign: TextAlign.center,
                      style: text.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              )
            else
              for (final item in items)
                _TodayRow(
                  item: item,
                  isTransfem: isTransfem,
                  onLog: () => onLog(item),
                ),
          ],
        ),
      ),
    );
  }
}

class _TodayRow extends StatefulWidget {
  const _TodayRow({
    required this.item,
    required this.isTransfem,
    required this.onLog,
  });

  final TodayDose item;
  final bool isTransfem;
  final VoidCallback onLog;

  @override
  State<_TodayRow> createState() => _TodayRowState();
}

class _TodayRowState extends State<_TodayRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final done = widget.item.isDone;
    final notDay = !widget.item.isDoseDay;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        margin: const EdgeInsets.symmetric(vertical: 2),
        padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
        decoration: BoxDecoration(
          color: _hovered ? scheme.surfaceContainerHigh : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Icon(
              done
                  ? Icons.check_circle
                  : notDay
                  ? Icons.remove_circle_outline
                  : Icons.radio_button_unchecked,
              size: 20,
              color: done
                  ? scheme.primary
                  : notDay
                  ? scheme.outline
                  : scheme.onSurfaceVariant,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${esterLabel(widget.item.item.ester, l10n.lang)} · ${formatDose(widget.item.item.doseMG)} mg',
                    style: text.bodyLarge?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: notDay ? scheme.onSurfaceVariant : null,
                    ),
                  ),
                  Text(
                    notDay
                        ? l10n.t('plan.notDoseDay')
                        : '${l10n.t('home.taken')} ${widget.item.taken}/${widget.item.due} · ${routeLabel(context, widget.item.item.route)}',
                    style: text.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            if (!done && !notDay)
              TextButton(
                onPressed: widget.onLog,
                child: Text(l10n.t('home.taken')),
              ),
          ],
        ),
      ),
    );
  }
}

class _NextDosePanel extends StatelessWidget {
  const _NextDosePanel({required this.state, required this.onOpenPlan});

  final AppState state;
  final VoidCallback onOpenPlan;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final next = nextDoseAt(state.plan, state.doses, DateTime.now());

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.schedule, size: 18, color: scheme.onSurfaceVariant),
                const SizedBox(width: 8),
                Text(l10n.t('home.next'), style: text.titleMedium),
                const Spacer(),
                IconButton(
                  onPressed: onOpenPlan,
                  icon: const Icon(Icons.chevron_right),
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
            const SizedBox(height: 6),
            if (next == null)
              Text(
                l10n.t('home.noPlan'),
                style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
              )
            else
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text(
                    DateFormat.Hm(
                      Localizations.localeOf(context).toString(),
                    ).format(next),
                    style: text.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w400,
                      color: next.isBefore(DateTime.now())
                          ? scheme.error
                          : scheme.onSurface,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      formatDay(context, next),
                      style: text.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
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

class _LabPanel extends StatelessWidget {
  const _LabPanel({required this.state, required this.onOpenLabs});

  final AppState state;
  final VoidCallback onOpenLabs;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final labs = state.labs;

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.science_outlined, size: 18, color: scheme.onSurfaceVariant),
                const SizedBox(width: 8),
                Text(l10n.t('home.latestLab'), style: text.titleMedium),
                const Spacer(),
                TextButton(
                  onPressed: onOpenLabs,
                  child: Text(l10n.t('home.viewAll')),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (labs.isEmpty)
              Text(
                l10n.t('home.noLabs'),
                style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
              )
            else
              Builder(
                builder: (context) {
                  final latest = labs.reduce((a, b) => a.timeH >= b.timeH ? a : b);
                  final modelled = state.sim == null
                      ? null
                      : state.levelAt(latest.timeH);
                  final ratio = modelled == null || modelled <= 0
                      ? null
                      : latest.unit.toModelUnit(latest.concValue) / modelled;
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${formatDose(latest.concValue)} ${latest.unit.code}',
                              style: text.headlineSmall?.copyWith(
                                fontWeight: FontWeight.w400,
                              ),
                            ),
                            Text(
                              formatDateTime(context, latest.time),
                              style: text.bodySmall?.copyWith(
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (ratio != null)
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Text('×${ratio.toStringAsFixed(2)}', style: text.titleMedium),
                            Text(
                              l10n.t('labs.ratio'),
                              style: text.labelSmall?.copyWith(
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                    ],
                  );
                },
              ),
          ],
        ),
      ),
    );
  }
}

class _SupplyPanel extends StatelessWidget {
  const _SupplyPanel({required this.warnings, required this.onOpen});

  final List<SupplyStatus> warnings;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Card(
      color: scheme.tertiaryContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 12, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.inventory_2_outlined,
                  size: 18,
                  color: scheme.onTertiaryContainer,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    l10n.t('supplies.title'),
                    style: text.titleMedium?.copyWith(
                      color: scheme.onTertiaryContainer,
                    ),
                  ),
                ),
                IconButton(
                  onPressed: onOpen,
                  icon: const Icon(Icons.chevron_right),
                  color: scheme.onTertiaryContainer,
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
            for (final status in warnings)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  '${esterLabel(status.supply.ester, l10n.lang)} · '
                  '${l10n.t('home.supplyLowBody').replaceAll('{days}', status.daysLeft == null ? '—' : math.max(0, status.daysLeft!).ceil().toString())}',
                  style: text.bodySmall?.copyWith(
                    color: scheme.onTertiaryContainer,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
