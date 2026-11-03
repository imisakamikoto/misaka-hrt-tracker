import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/engine_models.dart';
import '../core/l10n.dart';
import '../data/models.dart';
import '../state/app_state.dart';
import 'settings_pages.dart';
import 'widgets/common.dart';

/// Anti-androgen support and the long view, on one page.
///
/// The page answers three questions in the order they are asked: am I late,
/// is this dose in a range that is used for blockade, and what do the last
/// day, month and year actually look like. It never estimates how much
/// androgen is blocked — see the note at the bottom, which comes from the
/// engine rather than being written here.
class BlockadePage extends StatefulWidget {
  const BlockadePage({super.key});

  @override
  State<BlockadePage> createState() => _BlockadePageState();
}

class _BlockadePageState extends State<BlockadePage> {
  ProgressReport? _progress;
  bool _loading = true;
  String? _error;
  String _signature = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final state = context.read<AppState>();
    final signature =
        '${state.doses.length}:${state.labs.length}:${state.weight}:${state.mode}';
    if (signature == _signature && _progress != null) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final report = await state.engine.progress(
        events: state.doses,
        labs: state.labs,
        bodyWeightKg: state.weight,
        birthYear: state.birthYear,
        params: state.effectivePkParams,
        clearanceMult: state.calibration?.clearanceMult ?? 1,
        e2Target: state.isTransfem
            ? TargetRange(state.targetLow, state.targetHigh)
            : null,
        tTarget: state.isTransfem
            ? null
            : TargetRange(state.targetLow, state.targetHigh),
      );
      if (!mounted) return;
      setState(() {
        _progress = report;
        _signature = signature;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final report = state.blockade;

    return Scaffold(
      appBar: AppBar(title: Text(l10n.t('blockade.title'))),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
          children: [
            Text(
              l10n.t('blockade.intro'),
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 8),
            if (report == null || report.isEmpty)
              Card(
                child: EmptyState(
                  icon: Icons.shield_outlined,
                  title: l10n.t('blockade.empty'),
                  body: l10n.t('blockade.emptyBody'),
                ),
              )
            else ...[
              SectionHeader(
                title: l10n.t('blockade.section.dose'),
                padding: const EdgeInsets.only(top: 16, bottom: 8),
              ),
              for (final compound in report.compounds)
                _CompoundCard(compound: compound),
              SectionHeader(
                title: l10n.t('blockade.section.reminder'),
                padding: const EdgeInsets.only(top: 24, bottom: 8),
              ),
              _ReminderCard(state: state, report: report),
            ],
            SectionHeader(
              title: l10n.t('blockade.section.progress'),
              padding: const EdgeInsets.only(top: 24, bottom: 8),
            ),
            if (_loading)
              const Card(
                child: Padding(
                  padding: EdgeInsets.all(32),
                  child: Center(child: CircularProgressIndicator()),
                ),
              )
            else if (_error != null)
              Card(
                color: scheme.errorContainer,
                child: ListTile(
                  leading: Icon(Icons.memory, color: scheme.onErrorContainer),
                  title: Text(
                    _error!,
                    style: TextStyle(color: scheme.onErrorContainer),
                  ),
                ),
              )
            else if (_progress == null)
              Card(
                child: EmptyState(
                  icon: Icons.timeline,
                  title: l10n.t('progress.noData'),
                  body: l10n.t('progress.noDataBody'),
                ),
              )
            else
              _ProgressTable(report: _progress!),
            const SizedBox(height: 16),
            if (report != null)
              Text(
                report.note,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            if (_progress != null) ...[
              const SizedBox(height: 8),
              Text(
                _progress!.note,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _CompoundCard extends StatelessWidget {
  const _CompoundCard({required this.compound});

  final BlockadeCompound compound;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final ester = Ester.tryParse(compound.ester);
    final name = ester == null
        ? compound.name
        : esterLabel(ester, l10n.lang);
    final verdictColor = switch (compound.verdict) {
      'adequate' => scheme.secondaryContainer,
      'nothingLogged' || 'coverage' => scheme.tertiaryContainer,
      'aboveCeiling' || 'highDose' => scheme.errorContainer,
      _ => scheme.surfaceContainerHighest,
    };
    final verdictForeground = switch (compound.verdict) {
      'adequate' => scheme.onSecondaryContainer,
      'nothingLogged' || 'coverage' => scheme.onTertiaryContainer,
      'aboveCeiling' || 'highDose' => scheme.onErrorContainer,
      _ => scheme.onSurfaceVariant,
    };

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  backgroundColor: scheme.surfaceContainerHighest,
                  child: const Icon(Icons.shield_outlined, size: 20),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(name, style: text.titleMedium),
                      Text(
                        '${formatDose(compound.doseMG)} mg · ${l10n.t('blockade.every')} ${formatDose(compound.intervalH / 24)} ${l10n.t('common.days')}',
                        style: text.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            // The band bar: below the usual range on the left, ceiling on the
            // right, with a marker where the logged dose sits.
            _BandBar(compound: compound),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _Pill(
                  label: l10n.t('blockade.band.${compound.band}'),
                  background: verdictColor,
                  foreground: verdictForeground,
                ),
                _Pill(
                  label:
                      '${l10n.t('blockade.daily')} ${formatDose(compound.dailyMG)} mg',
                  background: scheme.surfaceContainerHighest,
                  foreground: scheme.onSurfaceVariant,
                ),
                _Pill(
                  label:
                      '${l10n.t('blockade.coverage')} ${compound.coveragePct.toStringAsFixed(0)}%',
                  background: compound.coveragePct < 80
                      ? scheme.tertiaryContainer
                      : scheme.surfaceContainerHighest,
                  foreground: compound.coveragePct < 80
                      ? scheme.onTertiaryContainer
                      : scheme.onSurfaceVariant,
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Icon(
                  compound.expectsTestosteroneFall
                      ? Icons.trending_down
                      : Icons.block,
                  size: 16,
                  color: scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    l10n.t(
                      compound.expectsTestosteroneFall
                          ? 'blockade.expectsFall'
                          : 'blockade.noFall',
                    ),
                    style: text.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
            if (compound.level != null) ...[
              const SizedBox(height: 6),
              Row(
                children: [
                  Icon(
                    Icons.show_chart,
                    size: 16,
                    color: scheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '${l10n.t('blockade.level')} '
                      '${compound.level!.trough.toStringAsFixed(0)}–'
                      '${compound.level!.peak.toStringAsFixed(0)} ng/mL',
                      style: text.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 6),
            Row(
              children: [
                Icon(
                  Icons.notifications_outlined,
                  size: 16,
                  color: compound.isOverdue ? scheme.error : scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    compound.isOverdue
                        ? '${l10n.t('blockade.overdue')} ${compound.overdueH.toStringAsFixed(0)} h'
                        : compound.nextDue == null
                        ? '—'
                        : '${l10n.t('blockade.nextDue')} · ${formatDateTime(context, compound.nextDue!)}',
                    style: text.bodySmall?.copyWith(
                      color: compound.isOverdue
                          ? scheme.error
                          : scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
            // The engine's own sentences carry the specifics; they are shown
            // in the language they were written in rather than half-translated.
            if (l10n.lang == 'en')
              for (final note in compound.notes) ...[
                const SizedBox(height: 6),
                Text(
                  note,
                  style: text.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
          ],
        ),
      ),
    );
  }
}

class _BandBar extends StatelessWidget {
  const _BandBar({required this.compound});

  final BlockadeCompound compound;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final ceiling = compound.bandCeilingMG <= 0 ? 1.0 : compound.bandCeilingMG;
    final lowStop = (compound.bandLowMG / ceiling).clamp(0.0, 1.0);
    final highStop = (compound.bandHighMG / ceiling).clamp(0.0, 1.0);
    final position = (compound.dailyMG / ceiling).clamp(0.0, 1.0);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth;
            return SizedBox(
              height: 18,
              width: width,
              child: Stack(
                children: [
                  Positioned(
                    left: 0,
                    right: 0,
                    top: 6,
                    child: Container(
                      height: 6,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(3),
                        gradient: LinearGradient(
                          colors: [
                            scheme.surfaceContainerHighest,
                            scheme.secondaryContainer,
                            scheme.secondaryContainer,
                            scheme.errorContainer,
                          ],
                          stops: [0, lowStop, highStop, 1],
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    left: (position * width - 5).clamp(0.0, width - 10),
                    top: 1,
                    child: Container(
                      width: 10,
                      height: 16,
                      decoration: BoxDecoration(
                        color: scheme.primary,
                        borderRadius: BorderRadius.circular(3),
                        border: Border.all(color: scheme.surface, width: 1.5),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
        Row(
          children: [
            Text(
              '${compound.bandLowMG.toStringAsFixed(0)}',
              style: Theme.of(context).textTheme.labelSmall,
            ),
            const Spacer(),
            Text(
              '${compound.bandHighMG.toStringAsFixed(0)}',
              style: Theme.of(context).textTheme.labelSmall,
            ),
            const Spacer(),
            Text(
              '${ceiling.toStringAsFixed(0)} mg',
              style: Theme.of(context).textTheme.labelSmall,
            ),
          ],
        ),
        const SizedBox(height: 2),
        Text(
          l10n.t('blockade.bandHint'),
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

class _ReminderCard extends StatelessWidget {
  const _ReminderCard({required this.state, required this.report});

  final AppState state;
  final BlockadeReport report;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final overdue = report.mostOverdue;
    return Card(
      child: Column(
        children: [
          SwitchListTile(
            secondary: const Icon(Icons.alarm),
            title: Text(l10n.t('blockade.remindDoses')),
            subtitle: Text(
              l10n.t('blockade.remindDosesDesc'),
              style: Theme.of(context).textTheme.bodySmall,
            ),
            value: state.notifyDoseDue,
            onChanged: state.setNotifyDoseDue,
          ),
          if (overdue != null) ...[
            const Divider(height: 1),
            ListTile(
              leading: Icon(
                Icons.notification_important_outlined,
                color: Theme.of(context).colorScheme.error,
              ),
              title: Text(
                '${l10n.t('blockade.overdue')} ${overdue.overdueH.toStringAsFixed(0)} h',
              ),
              subtitle: Text(
                l10n
                    .t('blockade.dueOverdue')
                    .replaceAll('{drug}', overdue.name)
                    .replaceAll('{hours}', overdue.overdueH.toStringAsFixed(0)),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ],
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.tune),
            title: Text(l10n.t('blockade.leadTime')),
            subtitle: Text(
              '${state.notifyLeadMinutes} ${l10n.t('common.minutes')}',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const NotificationsPage()),
            ),
          ),
        ],
      ),
    );
  }
}

class _ProgressTable extends StatelessWidget {
  const _ProgressTable({required this.report});

  final ProgressReport report;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    // Suppression is a measurement, not a consequence of the drug list. With
    // no testosterone result in any window every row would read "—" and look
    // broken, so the table says why instead of leaving it to be guessed.
    final hasTLabs = report.windows.any((w) => w.tLabsN > 0);

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  flex: 2,
                  child: Text(l10n.t('progress.metric'), style: text.labelLarge),
                ),
                for (final w in report.windows)
                  Expanded(
                    child: Text(
                      l10n.t('progress.window.${w.label}'),
                      textAlign: TextAlign.end,
                      style: text.labelLarge,
                    ),
                  ),
              ],
            ),
            const Divider(height: 20),
            _Row(
              label: l10n.t('progress.suppression'),
              values: [
                for (final w in report.windows) _pct(w.tSuppressionPct),
              ],
              emphasise: true,
            ),
            _Row(
              label: l10n.t('progress.effectiveness'),
              values: [
                for (final w in report.windows) _pct(w.effectivenessPct),
              ],
              emphasise: true,
            ),
            _Row(
              label: l10n.t('progress.tir'),
              values: [for (final w in report.windows) _pct(w.timeInRangePct)],
            ),
            _Row(
              label: l10n.t('progress.coverage'),
              values: [for (final w in report.windows) _pct(w.coveragePct)],
            ),
            _Row(
              label: l10n.t('progress.tLabs'),
              values: [
                for (final w in report.windows)
                  w.tLabsN == 0
                      ? '—'
                      : '${w.tBelowCeiling}/${w.tLabsN}',
              ],
            ),
            _Row(
              label: l10n.t('progress.e2Labs'),
              values: [
                for (final w in report.windows)
                  w.e2LabsN == 0 ? '—' : '${w.e2LabsN}',
              ],
            ),
            const SizedBox(height: 8),
            Text(
              l10n
                  .t('progress.ceiling')
                  .replaceAll('{value}', report.tCeilingNgDl.toStringAsFixed(0)),
              style: text.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
            if (!hasTLabs) ...[
              const SizedBox(height: 6),
              Text(
                l10n.t('progress.noTLabs'),
                style: text.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ],
          ],
        ),
      ),
    );
  }

  static String _pct(double? value) =>
      value == null ? '—' : '${value.toStringAsFixed(0)}%';
}

class _Row extends StatelessWidget {
  const _Row({
    required this.label,
    required this.values,
    this.emphasise = false,
  });

  final String label;
  final List<String> values;
  final bool emphasise;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final style = emphasise ? text.titleSmall : text.bodyMedium;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          Expanded(flex: 2, child: Text(label, style: style)),
          for (final value in values)
            Expanded(
              child: Text(value, textAlign: TextAlign.end, style: style),
            ),
        ],
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({
    required this.label,
    required this.background,
    required this.foreground,
  });

  final String label;
  final Color background;
  final Color foreground;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: Theme.of(
          context,
        ).textTheme.labelMedium?.copyWith(color: foreground),
      ),
    );
  }
}
