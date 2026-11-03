import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/engine_models.dart';
import '../core/l10n.dart';
import '../data/models.dart';
import '../state/app_state.dart';
import 'widgets/common.dart';

/// Bust, underbust and what they add up to.
///
/// Two numbers are on this page and one of them is the point: the difference
/// in centimetres is the measurement, and the cup letter is a convention laid
/// on top of it that changes when you cross a border. So every system the core
/// knows is shown at once, and switching between them moves no numbers — only
/// the letters.
class BodyPage extends StatelessWidget {
  const BodyPage({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final report = state.bodyReport;
    final measurements = state.measurements;

    return Scaffold(
      appBar: AppBar(title: Text(l10n.t('body.title'))),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _addMeasurement(context, state),
        icon: const Icon(Icons.straighten),
        label: Text(l10n.t('body.add')),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
        children: [
          Text(
            l10n.t('body.intro'),
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
          if (report == null || measurements.isEmpty) ...[
            const SizedBox(height: 32),
            EmptyState(
              icon: Icons.straighten,
              title: l10n.t('body.empty'),
              body: l10n.t('body.emptyBody'),
            ),
          ] else ...[
            const SizedBox(height: 16),
            _CupCard(report: report),
            SectionHeader(title: l10n.t('body.growth')),
            _GrowthCard(report: report),
            SectionHeader(title: l10n.t('body.history')),
            for (final m in measurements.reversed)
              _MeasureTile(measure: m, report: report, state: state),
          ],
          const SizedBox(height: 16),
          Text(
            report?.note.isNotEmpty == true
                ? report!.note
                : l10n.t('body.note'),
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _addMeasurement(BuildContext context, AppState state) async {
    final measure = await showModalBottomSheet<BodyMeasure>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const _MeasureSheet(),
    );
    if (measure == null) return;
    await state.saveMeasurement(measure);
  }
}

class _CupCard extends StatelessWidget {
  const _CupCard({required this.report});

  final BodyReport report;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final current = report.sizeIn(state.cupSystem) ?? report.sizes.first;

    return Card(
      color: scheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 18, 18, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              current.label,
              style: text.displaySmall?.copyWith(
                color: scheme.onPrimaryContainer,
                fontWeight: FontWeight.w700,
                letterSpacing: 1,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              l10n
                  .t('body.cupOf')
                  .replaceAll('{diff}', _cm(report.differenceCm))
                  .replaceAll('{band}', _cm(report.bustCm))
                  .replaceAll('{under}', _cm(report.underbustCm)),
              style: text.bodySmall?.copyWith(
                color: scheme.onPrimaryContainer.withValues(alpha: 0.85),
              ),
            ),
            if (report.cupProgress != null) ...[
              const SizedBox(height: 14),
              ClipRRect(
                borderRadius: BorderRadius.circular(999),
                child: LinearProgressIndicator(
                  value: report.cupProgress!.clamp(0.0, 1.0),
                  minHeight: 8,
                  backgroundColor: scheme.onPrimaryContainer.withValues(
                    alpha: 0.15,
                  ),
                  valueColor: AlwaysStoppedAnimation(
                    scheme.onPrimaryContainer,
                  ),
                ),
              ),
            ],
            const SizedBox(height: 14),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final s in report.sizes)
                  ChoiceChip(
                    label: Text(
                      '${s.label} · ${l10n.t('body.system.${s.system}')}',
                    ),
                    selected: s.system == state.cupSystem,
                    onSelected: (_) => state.setCupSystem(s.system),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _GrowthCard extends StatelessWidget {
  const _GrowthCard({required this.report});

  final BodyReport report;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final growth = report.growth;

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: growth == null
            ? Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  l10n.t('body.noGrowth'),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              )
            : Column(
                children: [
                  KeyValueRow(
                    label: l10n.t('body.difference'),
                    value: '${_cm(growth.lastDifferenceCm)} cm',
                  ),
                  KeyValueRow(
                    label: l10n.t('body.change'),
                    value:
                        '${growth.changeCm >= 0 ? '+' : '−'}${_cm(growth.changeCm.abs())} cm',
                  ),
                  KeyValueRow(
                    label: l10n.t('body.rate'),
                    value:
                        '${_cm(growth.rateCmPerMonth)} cm ${l10n.t('body.perMonth')}',
                  ),
                  if (growth.nextCup != null)
                    KeyValueRow(
                      label: l10n.t('body.nextCup'),
                      value: growth.monthsToNextCup == null
                          ? growth.nextCup!
                          : '${growth.nextCup!} · ${_months(growth.monthsToNextCup!)} ${l10n.t('body.months')}',
                    ),
                  KeyValueRow(
                    label: l10n.t('body.span'),
                    value: '${(growth.spanDays / 30.44).round()} '
                        '${l10n.t('body.months')}',
                  ),
                ],
              ),
      ),
    );
  }
}

class _MeasureTile extends StatelessWidget {
  const _MeasureTile({
    required this.measure,
    required this.report,
    required this.state,
  });

  final BodyMeasure measure;
  final BodyReport report;
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final difference = measure.differenceCm;

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: scheme.surfaceContainerHighest,
          child: Text(
            '${measure.time.month}/${measure.time.day}',
            style: Theme.of(context).textTheme.labelSmall,
          ),
        ),
        title: Text('${_cm(measure.bustCm)} / '
            '${measure.underbustCm == null ? '—' : _cm(measure.underbustCm!)} cm'),
        subtitle: Text(
          difference == null
              ? l10n.t('body.needUnderbust')
              : '${l10n.t('body.difference')} ${_cm(difference)} cm',
        ),
        trailing: IconButton(
          icon: const Icon(Icons.delete_outline),
          tooltip: l10n.t('common.delete'),
          onPressed: () async {
            final ok = await showDialog<bool>(
              context: context,
              builder: (_) => ConfirmDialog(
                title: l10n.t('body.delete'),
                body: l10n.t('body.deleteBody'),
                confirmLabel: l10n.t('common.delete'),
              ),
            );
            if (ok == true) await state.deleteMeasurement(measure.id);
          },
        ),
      ),
    );
  }

}

class _MeasureSheet extends StatefulWidget {
  const _MeasureSheet();

  @override
  State<_MeasureSheet> createState() => _MeasureSheetState();
}

class _MeasureSheetState extends State<_MeasureSheet> {
  final _bust = TextEditingController();
  final _underbust = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  DateTime _when = DateTime.now();

  @override
  void dispose() {
    _bust.dispose();
    _underbust.dispose();
    super.dispose();
  }

  double? _parse(String raw) => double.tryParse(raw.replaceAll(',', '.'));

  void _save() {
    if (_formKey.currentState?.validate() != true) return;
    final bust = _parse(_bust.text);
    if (bust == null) return;
    final under = _parse(_underbust.text);
    Navigator.of(context).pop(
      BodyMeasure(
        id: 'bm-${DateTime.now().microsecondsSinceEpoch}',
        timeH: hoursFromDateTime(_when),
        bustCm: bust,
        underbustCm: under != null && under > 0 ? under : null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;

    return Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        20,
        20,
        MediaQuery.viewInsetsOf(context).bottom + 20,
      ),
      child: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.t('body.add'),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 16),
            NumberField(
              controller: _bust,
              label: l10n.t('body.bust'),
              suffix: 'cm',
              autofocus: true,
              validator: (v) {
                final value = _parse(v ?? '');
                if (value == null || value < 40 || value > 250) {
                  return l10n.t('body.invalid');
                }
                return null;
              },
            ),
            const SizedBox(height: 12),
            NumberField(
              controller: _underbust,
              label: l10n.t('body.underbust'),
              suffix: 'cm',
              helper: l10n.t('body.underbustHint'),
              validator: (v) {
                final raw = (v ?? '').trim();
                if (raw.isEmpty) return null;
                final value = _parse(raw);
                if (value == null || value < 40 || value > 250) {
                  return l10n.t('body.invalid');
                }
                final bust = _parse(_bust.text);
                if (bust != null && value >= bust) {
                  return l10n.t('body.underbustTooBig');
                }
                return null;
              },
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Icon(Icons.event, size: 18, color: scheme.onSurfaceVariant),
                const SizedBox(width: 8),
                Text(
                  formatDay(context, _when),
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const Spacer(),
                TextButton(
                  onPressed: () async {
                    final picked = await showDatePicker(
                      context: context,
                      initialDate: _when,
                      firstDate: DateTime(2000),
                      lastDate: DateTime.now(),
                    );
                    if (picked != null) {
                      setState(() {
                        _when = DateTime(
                          picked.year,
                          picked.month,
                          picked.day,
                          12,
                        );
                      });
                    }
                  },
                  child: Text(l10n.t('body.changeDate')),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(l10n.t('common.cancel')),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _save,
                  child: Text(l10n.t('common.save')),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

String _cm(double? value) {
  if (value == null || !value.isFinite) return '—';
  return value == value.roundToDouble()
      ? value.toStringAsFixed(0)
      : value.toStringAsFixed(1);
}

String _months(double value) {
  if (value < 1) return '<1';
  if (value > 120) return '99+';
  return value.toStringAsFixed(0);
}
