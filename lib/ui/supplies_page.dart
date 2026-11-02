import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../core/domain.dart';
import '../core/l10n.dart';
import '../data/models.dart';
import '../state/app_state.dart';
import 'widgets/common.dart';

class SuppliesPage extends StatelessWidget {
  const SuppliesPage({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final statuses = state.supplyStatuses;

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.t('supplies.title')),
        actions: [
          IconButton(
            onPressed: () => _edit(context, null),
            icon: const Icon(Icons.add),
            tooltip: l10n.t('supplies.add'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          if (statuses.isEmpty)
            Card(
              child: EmptyState(
                icon: Icons.inventory_2_outlined,
                title: l10n.t('supplies.empty'),
                body: l10n.t('supplies.emptyBody'),
                action: FilledButton.tonal(
                  onPressed: () => _edit(context, null),
                  child: Text(l10n.t('supplies.add')),
                ),
              ),
            )
          else
            for (final status in statuses)
              Card(
                margin: const EdgeInsets.only(bottom: 12),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          CircleAvatar(
                            backgroundColor: scheme.surfaceContainerHighest,
                            child: Icon(
                              _routeIcon(status.supply.route),
                              size: 20,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  esterLabel(status.supply.ester, l10n.lang),
                                  style: Theme.of(context)
                                      .textTheme
                                      .titleMedium,
                                ),
                                Text(
                                  routeLabel(context, status.supply.route),
                                  style: Theme.of(context).textTheme.bodySmall
                                      ?.copyWith(
                                        color: scheme.onSurfaceVariant,
                                      ),
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            onPressed: () => _edit(context, status.supply),
                            icon: const Icon(Icons.edit_outlined),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: _Metric(
                              label: l10n.t('supplies.remaining'),
                              value: status.supply.route == DoseRoute.patchApply
                                  ? '${status.remaining.toStringAsFixed(0)}'
                                  : '${status.remaining.toStringAsFixed(1)} mg',
                              warning:
                                  status.daysLeft != null &&
                                  status.daysLeft! <= state.supplyLeadDays,
                            ),
                          ),
                          Expanded(
                            child: _Metric(
                              label: l10n.t('supplies.runOut'),
                              value: status.runOut == null
                                  ? l10n.t('supplies.noRate')
                                  : DateFormat.yMMMd(
                                      Localizations.localeOf(context)
                                          .toString(),
                                    ).format(status.runOut!),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      LinearProgressIndicator(
                        value: _fraction(status),
                        minHeight: 6,
                        borderRadius: BorderRadius.circular(3),
                        color:
                            status.daysLeft != null &&
                                status.daysLeft! <= state.supplyLeadDays
                            ? scheme.error
                            : scheme.primary,
                        backgroundColor: scheme.surfaceContainerHighest,
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Text(
                            '${status.supply.count.toStringAsFixed(0)} × ${_packLabel(l10n, status.supply.pack)}',
                            style: Theme.of(context).textTheme.labelSmall
                                ?.copyWith(color: scheme.onSurfaceVariant),
                          ),
                          const Spacer(),
                          TextButton.icon(
                            onPressed: () => _restock(context, status.supply),
                            icon: const Icon(
                              Icons.add_circle_outline,
                              size: 18,
                            ),
                            label: Text(l10n.t('supplies.restock')),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
        ],
      ),
    );
  }

  static double _fraction(SupplyStatus status) {
    final total = status.supply.count * status.supply.pack.unitMG;
    if (total <= 0) return 0;
    return (status.remaining / total).clamp(0.0, 1.0);
  }

  static String _packLabel(L10n l10n, Pack pack) => switch (pack.kind) {
    'vial' => '${l10n.t('supplies.pack.vial')} ${(pack as VialPack).ml} mL',
    'pill' => '${l10n.t('supplies.pack.pill')} ${(pack as PillPack).mg} mg',
    'pump' => '${l10n.t('supplies.pack.pump')} ${(pack as PumpPack).mg} mg',
    'sachet' =>
      '${l10n.t('supplies.pack.sachet')} ${(pack as SachetPack).mg} mg',
    'patch' => l10n.t('supplies.pack.patch'),
    _ => l10n.t('supplies.pack.bulk'),
  };

  static IconData _routeIcon(DoseRoute route) => switch (route) {
    DoseRoute.injection => Icons.vaccines_outlined,
    DoseRoute.gel => Icons.water_drop_outlined,
    DoseRoute.patchApply => Icons.sticky_note_2_outlined,
    DoseRoute.sublingual => Icons.medication_liquid_outlined,
    DoseRoute.oral => Icons.medication_outlined,
    DoseRoute.patchRemove => Icons.remove_circle_outline,
  };

  static Future<void> _edit(BuildContext context, Supply? existing) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SupplyEditorPage(existing: existing),
        fullscreenDialog: true,
      ),
    );
  }

  static Future<void> _restock(BuildContext context, Supply supply) async {
    final l10n = context.l10n;
    final controller = TextEditingController(text: '1');
    final units = await showDialog<double>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.t('supplies.restock')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(l10n.t('supplies.restockHint')),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              autofocus: true,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(labelText: l10n.t('supplies.count')),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l10n.t('common.cancel')),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(context, double.tryParse(controller.text)),
            child: Text(l10n.t('common.save')),
          ),
        ],
      ),
    );
    if (units == null || units <= 0) return;
    if (!context.mounted) return;
    await context.read<AppState>().saveSupply(
      Supply(
        id: supply.id,
        route: supply.route,
        ester: supply.ester,
        pack: supply.pack,
        count: supply.count + units,
        startedAt: supply.startedAt,
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({
    required this.label,
    required this.value,
    this.warning = false,
  });
  final String label;
  final String value;
  final bool warning;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: Theme.of(context).textTheme.labelSmall
              ?.copyWith(color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          style: Theme.of(context).textTheme.titleMedium
              ?.copyWith(color: warning ? scheme.error : null),
        ),
      ],
    );
  }
}

class SupplyEditorPage extends StatefulWidget {
  const SupplyEditorPage({super.key, this.existing});
  final Supply? existing;

  @override
  State<SupplyEditorPage> createState() => _SupplyEditorPageState();
}

class _SupplyEditorPageState extends State<SupplyEditorPage> {
  late Ester _ester;
  late DoseRoute _route;
  late String _packKind;
  final _countController = TextEditingController(text: '1');
  final _mlController = TextEditingController(text: '10');
  final _mgPerMlController = TextEditingController(text: '10');
  final _mgController = TextEditingController(text: '2');

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    final state = context.read<AppState>();
    _ester = existing?.ester ?? (state.isTransfem ? Ester.E2 : Ester.T);
    _route =
        existing?.route ??
        (_ester.isTestosterone ? DoseRoute.gel : DoseRoute.oral);
    _packKind = existing?.pack.kind ?? defaultPackFor(_route).kind;
    if (existing != null) {
      _countController.text = existing.count.toStringAsFixed(0);
      final pack = existing.pack;
      if (pack is VialPack) {
        _mlController.text = formatDose(pack.ml);
        _mgPerMlController.text = formatDose(pack.mgPerMl);
      } else if (pack is PillPack) {
        _mgController.text = formatDose(pack.mg);
      } else if (pack is PumpPack) {
        _mgController.text = formatDose(pack.mg);
      } else if (pack is SachetPack) {
        _mgController.text = formatDose(pack.mg);
      }
    }
  }

  @override
  void dispose() {
    _countController.dispose();
    _mlController.dispose();
    _mgPerMlController.dispose();
    _mgController.dispose();
    super.dispose();
  }

  Pack _buildPack() {
    switch (_packKind) {
      case 'vial':
        return VialPack(
          ml: double.tryParse(_mlController.text) ?? 1,
          mgPerMl: double.tryParse(_mgPerMlController.text) ?? 1,
        );
      case 'pill':
        return PillPack(mg: double.tryParse(_mgController.text) ?? 1);
      case 'pump':
        return PumpPack(mg: double.tryParse(_mgController.text) ?? 1);
      case 'sachet':
        return SachetPack(mg: double.tryParse(_mgController.text) ?? 1);
      case 'patch':
        return const PatchPack();
      default:
        return const BulkPack();
    }
  }

  Future<void> _save() async {
    final state = context.read<AppState>();
    final count = double.tryParse(_countController.text);
    if (count == null || count <= 0) return;
    await state.saveSupply(
      Supply(
        id: widget.existing?.id ?? state.newId('supply'),
        route: _route,
        ester: _ester,
        pack: _buildPack(),
        count: count,
        startedAt:
            widget.existing?.startedAt ?? DateTime.now().millisecondsSinceEpoch,
      ),
    );
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _delete() async {
    final existing = widget.existing;
    if (existing == null) return;
    final ok = await ConfirmDialog.show(
      context,
      title: '${context.l10n.t('common.delete')}?',
      confirmLabel: context.l10n.t('common.delete'),
      destructive: true,
    );
    if (!ok || !mounted) return;
    await context.read<AppState>().deleteSupply(existing.id);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final state = context.watch<AppState>();
    final drugs = state.isTransfem
        ? Ester.values.where((e) => !e.isTestosterone).toList()
        : Ester.values.where((e) => e.isTestosterone).toList();
    final routes = switch (_ester) {
      Ester.E2 => [
        DoseRoute.oral,
        DoseRoute.sublingual,
        DoseRoute.gel,
        DoseRoute.patchApply,
      ],
      Ester.EV => [DoseRoute.oral, DoseRoute.sublingual, DoseRoute.injection],
      Ester.T => [DoseRoute.gel, DoseRoute.patchApply],
      final e when e.isTestosterone => [DoseRoute.injection],
      final e when e.isGnrhAgonist => [DoseRoute.injection],
      final e when e.isUnmodelled || e == Ester.CPA => [DoseRoute.oral],
      _ => [DoseRoute.injection],
    };

    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.existing == null
              ? l10n.t('supplies.add')
              : l10n.t('supplies.edit'),
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
                final allowed = switch (v) {
                  Ester.E2 => [
                    DoseRoute.oral,
                    DoseRoute.sublingual,
                    DoseRoute.gel,
                    DoseRoute.patchApply,
                  ],
                  Ester.EV => [
                    DoseRoute.oral,
                    DoseRoute.sublingual,
                    DoseRoute.injection,
                  ],
                  Ester.T => [DoseRoute.gel, DoseRoute.patchApply],
                  final e when e.isTestosterone => [DoseRoute.injection],
                  final e when e.isUnmodelled || e == Ester.CPA => [
                    DoseRoute.oral,
                  ],
                  _ => [DoseRoute.injection],
                };
                if (!allowed.contains(_route)) _route = allowed.first;
                _packKind = defaultPackFor(_route).kind;
              });
            },
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            children: [
              for (final route in routes)
                ChoiceChip(
                  label: Text(routeLabel(context, route)),
                  selected: _route == route,
                  onSelected: (_) => setState(() {
                    _route = route;
                    _packKind = defaultPackFor(route).kind;
                  }),
                ),
            ],
          ),
          const SizedBox(height: 20),
          Text(
            l10n.t('supplies.pack'),
            style: Theme.of(context).textTheme.labelLarge,
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              for (final kind in _kindsFor(_route))
                ChoiceChip(
                  label: Text(l10n.t('supplies.pack.$kind')),
                  selected: _packKind == kind,
                  onSelected: (_) => setState(() => _packKind = kind),
                ),
            ],
          ),
          const SizedBox(height: 16),
          if (_packKind == 'vial') ...[
            Row(
              children: [
                Expanded(
                  child: NumberField(
                    controller: _mlController,
                    label: l10n.t('supplies.ml'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: NumberField(
                    controller: _mgPerMlController,
                    label: l10n.t('supplies.mgPerMl'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
          ],
          if (_packKind == 'pill' ||
              _packKind == 'pump' ||
              _packKind == 'sachet') ...[
            NumberField(
              controller: _mgController,
              label: l10n.t('supplies.packMg'),
              suffix: 'mg',
            ),
            const SizedBox(height: 12),
          ],
          NumberField(
            controller: _countController,
            label: l10n.t('supplies.count'),
            decimal: false,
          ),
        ],
      ),
    );
  }

  List<String> _kindsFor(DoseRoute route) => switch (route) {
    DoseRoute.injection => const ['vial', 'bulk'],
    DoseRoute.patchApply => const ['patch'],
    DoseRoute.gel => const ['pump', 'sachet', 'bulk'],
    DoseRoute.oral || DoseRoute.sublingual => const ['pill', 'bulk'],
    _ => const ['bulk'],
  };
}
