import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/domain.dart';
import '../core/l10n.dart';
import '../data/models.dart';
import '../state/app_state.dart';
import 'plan_page.dart';
import 'widgets/common.dart';
import 'widgets/level_chart.dart';

class ForecastPage extends StatefulWidget {
  const ForecastPage({super.key});

  @override
  State<ForecastPage> createState() => _ForecastPageState();
}

class _ForecastPageState extends State<ForecastPage> {
  int _windowDays = 30;
  bool _replace = true;
  bool _loading = false;
  SimulationResult? _planned;
  String? _signature;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _compute());
  }

  Future<void> _compute() async {
    final state = context.read<AppState>();
    if (state.plan.isEmpty) {
      if (mounted) setState(() => _planned = null);
      return;
    }
    setState(() => _loading = true);
    try {
      final now = DateTime.now();
      final horizon = now.add(Duration(days: _windowDays + 1));
      final past = state.doses
          .where((e) => e.timeH > state.nowH - 90 * 24)
          .toList();
      final replacementStart = hoursFromDateTime(
        DateTime(now.year, now.month, now.day),
      );
      final kept = _replace
          ? past
                .where(
                  (e) =>
                      e.timeH >= replacementStart ||
                      !state.plan.any(
                        (p) => p.ester == e.ester && p.ester.isEstradiol,
                      ),
                )
                .toList()
          : past;
      final future = futurePlanDoses(state.plan, now, horizon);
      final events = [...kept, ...future]
        ..sort((a, b) => a.timeH.compareTo(b.timeH));
      final result = await state.simulateEvents(events);
      if (!mounted) return;
      setState(() {
        _planned = result;
        _loading = false;
        _signature = _describeSignature(state);
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  String _describeSignature(AppState state) {
    final parts = state.plan
        .map((p) => '${p.id}:${p.doseMG}:${p.everyDays}:${p.timesPerDay}')
        .join(',');
    return '$parts|$_replace|$_windowDays|${state.doses.length}';
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final signature = _describeSignature(state);

    if (signature != _signature && !_loading) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _compute());
    }

    final nowH = state.nowH;
    final start = nowH;
    final end = nowH + _windowDays * 24;
    final basePoints = <Offset>[];
    final sim = state.sim;
    if (sim != null) {
      for (var i = 0; i < sim.timeH.length; i++) {
        final t = sim.timeH[i];
        if (t < start || t > end) continue;
        basePoints.add(
          Offset(
            t,
            (state.isTransfem ? sim.e2PgMl[i] : sim.tNgDl[i]) *
                (state.calibration?.scale ?? 1),
          ),
        );
      }
    }
    final plannedPoints = <Offset>[];
    final planned = _planned;
    if (planned != null) {
      for (var i = 0; i < planned.timeH.length; i++) {
        final t = planned.timeH[i];
        if (t < start || t > end) continue;
        plannedPoints.add(
          Offset(
            t,
            (state.isTransfem ? planned.e2PgMl[i] : planned.tNgDl[i]) *
                (state.calibration?.scale ?? 1),
          ),
        );
      }
    }

    final baseStats = _stats(basePoints);
    final plannedStats = _stats(plannedPoints);

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          SliverAppBar.large(title: Text(l10n.t('forecast.title'))),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 96),
            sliver: SliverList(
              delegate: SliverChildListDelegate([
                Text(
                  l10n.t('forecast.intro'),
                  style: Theme.of(context).textTheme.bodyMedium
                      ?.copyWith(color: scheme.onSurfaceVariant),
                ),
                const SizedBox(height: 16),
                if (state.plan.isEmpty)
                  Card(
                    child: EmptyState(
                      icon: Icons.tune,
                      title: l10n.t('forecast.noPlan'),
                      body: l10n.t('forecast.noPlanBody'),
                      action: FilledButton.tonal(
                        onPressed: () async {
                          await Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => const PlanPage(),
                            ),
                          );
                          if (mounted) _compute();
                        },
                        child: Text(l10n.t('forecast.addPlan')),
                      ),
                    ),
                  )
                else ...[
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: SegmentedButton<int>(
                                  segments: const [
                                    ButtonSegment(value: 7, label: Text('1w')),
                                    ButtonSegment(value: 30, label: Text('1m')),
                                    ButtonSegment(value: 90, label: Text('3m')),
                                  ],
                                  selected: {_windowDays},
                                  showSelectedIcon: false,
                                  onSelectionChanged: (v) {
                                    setState(() => _windowDays = v.first);
                                    _compute();
                                  },
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          SwitchListTile(
                            contentPadding: EdgeInsets.zero,
                            value: _replace,
                            onChanged: (v) {
                              setState(() => _replace = v);
                              _compute();
                            },
                            title: Text(l10n.t('forecast.replace')),
                            subtitle: Text(
                              l10n.t('forecast.replaceHint'),
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(12, 16, 12, 12),
                      child: Column(
                        children: [
                          if (_loading)
                            const Padding(
                              padding: EdgeInsets.all(32),
                              child: CircularProgressIndicator(),
                            )
                          else if (basePoints.isEmpty && plannedPoints.isEmpty)
                            EmptyState(
                              icon: Icons.show_chart,
                              title: l10n.t('home.noData'),
                              body: l10n.t('home.noDataBody'),
                            )
                          else
                            LevelChart(
                              points: basePoints,
                              compare: plannedPoints,
                              compareLabel: l10n.t('forecast.planned'),
                              windowStart: start,
                              windowEnd: end,
                              low: state.targetLow,
                              high: state.targetHigh,
                              unit: state.isTransfem ? 'pg/mL' : 'ng/dL',
                              height: 260,
                            ),
                          const SizedBox(height: 8),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              _Legend(
                                color: scheme.primary,
                                label: l10n.t('forecast.current'),
                              ),
                              const SizedBox(width: 16),
                              _Legend(
                                color: scheme.tertiary,
                                label: l10n.t('forecast.planned'),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: _StatCard(
                          title: l10n.t('forecast.current'),
                          stats: baseStats,
                          color: scheme.primary,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _StatCard(
                          title: l10n.t('forecast.planned'),
                          stats: plannedStats,
                          color: scheme.tertiary,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Text(
                    l10n.t('forecast.compareNote'),
                    style: Theme.of(context).textTheme.labelSmall
                        ?.copyWith(color: scheme.onSurfaceVariant),
                    textAlign: TextAlign.center,
                  ),
                ],
              ]),
            ),
          ),
        ],
      ),
    );
  }

  ({double? peak, double? trough, double? average}) _stats(
    List<Offset> points,
  ) {
    if (points.isEmpty) return (peak: null, trough: null, average: null);
    var peak = 0.0;
    var trough = double.infinity;
    var sum = 0.0;
    for (final p in points) {
      peak = math.max(peak, p.dy);
      trough = math.min(trough, p.dy);
      sum += p.dy;
    }
    return (peak: peak, trough: trough, average: sum / points.length);
  }
}

class _Legend extends StatelessWidget {
  const _Legend({required this.color, required this.label});
  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(width: 10, height: 3, color: color),
        const SizedBox(width: 6),
        Text(label, style: Theme.of(context).textTheme.labelSmall),
      ],
    );
  }
}

class _StatCard extends StatelessWidget {
  const _StatCard({
    required this.title,
    required this.stats,
    required this.color,
  });

  final String title;
  final ({double? peak, double? trough, double? average}) stats;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final text = Theme.of(context).textTheme;
    String fmt(double? v) =>
        v == null ? '—' : v.toStringAsFixed(v >= 100 ? 0 : 1);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(child: Text(title, style: text.titleSmall)),
              ],
            ),
            const SizedBox(height: 12),
            KeyValueRow(label: l10n.t('forecast.peak'), value: fmt(stats.peak)),
            KeyValueRow(
              label: l10n.t('forecast.trough'),
              value: fmt(stats.trough),
            ),
            KeyValueRow(
              label: l10n.t('forecast.average'),
              value: fmt(stats.average),
            ),
          ],
        ),
      ),
    );
  }
}
