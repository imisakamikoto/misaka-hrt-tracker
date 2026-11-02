import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/l10n.dart';
import '../data/models.dart';
import '../state/app_state.dart';
import 'widgets/common.dart';

class DosePage extends StatefulWidget {
  const DosePage({super.key, this.existing});

  final DoseEvent? existing;

  @override
  State<DosePage> createState() => _DosePageState();
}

class _DosePageState extends State<DosePage> {
  late DoseRoute _route;
  late Ester _ester;
  late DateTime _time;
  final _doseController = TextEditingController();
  final _concentrationController = TextEditingController();
  final _volumeController = TextEditingController();
  final _releaseController = TextEditingController();
  final _areaController = TextEditingController();
  final _wearController = TextEditingController();
  final _holdController = TextEditingController();

  int _gelSite = 0;
  int _holdTier = 2;
  bool _customHold = false;
  String? _error;

  static const _transfemOral = [
    Ester.E2,
    Ester.EV,
    Ester.CPA,
    Ester.SPIRO,
    Ester.BICA,
    Ester.MPA,
    Ester.RLX,
  ];
  static const _transfemInjection = [
    Ester.EV,
    Ester.EB,
    Ester.EC,
    Ester.EN,
    Ester.EU,
    Ester.LEUP,
    Ester.TRIP,
  ];
  static const _transmascInjection = [Ester.TC, Ester.TE, Ester.TU];

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    _route = existing?.route ?? DoseRoute.oral;
    _ester = existing?.ester ?? Ester.E2;
    _time = existing?.time ?? DateTime.now();
    if (existing != null) {
      _doseController.text = formatDose(existing.doseMG);
      final conc = existing.extras[ExtraKey.concentration];
      if (conc != null) _concentrationController.text = formatDose(conc);
      final rate = existing.extras[ExtraKey.releaseRate];
      if (rate != null) _releaseController.text = formatDose(rate);
      final area = existing.extras[ExtraKey.area];
      if (area != null) _areaController.text = formatDose(area);
      final wear = existing.extras[ExtraKey.patchWear];
      if (wear != null) _wearController.text = formatDose(wear);
      _gelSite = existing.gelSiteIndex;
      final theta = existing.extras[ExtraKey.sublingualTheta];
      final tier = existing.extras[ExtraKey.sublingualTier];
      if (theta != null) {
        _customHold = true;
        _holdController.text = _holdFromTheta(theta).toStringAsFixed(0);
      } else if (tier != null) {
        _holdTier = tier.round().clamp(0, 3);
      }
    }
    // Keep the drug valid for the route.
    if (!_drugsFor(_route).contains(_ester)) {
      _ester = _drugsFor(_route).first;
    }
  }

  double _holdFromTheta(double theta) {
    const holds = [2.0, 5.0, 10.0, 15.0];
    const thetas = [0.01, 0.04, 0.11, 0.18];
    if (theta <= thetas.first) return holds.first;
    if (theta >= thetas.last) return holds.last;
    for (var i = 0; i < thetas.length - 1; i++) {
      if (theta >= thetas[i] && theta <= thetas[i + 1]) {
        final t = (theta - thetas[i]) / (thetas[i + 1] - thetas[i]);
        return holds[i] + (holds[i + 1] - holds[i]) * t;
      }
    }
    return holds[2];
  }

  @override
  void dispose() {
    _doseController.dispose();
    _concentrationController.dispose();
    _volumeController.dispose();
    _releaseController.dispose();
    _areaController.dispose();
    _wearController.dispose();
    _holdController.dispose();
    super.dispose();
  }

  List<Ester> _drugsFor(DoseRoute route) {
    final transfem = context.read<AppState>().isTransfem;
    if (transfem) {
      return switch (route) {
        DoseRoute.oral => _transfemOral,
        DoseRoute.sublingual => const [Ester.E2, Ester.EV],
        DoseRoute.injection => _transfemInjection,
        DoseRoute.gel => const [Ester.E2],
        DoseRoute.patchApply || DoseRoute.patchRemove => const [Ester.E2],
      };
    }
    return switch (route) {
      DoseRoute.injection => _transmascInjection,
      DoseRoute.gel => const [Ester.T],
      DoseRoute.patchApply || DoseRoute.patchRemove => const [Ester.T],
      _ => const [Ester.T],
    };
  }

  List<DoseRoute> get _routes {
    final transfem = context.read<AppState>().isTransfem;
    if (transfem) {
      return const [
        DoseRoute.oral,
        DoseRoute.sublingual,
        DoseRoute.injection,
        DoseRoute.gel,
        DoseRoute.patchApply,
        DoseRoute.patchRemove,
      ];
    }
    return const [
      DoseRoute.gel,
      DoseRoute.injection,
      DoseRoute.patchApply,
      DoseRoute.patchRemove,
    ];
  }

  Future<void> _pickTime() async {
    final date = await showDatePicker(
      context: context,
      initialDate: _time,
      firstDate: DateTime(2000),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_time),
    );
    if (time == null || !mounted) return;
    setState(() {
      _time = DateTime(date.year, date.month, date.day, time.hour, time.minute);
    });
  }

  double _resolveDose() {
    final typed = double.tryParse(_doseController.text.replaceAll(',', '.'));
    if (typed != null && typed > 0) return typed;
    final conc = double.tryParse(
      _concentrationController.text.replaceAll(',', '.'),
    );
    final vol = double.tryParse(_volumeController.text.replaceAll(',', '.'));
    if (conc != null && vol != null && conc > 0 && vol > 0) return conc * vol;
    return 0;
  }

  Map<String, double> _extras() {
    final extras = <String, double>{};
    switch (_route) {
      case DoseRoute.gel:
        extras[ExtraKey.gelSite] = _gelSite.toDouble();
      case DoseRoute.sublingual:
        if (_customHold) {
          final hold = double.tryParse(
            _holdController.text.replaceAll(',', '.'),
          );
          if (hold != null && hold > 0) {
            extras[ExtraKey.sublingualTheta] = _thetaFromHold(hold);
          }
        } else {
          extras[ExtraKey.sublingualTier] = _holdTier.toDouble();
        }
      case DoseRoute.patchApply:
        final rate = double.tryParse(
          _releaseController.text.replaceAll(',', '.'),
        );
        if (rate != null && rate > 0) extras[ExtraKey.releaseRate] = rate;
        final area = double.tryParse(_areaController.text.replaceAll(',', '.'));
        if (area != null && area > 0) extras[ExtraKey.area] = area;
        final wear = double.tryParse(_wearController.text.replaceAll(',', '.'));
        if (wear != null && wear > 0) extras[ExtraKey.patchWear] = wear;
      case DoseRoute.injection:
        final conc = double.tryParse(
          _concentrationController.text.replaceAll(',', '.'),
        );
        if (conc != null && conc > 0) extras[ExtraKey.concentration] = conc;
      default:
        break;
    }
    return extras;
  }

  double _thetaFromHold(double hold) {
    const holds = [2.0, 5.0, 10.0, 15.0];
    const thetas = [0.01, 0.04, 0.11, 0.18];
    if (hold <= holds.first) return thetas.first * hold / holds.first;
    if (hold >= holds.last) {
      // Past the longest tier the curve levels off; the model caps near 0.34.
      return (thetas.last + (hold - holds.last) * 0.012).clamp(0.0, 0.6);
    }
    for (var i = 0; i < holds.length - 1; i++) {
      if (hold >= holds[i] && hold <= holds[i + 1]) {
        final t = (hold - holds[i]) / (holds[i + 1] - holds[i]);
        return thetas[i] + (thetas[i + 1] - thetas[i]) * t;
      }
    }
    return thetas[2];
  }

  Future<void> _save() async {
    final dose = _resolveDose();
    if (dose < 0 || dose > 10000) {
      setState(() => _error = context.l10n.t('dose.invalidAmount'));
      return;
    }
    if (_route != DoseRoute.patchApply && dose <= 0) {
      setState(() => _error = context.l10n.t('dose.invalidAmount'));
      return;
    }
    if (_route == DoseRoute.patchApply &&
        dose <= 0 &&
        (double.tryParse(_releaseController.text) ?? 0) <= 0) {
      setState(() => _error = context.l10n.t('dose.invalidAmount'));
      return;
    }
    if (_time.difference(DateTime.now()).inHours > 24) {
      setState(() => _error = context.l10n.t('dose.invalidTime'));
      return;
    }

    final state = context.read<AppState>();
    final event = DoseEvent(
      id: widget.existing?.id ?? state.newId('dose'),
      route: _route,
      timeH: hoursFromDateTime(_time),
      doseMG: dose,
      ester: _ester,
      extras: _extras(),
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    ).copyWith(updatedAt: DateTime.now().millisecondsSinceEpoch);

    if (widget.existing == null) {
      await state.addDose(event);
    } else {
      await state.updateDose(event);
    }
    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  Future<void> _delete() async {
    final existing = widget.existing;
    if (existing == null) return;
    final ok = await ConfirmDialog.show(
      context,
      title: context.l10n.t('dose.deleteConfirm'),
      confirmLabel: context.l10n.t('common.delete'),
      destructive: true,
    );
    if (!ok || !mounted) return;
    await context.read<AppState>().deleteDose(existing.id);
    if (mounted) Navigator.of(context).pop(true);
  }

  Future<void> _saveAsTemplate() async {
    final l10n = context.l10n;
    final nameController = TextEditingController(
      text: '${esterLabel(_ester, l10n.lang)} ${_doseController.text} mg',
    );
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.t('dose.saveTemplate')),
        content: TextField(
          controller: nameController,
          autofocus: true,
          decoration: InputDecoration(labelText: l10n.t('dose.templateName')),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l10n.t('common.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, nameController.text),
            child: Text(l10n.t('common.save')),
          ),
        ],
      ),
    );
    if (name == null || name.trim().isEmpty || !mounted) return;
    final state = context.read<AppState>();
    await state.saveTemplate(
      DoseTemplate(
        id: state.newId('tpl'),
        name: name.trim(),
        route: _route,
        ester: _ester,
        doseMG: _resolveDose(),
        extras: _extras(),
        createdAt: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(l10n.t('common.done'))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final state = context.watch<AppState>();
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final drugs = _drugsFor(_route);
    if (!drugs.contains(_ester)) _ester = drugs.first;

    final quick = state.quickDoses
        .where((q) => q.route == _route && q.ester == _ester)
        .toList();
    final templates = state.templates;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.existing == null ? l10n.t('dose.new') : l10n.t('dose.edit'),
        ),
        actions: [
          if (widget.existing != null)
            IconButton(
              onPressed: _delete,
              icon: const Icon(Icons.delete_outline),
              tooltip: l10n.t('common.delete'),
            ),
          TextButton(onPressed: _save, child: Text(l10n.t('common.save'))),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          if (_error != null)
            Container(
              margin: const EdgeInsets.only(bottom: 12),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: scheme.errorContainer,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                _error!,
                style: TextStyle(color: scheme.onErrorContainer),
              ),
            ),
          SectionHeader(title: l10n.t('dose.route'), padding: EdgeInsets.zero),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final route in _routes)
                ChoiceChip(
                  label: Text(routeLabel(context, route)),
                  selected: _route == route,
                  onSelected: (_) => setState(() {
                    _route = route;
                    final allowed = _drugsFor(route);
                    if (!allowed.contains(_ester)) _ester = allowed.first;
                  }),
                ),
            ],
          ),
          const SizedBox(height: 20),
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
              if (v != null) setState(() => _ester = v);
            },
          ),
          const SizedBox(height: 20),
          if (_route == DoseRoute.injection) ...[
            Row(
              children: [
                Expanded(
                  child: NumberField(
                    controller: _concentrationController,
                    label: l10n.t('dose.concentration'),
                    decimal: true,
                    onChanged: (_) => setState(() {}),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: NumberField(
                    controller: _volumeController,
                    label: l10n.t('dose.volume'),
                    decimal: true,
                    onChanged: (v) {
                      final conc = double.tryParse(
                        _concentrationController.text.replaceAll(',', '.'),
                      );
                      final vol = double.tryParse(v.replaceAll(',', '.'));
                      if (conc != null && vol != null) {
                        setState(
                          () => _doseController.text = formatDose(conc * vol),
                        );
                      }
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
          ],
          NumberField(
            controller: _doseController,
            label: l10n.t('dose.amountMg'),
            suffix: 'mg',
            helper: _route == DoseRoute.injection
                ? (l10n.lang.startsWith('zh')
                      ? '按酯计的实际注射量'
                      : 'mg of the ester injected')
                : null,
          ),
          if (_route == DoseRoute.gel) ...[
            const SizedBox(height: 16),
            Text(l10n.t('dose.site'), style: text.labelLarge),
            const SizedBox(height: 8),
            SegmentedButton<int>(
              segments: [
                ButtonSegment(value: 0, label: Text(l10n.t('dose.site.arm'))),
                ButtonSegment(value: 1, label: Text(l10n.t('dose.site.thigh'))),
                ButtonSegment(
                  value: 2,
                  label: Text(l10n.t('dose.site.scrotal')),
                ),
              ],
              selected: {_gelSite},
              onSelectionChanged: (v) => setState(() => _gelSite = v.first),
            ),
          ],
          if (_route == DoseRoute.sublingual) ...[
            const SizedBox(height: 16),
            Text(l10n.t('dose.hold'), style: text.labelLarge),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                for (var i = 0; i < 4; i++)
                  ChoiceChip(
                    label: Text(
                      l10n.t(
                        [
                          'dose.tier.quick',
                          'dose.tier.casual',
                          'dose.tier.standard',
                          'dose.tier.strict',
                        ][i],
                      ),
                    ),
                    selected: !_customHold && _holdTier == i,
                    onSelected: (_) => setState(() {
                      _customHold = false;
                      _holdTier = i;
                    }),
                  ),
                ChoiceChip(
                  label: Text(l10n.t('dose.customHold')),
                  selected: _customHold,
                  onSelected: (_) => setState(() => _customHold = true),
                ),
              ],
            ),
            if (_customHold) ...[
              const SizedBox(height: 12),
              NumberField(
                controller: _holdController,
                label: l10n.t('dose.hold'),
                suffix: l10n.t('common.minutes'),
                decimal: false,
              ),
            ],
          ],
          if (_route == DoseRoute.patchApply) ...[
            const SizedBox(height: 16),
            NumberField(
              controller: _releaseController,
              label: l10n.t('dose.releaseRate'),
              suffix: 'µg/day',
              decimal: true,
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: NumberField(
                    controller: _areaController,
                    label: l10n.t('dose.area'),
                    suffix: 'cm²',
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: NumberField(
                    controller: _wearController,
                    label: l10n.t('dose.wear'),
                    suffix: 'h',
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              l10n.t('dose.removePatchHint'),
              style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
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
          if (quick.isNotEmpty) ...[
            SectionHeader(
              title: l10n.t('dose.quick'),
              padding: const EdgeInsets.only(top: 24, bottom: 8),
            ),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final q in quick)
                  InputChip(
                    label: Text('${formatDose(q.value)} mg'),
                    onPressed: () {
                      setState(
                        () => _doseController.text = formatDose(q.value),
                      );
                    },
                    onDeleted: () =>
                        context.read<AppState>().removeQuickDose(q.id),
                  ),
              ],
            ),
          ],
          if (templates.isNotEmpty) ...[
            SectionHeader(
              title: l10n.t('dose.templates'),
              padding: const EdgeInsets.only(top: 24, bottom: 8),
            ),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final t in templates)
                  InputChip(
                    avatar: const Icon(Icons.bookmark_outline, size: 18),
                    label: Text(t.name),
                    onPressed: () {
                      setState(() {
                        _route = t.route;
                        _ester = t.ester;
                        _doseController.text = formatDose(t.doseMG);
                        if (t.extras[ExtraKey.gelSite] != null) {
                          _gelSite = t.extras[ExtraKey.gelSite]!.round();
                        }
                      });
                    },
                    onDeleted: () =>
                        context.read<AppState>().deleteTemplate(t.id),
                  ),
              ],
            ),
          ],
          const SizedBox(height: 24),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () {
                    final q = QuickDose(
                      id: state.newId('quick'),
                      route: _route,
                      ester: _ester,
                      value: _resolveDose(),
                      createdAt: DateTime.now().millisecondsSinceEpoch,
                    );
                    if (q.value > 0) context.read<AppState>().addQuickDose(q);
                  },
                  icon: const Icon(Icons.bolt_outlined),
                  label: Text(l10n.t('dose.quickAdd')),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _saveAsTemplate,
                  icon: const Icon(Icons.bookmark_add_outlined),
                  label: Text(l10n.t('dose.saveTemplate')),
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          ExpansionTile(
            title: Text(l10n.t('dose.guide')),
            subtitle: Text(l10n.t('dose.guideBody'), style: text.bodySmall),
            childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            children: [
              for (final line in _guideLines(l10n.lang)) ...[
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        Icons.circle,
                        size: 6,
                        color: scheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 10),
                      Expanded(child: Text(line, style: text.bodySmall)),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  List<String> _guideLines(String lang) {
    final zh = lang.startsWith('zh');
    final transfem = context.read<AppState>().isTransfem;
    if (transfem) {
      return [
        zh ? '口服雌二醇：每天 2–6 mg' : 'Oral estradiol: 2–6 mg a day',
        zh
            ? '舌下雌二醇：每次 0.5–2 mg，每天 1–3 次'
            : 'Sublingual estradiol: 0.5–2 mg, 1–3 times a day',
        zh ? '雌二醇凝胶：每天 1.5–3 mg' : 'Estradiol gel: 1.5–3 mg a day',
        zh ? '雌二醇贴片：每周 50–200 µg/天' : 'Estradiol patch: 50–200 µg/day',
        zh ? '戊酸雌二醇注射：每 5–7 天 2–5 mg' : 'EV injection: 2–5 mg every 5–7 days',
        zh ? '醋酸环丙孕酮：每天 5–12.5 mg' : 'Cyproterone acetate: 5–12.5 mg a day',
      ];
    }
    return [
      zh ? '睾酮凝胶：每天 40–100 mg' : 'Testosterone gel: 40–100 mg a day',
      zh ? '环丙酸/庚酸睾酮：每周 50–100 mg' : 'TC/TE injection: 50–100 mg a week',
      zh ? '十一酸睾酮：每 10 周 1000 mg' : 'TU injection: 1000 mg every 10 weeks',
    ];
  }
}
