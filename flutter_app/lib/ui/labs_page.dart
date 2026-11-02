import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../core/l10n.dart';
import '../data/models.dart';
import '../state/app_state.dart';
import 'calibration_page.dart';
import 'widgets/common.dart';
import 'widgets/level_chart.dart';

class LabsPage extends StatelessWidget {
  const LabsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final labs = [...state.labs]..sort((a, b) => b.timeH.compareTo(a.timeH));

    final nowH = state.nowH;
    final windowStart = nowH - 90 * 24;
    final windowEnd = nowH + 24;

    final points = <Offset>[];
    final sim = state.sim;
    if (sim != null) {
      for (var i = 0; i < sim.timeH.length; i++) {
        final t = sim.timeH[i];
        if (t < windowStart || t > windowEnd) continue;
        points.add(
          Offset(
            t,
            (state.isTransfem ? sim.e2PgMl[i] : sim.tNgDl[i]) *
                (state.calibration?.scale ?? 1),
          ),
        );
      }
    }
    final labPoints = <LabPoint>[];
    for (final lab in labs) {
      if (lab.unit.isTestosterone == state.isTransfem) continue;
      labPoints.add(
        LabPoint(hours: lab.timeH, value: lab.unit.toModelUnit(lab.concValue)),
      );
    }

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          SliverAppBar.large(
            title: Text(l10n.t('labs.title')),
            actions: [
              IconButton(
                onPressed: () => _openForm(context),
                icon: const Icon(Icons.add),
                tooltip: l10n.t('labs.add'),
              ),
            ],
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 96),
            sliver: SliverList(
              delegate: SliverChildListDelegate([
                if (points.isNotEmpty || labPoints.isNotEmpty)
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(12, 16, 12, 8),
                      child: LevelChart(
                        points: points,
                        labs: labPoints,
                        windowStart: windowStart,
                        windowEnd: windowEnd,
                        low: state.targetLow,
                        high: state.targetHigh,
                        unit: state.isTransfem ? 'pg/mL' : 'ng/dL',
                        height: 220,
                      ),
                    ),
                  ),
                const SizedBox(height: 12),
                Card(
                  child: ListTile(
                    leading: CircleAvatar(
                      backgroundColor: scheme.tertiaryContainer,
                      child: Icon(
                        Icons.tune,
                        color: scheme.onTertiaryContainer,
                      ),
                    ),
                    title: Text(l10n.t('cal.title')),
                    subtitle: Text(
                      state.calibrationMethod == 'off'
                          ? l10n.t('cal.off')
                          : '${state.calibrationMethod.toUpperCase()} · ${l10n.t('cal.n')} ${state.calibration?.n ?? 0}',
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const CalibrationPage(),
                      ),
                    ),
                  ),
                ),
                SectionHeader(
                  title: l10n.t('labs.title'),
                  padding: const EdgeInsets.only(top: 24, bottom: 8),
                ),
                if (labs.isEmpty)
                  Card(
                    child: EmptyState(
                      icon: Icons.science_outlined,
                      title: l10n.t('labs.empty'),
                      body: l10n.t('labs.emptyBody'),
                      action: FilledButton.tonal(
                        onPressed: () => _openForm(context),
                        child: Text(l10n.t('labs.add')),
                      ),
                    ),
                  )
                else
                  Card(
                    child: Column(
                      children: [
                        for (var i = 0; i < labs.length; i++) ...[
                          if (i > 0)
                            const Divider(height: 1, indent: 16, endIndent: 16),
                          _LabRow(lab: labs[i]),
                        ],
                      ],
                    ),
                  ),
              ]),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _openForm(BuildContext context, {LabResult? existing}) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => LabFormPage(existing: existing),
        fullscreenDialog: true,
      ),
    );
  }
}

class _LabRow extends StatelessWidget {
  const _LabRow({required this.lab});
  final LabResult lab;

  @override
  Widget build(BuildContext context) {
    final state = context.read<AppState>();
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final modelled = state.sim == null ? null : state.levelAt(lab.timeH);
    final obs = lab.unit.toModelUnit(lab.concValue);
    final ratio = modelled == null || modelled <= 0 ? null : obs / modelled;
    final date = DateFormat.yMMMd(Localizations.localeOf(context).toString())
        .add_Hm()
        .format(lab.time);

    return ListTile(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => LabFormPage(existing: lab),
          fullscreenDialog: true,
        ),
      ),
      title: Text('${formatDose(lab.concValue)} ${lab.unit.code}'),
      subtitle: Text(
        [date, if (lab.assay != null) lab.assay!.toUpperCase()].join(' · '),
        style: Theme.of(context).textTheme.bodySmall
            ?.copyWith(color: scheme.onSurfaceVariant),
      ),
      trailing: ratio == null
          ? const Icon(Icons.trending_flat)
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
                  style: Theme.of(context).textTheme.labelSmall
                      ?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ],
            ),
    );
  }
}

class LabFormPage extends StatefulWidget {
  const LabFormPage({super.key, this.existing});
  final LabResult? existing;

  @override
  State<LabFormPage> createState() => _LabFormPageState();
}

class _LabFormPageState extends State<LabFormPage> {
  late final TextEditingController _valueController;
  late LabUnit _unit;
  late DateTime _time;
  String? _assay;
  String? _error;

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    final transfem = context.read<AppState>().isTransfem;
    _valueController = TextEditingController(
      text: existing == null ? '' : formatDose(existing.concValue),
    );
    _unit = existing?.unit ?? (transfem ? LabUnit.pgMl : LabUnit.ngDl);
    _time = existing?.time ?? DateTime.now();
    _assay = existing?.assay;
  }

  @override
  void dispose() {
    _valueController.dispose();
    super.dispose();
  }

  Future<void> _pickTime() async {
    final date = await showDatePicker(
      context: context,
      initialDate: _time,
      firstDate: DateTime(2000),
      lastDate: DateTime.now().add(const Duration(days: 1)),
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_time),
    );
    if (time == null || !mounted) return;
    setState(
      () => _time = DateTime(
        date.year,
        date.month,
        date.day,
        time.hour,
        time.minute,
      ),
    );
  }

  Future<void> _save() async {
    final value = double.tryParse(_valueController.text.replaceAll(',', '.'));
    if (value == null || value <= 0 || value > 100000) {
      setState(() => _error = context.l10n.t('dose.invalidAmount'));
      return;
    }
    final state = context.read<AppState>();
    await state.saveLab(
      LabResult(
        id: widget.existing?.id ?? state.newId('lab'),
        timeH: hoursFromDateTime(_time),
        concValue: value,
        unit: _unit,
        assay: _assay,
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _delete() async {
    final existing = widget.existing;
    if (existing == null) return;
    final ok = await ConfirmDialog.show(
      context,
      title: context.l10n.t('labs.deleteConfirm'),
      confirmLabel: context.l10n.t('common.delete'),
      destructive: true,
    );
    if (!ok || !mounted) return;
    await context.read<AppState>().deleteLab(existing.id);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final state = context.watch<AppState>();
    final units = state.isTransfem
        ? [LabUnit.pgMl, LabUnit.pmolL]
        : [LabUnit.ngDl, LabUnit.nmolL];

    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.existing == null ? l10n.t('labs.add') : l10n.t('labs.edit'),
        ),
        actions: [
          if (widget.existing != null)
            IconButton(
              onPressed: _delete,
              icon: const Icon(Icons.delete_outline),
            ),
          TextButton(onPressed: _save, child: Text(l10n.t('common.save'))),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          NumberField(
            controller: _valueController,
            label: l10n.t('labs.value'),
            autofocus: widget.existing == null,
          ),
          const SizedBox(height: 16),
          Text(
            l10n.t('labs.unit'),
            style: Theme.of(context).textTheme.labelLarge,
          ),
          const SizedBox(height: 8),
          SegmentedButton<LabUnit>(
            segments: [
              for (final unit in units)
                ButtonSegment(value: unit, label: Text(unit.code)),
            ],
            selected: {_unit},
            onSelectionChanged: (v) => setState(() => _unit = v.first),
          ),
          const SizedBox(height: 20),
          Text(
            l10n.t('labs.assay'),
            style: Theme.of(context).textTheme.labelLarge,
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              ChoiceChip(
                label: Text(l10n.t('labs.assay.unsure')),
                selected: _assay == null,
                onSelected: (_) => setState(() => _assay = null),
              ),
              ChoiceChip(
                label: Text(l10n.t('labs.assay.immuno')),
                selected: _assay == 'immuno',
                onSelected: (_) => setState(() => _assay = 'immuno'),
              ),
              ChoiceChip(
                label: Text(l10n.t('labs.assay.lcms')),
                selected: _assay == 'lcms',
                onSelected: (_) => setState(() => _assay = 'lcms'),
              ),
            ],
          ),
          const SizedBox(height: 20),
          Card(
            child: ListTile(
              leading: const Icon(Icons.schedule),
              title: Text(l10n.t('dose.time')),
              subtitle: Text(
                formatDay(context, _time) +
                    ' · ' +
                    formatDateTime(context, _time),
              ),
              trailing: const Icon(Icons.edit_calendar_outlined),
              onTap: _pickTime,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            l10n.t('cal.intro'),
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
