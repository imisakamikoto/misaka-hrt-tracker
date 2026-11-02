import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/domain.dart';
import '../core/l10n.dart';
import '../data/models.dart';
import '../state/app_state.dart';
import 'widgets/common.dart';

class PlanPage extends StatelessWidget {
  const PlanPage({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final l10n = context.l10n;
    final plan = state.plan;
    final today = todayDoses(
      plan: plan,
      doses: state.doses,
      now: DateTime.now(),
    );

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.t('plan.title')),
        actions: [
          IconButton(
            onPressed: () => _edit(context, null),
            icon: const Icon(Icons.add),
            tooltip: l10n.t('plan.add'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          if (plan.isEmpty)
            Card(
              child: EmptyState(
                icon: Icons.event_note_outlined,
                title: l10n.t('plan.empty'),
                body: l10n.t('plan.emptyBody'),
                action: FilledButton.tonal(
                  onPressed: () => _edit(context, null),
                  child: Text(l10n.t('plan.add')),
                ),
              ),
            )
          else
            Card(
              child: Column(
                children: [
                  for (var i = 0; i < plan.length; i++) ...[
                    if (i > 0)
                      const Divider(height: 1, indent: 16, endIndent: 16),
                    ListTile(
                      onTap: () => _edit(context, plan[i]),
                      leading: CircleAvatar(
                        backgroundColor: Theme.of(context)
                            .colorScheme
                            .surfaceContainerHighest,
                        child: Icon(_icon(plan[i].route), size: 20),
                      ),
                      title: Text(
                        '${esterLabel(plan[i].ester, l10n.lang)} · ${formatDose(plan[i].doseMG)} mg',
                      ),
                      subtitle: Text(
                        '${_frequencyLabel(l10n, plan[i])} · ${routeLabel(context, plan[i].route)}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      trailing: IconButton(
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () async {
                          final ok = await ConfirmDialog.show(
                            context,
                            title: '${l10n.t('common.delete')}?',
                            confirmLabel: l10n.t('common.delete'),
                            destructive: true,
                          );
                          if (ok) await state.deletePlanItem(plan[i].id);
                        },
                      ),
                    ),
                  ],
                ],
              ),
            ),
          if (today.isNotEmpty) ...[
            SectionHeader(
              title: l10n.t('home.today'),
              padding: const EdgeInsets.only(top: 24, bottom: 8),
            ),
            Card(
              child: Column(
                children: [
                  for (final item in today)
                    ListTile(
                      leading: Icon(
                        item.isDone
                            ? Icons.check_circle
                            : Icons.radio_button_unchecked,
                        color: item.isDone
                            ? Theme.of(context).colorScheme.primary
                            : Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                      title: Text(
                        '${esterLabel(item.item.ester, l10n.lang)} ${formatDose(item.item.doseMG)} mg',
                      ),
                      subtitle: Text(
                        item.isDoseDay
                            ? '${l10n.t('home.taken')} ${item.taken}/${item.due}'
                            : l10n.t('plan.notDoseDay'),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  static String _frequencyLabel(L10n l10n, PlanItem item) {
    final zh = l10n.lang.startsWith('zh');
    if (item.everyDays <= 1) {
      if (item.timesPerDay == 1) return zh ? '每天 1 次' : 'Once a day';
      return zh ? '每天 ${item.timesPerDay} 次' : '${item.timesPerDay}× a day';
    }
    return zh
        ? '每 ${formatDose(item.everyDays)} 天'
        : 'Every ${formatDose(item.everyDays)} days';
  }

  static IconData _icon(DoseRoute route) => switch (route) {
    DoseRoute.injection => Icons.vaccines_outlined,
    DoseRoute.gel => Icons.water_drop_outlined,
    DoseRoute.patchApply => Icons.sticky_note_2_outlined,
    DoseRoute.sublingual => Icons.medication_liquid_outlined,
    DoseRoute.oral => Icons.medication_outlined,
    DoseRoute.patchRemove => Icons.remove_circle_outline,
  };

  static Future<void> _edit(BuildContext context, PlanItem? existing) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PlanEditorPage(existing: existing),
        fullscreenDialog: true,
      ),
    );
  }
}

class PlanEditorPage extends StatefulWidget {
  const PlanEditorPage({super.key, this.existing});
  final PlanItem? existing;

  @override
  State<PlanEditorPage> createState() => _PlanEditorPageState();
}

class _PlanEditorPageState extends State<PlanEditorPage> {
  late Ester _ester;
  late DoseRoute _route;
  final _doseController = TextEditingController();
  final _customFrequencyController = TextEditingController();
  double _everyDays = 1;
  int _timesPerDay = 1;
  bool _custom = false;

  static const _drugsTransfem = [
    Ester.E2,
    Ester.EV,
    Ester.EB,
    Ester.EC,
    Ester.EN,
    Ester.EU,
    Ester.CPA,
    Ester.SPIRO,
    Ester.BICA,
    Ester.MPA,
    Ester.RLX,
    Ester.LEUP,
    Ester.TRIP,
  ];
  static const _drugsTransmasc = [Ester.T, Ester.TC, Ester.TE, Ester.TU];

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    final transfem = context.read<AppState>().isTransfem;
    _ester = existing?.ester ?? (transfem ? Ester.E2 : Ester.T);
    _route = existing?.route ?? _routesFor(_ester).first;
    _doseController.text = existing == null ? '' : formatDose(existing.doseMG);
    if (existing != null) {
      _everyDays = existing.everyDays;
      _timesPerDay = existing.timesPerDay;
      _custom = parseFrequency(existing.key) == null;
      if (_custom) _customFrequencyController.text = existing.key;
    }
  }

  @override
  void dispose() {
    _doseController.dispose();
    _customFrequencyController.dispose();
    super.dispose();
  }

  List<DoseRoute> _routesFor(Ester ester) {
    if (ester.isEstradiol) {
      if (ester == Ester.E2) {
        return [
          DoseRoute.oral,
          DoseRoute.sublingual,
          DoseRoute.gel,
          DoseRoute.patchApply,
        ];
      }
      if (ester == Ester.EV)
        return [DoseRoute.oral, DoseRoute.sublingual, DoseRoute.injection];
      return [DoseRoute.injection];
    }
    if (ester.isTestosterone) {
      if (ester == Ester.T) return [DoseRoute.gel, DoseRoute.patchApply];
      return [DoseRoute.injection];
    }
    if (ester.isGnrhAgonist) return [DoseRoute.injection];
    return [DoseRoute.oral];
  }

  Future<void> _save() async {
    final dose = double.tryParse(_doseController.text.replaceAll(',', '.'));
    if (dose == null || dose < 0 || dose > 10000) return;
    final state = context.read<AppState>();
    final frequency = _custom
        ? parseFrequency(_customFrequencyController.text.trim())
        : Frequency(
            frequencyKey(_everyDays, _timesPerDay),
            _everyDays,
            _timesPerDay,
          );
    if (frequency == null) return;
    await state.savePlanItem(
      PlanItem(
        id: widget.existing?.id ?? state.newId('plan'),
        route: _route,
        ester: _ester,
        doseMG: dose,
        extras: widget.existing?.extras ?? {},
        everyDays: frequency.everyDays,
        timesPerDay: frequency.timesPerDay,
      ),
    );
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final state = context.watch<AppState>();
    final drugs = state.isTransfem ? _drugsTransfem : _drugsTransmasc;
    final routes = _routesFor(_ester);

    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.existing == null ? l10n.t('plan.add') : l10n.t('plan.edit'),
        ),
        actions: [
          TextButton(onPressed: _save, child: Text(l10n.t('common.save'))),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          DropdownMenu<Ester>(
            initialSelection: _ester,
            width: double.infinity,
            label: Text(l10n.t('dose.drug')),
            dropdownMenuEntries: [
              for (final ester in drugs)
                DropdownMenuEntry(
                  value: ester,
                  label: esterLabel(ester, l10n.lang),
                ),
            ],
            onSelected: (v) {
              if (v == null) return;
              setState(() {
                _ester = v;
                final allowed = _routesFor(v);
                if (!allowed.contains(_route)) _route = allowed.first;
              });
            },
          ),
          const SizedBox(height: 20),
          Text(
            l10n.t('dose.route'),
            style: Theme.of(context).textTheme.labelLarge,
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              for (final route in routes)
                ChoiceChip(
                  label: Text(routeLabel(context, route)),
                  selected: _route == route,
                  onSelected: (_) => setState(() => _route = route),
                ),
            ],
          ),
          const SizedBox(height: 20),
          NumberField(
            controller: _doseController,
            label: l10n.t('dose.amountMg'),
            suffix: 'mg',
          ),
          const SizedBox(height: 20),
          Text(
            l10n.t('plan.frequency'),
            style: Theme.of(context).textTheme.labelLarge,
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final preset in frequencyPresets)
                ChoiceChip(
                  label: Text(_presetLabel(l10n, preset)),
                  selected:
                      !_custom &&
                      preset.everyDays == _everyDays &&
                      preset.timesPerDay == _timesPerDay,
                  onSelected: (_) => setState(() {
                    _custom = false;
                    _everyDays = preset.everyDays;
                    _timesPerDay = preset.timesPerDay;
                  }),
                ),
              ChoiceChip(
                label: Text(l10n.t('plan.customFrequency')),
                selected: _custom,
                onSelected: (_) => setState(() => _custom = true),
              ),
            ],
          ),
          if (_custom) ...[
            const SizedBox(height: 12),
            TextField(
              controller: _customFrequencyController,
              decoration: InputDecoration(
                labelText: l10n.t('plan.frequency'),
                helperText: l10n.lang.startsWith('zh')
                    ? '例如 e4 表示每 4 天一次，d2 表示每天两次'
                    : 'e4 = every 4 days, d2 = twice a day',
              ),
            ),
          ],
        ],
      ),
    );
  }

  String _presetLabel(L10n l10n, Frequency preset) {
    final zh = l10n.lang.startsWith('zh');
    if (preset.everyDays <= 1) {
      return zh ? '每天 ${preset.timesPerDay} 次' : '${preset.timesPerDay}/day';
    }
    return zh
        ? '每 ${formatDose(preset.everyDays)} 天'
        : '${formatDose(preset.everyDays)}d';
  }
}
