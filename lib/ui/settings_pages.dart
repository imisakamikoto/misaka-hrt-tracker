import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/boot.dart';
import '../core/l10n.dart';
import '../core/notifications.dart';
import '../data/models.dart';
import '../state/app_state.dart';
import 'widgets/common.dart';

class AppearancePage extends StatelessWidget {
  const AppearancePage({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final l10n = context.l10n;
    final options = [
      (value: 'light', key: 'settings.theme.light'),
      (value: 'dark', key: 'settings.theme.dark'),
      (value: 'system', key: 'settings.theme.system'),
      (value: 'mono', key: 'settings.theme.mono'),
    ];
    return Scaffold(
      appBar: AppBar(title: Text(l10n.t('settings.appearance'))),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          Card(
            child: RadioGroup<String>(
              groupValue: state.theme,
              onChanged: (v) {
                if (v != null) state.setTheme(v);
              },
              child: Column(
                children: [
                  for (final option in options)
                    RadioListTile<String>(
                      value: option.value,
                      title: Text(l10n.t(option.key)),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: SwitchListTile(
              secondary: const Icon(Icons.colorize),
              title: Text(l10n.t('settings.dynamicColor')),
              subtitle: Text(
                l10n.t('settings.dynamicColorDesc'),
                style: Theme.of(context).textTheme.bodySmall,
              ),
              value: state.useDynamicColor,
              onChanged: state.theme == 'mono' ? null : state.setDynamicColor,
            ),
          ),
        ],
      ),
    );
  }
}

class ProfilePage extends StatefulWidget {
  const ProfilePage({super.key});

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  late final TextEditingController _weight;
  late final TextEditingController _year;

  @override
  void initState() {
    super.initState();
    final state = context.read<AppState>();
    _weight = TextEditingController(text: state.weight.toStringAsFixed(0));
    _year = TextEditingController(text: state.birthYear?.toString() ?? '');
  }

  @override
  void dispose() {
    _weight.dispose();
    _year.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final state = context.read<AppState>();
    final weight = double.tryParse(_weight.text.replaceAll(',', '.'));
    if (weight != null) await state.setWeight(weight);
    final year = int.tryParse(_year.text);
    await state.setBirthYear(
      (year != null && year >= 1900 && year <= DateTime.now().year)
          ? year
          : null,
    );
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.t('settings.weight')),
        actions: [
          TextButton(onPressed: _save, child: Text(l10n.t('common.save'))),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          NumberField(
            controller: _weight,
            label: l10n.t('settings.weight'),
            suffix: 'kg',
          ),
          const SizedBox(height: 16),
          NumberField(
            controller: _year,
            label: l10n.t('settings.birthYear'),
            decimal: false,
            helper: l10n.t('onboarding.birthYear.desc'),
          ),
        ],
      ),
    );
  }
}

class PkParamsPage extends StatelessWidget {
  const PkParamsPage({super.key});

  static const _groups = <String, List<(String, String)>>{
    'E2': [
      ('e2KClear', 'Elimination (non-injection)'),
      ('e2KClearInj', 'Elimination (injection)'),
      ('e2FfEb', 'Formation · benzoate'),
      ('e2FfEv', 'Formation · valerate'),
      ('e2FfEc', 'Formation · cypionate'),
      ('e2FfEn', 'Formation · enanthate'),
      ('e2FfEu', 'Formation · undecylate'),
    ],
    'Oral / sublingual': [
      ('e2OralBio', 'Oral bioavailability'),
      ('e2SlQuick', 'Sublingual θ · 2 min'),
      ('e2SlCasual', 'Sublingual θ · 5 min'),
      ('e2SlStandard', 'Sublingual θ · 10 min'),
      ('e2SlStrict', 'Sublingual θ · 15 min'),
    ],
    'Gel': [
      ('e2GelArm', 'Arm'),
      ('e2GelThigh', 'Thigh'),
      ('e2GelScrotal', 'Genital'),
    ],
    'T': [
      ('tKClear', 'Elimination (non-injection)'),
      ('tKClearInj', 'Elimination (injection)'),
      ('tFfTc', 'Formation · cypionate'),
      ('tFfTe', 'Formation · enanthate'),
      ('tFfTu', 'Formation · undecanoate'),
      ('tGelArm', 'Gel · arm'),
      ('tGelThigh', 'Gel · thigh'),
      ('tGelScrotal', 'Gel · genital'),
    ],
  };

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final l10n = context.l10n;
    final params = state.effectivePkParams;
    final json = params.toJson();

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.t('settings.pkParams')),
        actions: [
          IconButton(
            tooltip: l10n.lang.startsWith('zh') ? '恢复默认' : 'Reset',
            onPressed: () => state.setPkParams(null),
            icon: const Icon(Icons.restart_alt),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          Text(
            l10n.t('settings.pkParamsDesc'),
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          for (final group in _groups.entries) ...[
            SectionHeader(
              title: group.key,
              padding: const EdgeInsets.only(top: 20, bottom: 8),
            ),
            Card(
              child: Column(
                children: [
                  for (final field in group.value)
                    ListTile(
                      title: Text(field.$2),
                      subtitle: Text(
                        field.$1,
                        style: Theme.of(context).textTheme.labelSmall,
                      ),
                      trailing: Text(
                        (json[field.$1] as double).toStringAsPrecision(4),
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      onTap: () => _edit(
                        context,
                        state,
                        field.$1,
                        field.$2,
                        json[field.$1] as double,
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

  Future<void> _edit(
    BuildContext context,
    AppState state,
    String field,
    String label,
    double value,
  ) async {
    final range = state.effectivePkParams.rangeFor(field);
    final controller = TextEditingController(text: value.toString());
    final result = await showDialog<double>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(label),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: controller,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: InputDecoration(
                labelText: field,
                helperText: '${range.$1} – ${range.$2}',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(context.l10n.t('common.cancel')),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(context, double.tryParse(controller.text)),
            child: Text(context.l10n.t('common.save')),
          ),
        ],
      ),
    );
    if (result == null) return;
    final clamped = result.clamp(range.$1, range.$2);
    await state.setPkParams(state.effectivePkParams.withField(field, clamped));
  }
}

class NotificationsPage extends StatefulWidget {
  const NotificationsPage({super.key});

  @override
  State<NotificationsPage> createState() => _NotificationsPageState();
}

class _NotificationsPageState extends State<NotificationsPage> {
  bool? _granted;

  @override
  void initState() {
    super.initState();
    NotificationService.instance.hasPermission().then((v) {
      if (mounted) setState(() => _granted = v);
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: Text(l10n.t('settings.notifications'))),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          Card(
            child: Column(
              children: [
                SwitchListTile(
                  secondary: const Icon(Icons.notifications_active_outlined),
                  title: Text(l10n.t('settings.notifyEnable')),
                  subtitle: Text(
                    l10n.t('settings.notifyEnableDesc'),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  value: state.notifyEnabled,
                  onChanged: (v) async {
                    if (v) {
                      final ok = await NotificationService.instance
                          .requestPermission();
                      if (!context.mounted) return;
                      setState(() => _granted = ok);
                      if (!ok) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                              l10n.t('settings.notifyPermissionBody'),
                            ),
                          ),
                        );
                        return;
                      }
                    }
                    await state.setNotifyEnabled(v);
                  },
                ),
                if (state.notifyEnabled) ...[
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.timer_outlined),
                    title: Text(l10n.t('settings.notifyLead')),
                    subtitle: Text(
                      '${state.notifyLeadMinutes} ${l10n.t('common.minutes')}',
                    ),
                    trailing: DropdownButton<int>(
                      value: state.notifyLeadMinutes,
                      underline: const SizedBox.shrink(),
                      items: const [
                        DropdownMenuItem(value: 15, child: Text('15')),
                        DropdownMenuItem(value: 30, child: Text('30')),
                        DropdownMenuItem(value: 60, child: Text('60')),
                        DropdownMenuItem(value: 120, child: Text('120')),
                      ],
                      onChanged: (v) {
                        if (v != null) state.setNotifyLead(v);
                      },
                    ),
                  ),
                  const Divider(height: 1),
                  _ThresholdTile(
                    label: l10n.t('settings.lowE2'),
                    value: state.lowE2,
                    min: 40,
                    max: 250,
                    onChanged: (v) => state.setLowThresholds(e2: v),
                  ),
                  _ThresholdTile(
                    label: l10n.t('settings.lowT'),
                    value: state.lowT,
                    min: 200,
                    max: 800,
                    onChanged: (v) => state.setLowThresholds(t: v),
                  ),
                  const Divider(height: 1),
                  SwitchListTile(
                    secondary: const Icon(Icons.schedule),
                    title: Text(l10n.t('settings.notifyDoseDue')),
                    value: state.notifyDoseDue,
                    onChanged: state.setNotifyDoseDue,
                  ),
                  SwitchListTile(
                    secondary: const Icon(Icons.restart_alt),
                    title: Text(l10n.t('settings.bootAutostart')),
                    subtitle: Text(
                      l10n.t('settings.bootAutostartDesc'),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    value: state.bootAutostart,
                    onChanged: (v) async {
                      final messenger = ScaffoldMessenger.of(context);
                      await state.setBootAutostart(v);
                      if (v && mounted) {
                        messenger.showSnackBar(
                          SnackBar(
                            content: Text(l10n.t('settings.openAutostart')),
                            action: SnackBarAction(
                              label: l10n.t('common.ok'),
                              onPressed: () => BootHost.openAutostartSettings(),
                            ),
                          ),
                        );
                      }
                    },
                  ),
                  if (state.bootAutostart)
                    ListTile(
                      leading: const Icon(Icons.settings_suggest_outlined),
                      title: Text(l10n.t('settings.openAutostart')),
                      trailing: const Icon(Icons.open_in_new, size: 18),
                      onTap: () => BootHost.openAutostartSettings(),
                    ),
                  ListTile(
                    leading: const Icon(Icons.alarm_on_outlined),
                    title: Text(l10n.t('settings.exactAlarms')),
                    subtitle: Text(
                      l10n.t('settings.exactAlarmsDesc'),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () async {
                      final ok = await NotificationService.instance
                          .requestExactAlarms();
                      if (ok) await state.refreshReminders();
                    },
                  ),
                ],
              ],
            ),
          ),
          if (_granted == false) ...[
            const SizedBox(height: 12),
            Card(
              color: scheme.tertiaryContainer,
              child: ListTile(
                leading: Icon(
                  Icons.notifications_off_outlined,
                  color: scheme.onTertiaryContainer,
                ),
                title: Text(
                  l10n.t('settings.notifyPermission'),
                  style: TextStyle(color: scheme.onTertiaryContainer),
                ),
                subtitle: Text(
                  l10n.t('settings.notifyPermissionBody'),
                  style: TextStyle(color: scheme.onTertiaryContainer),
                ),
                trailing: FilledButton.tonal(
                  onPressed: () async {
                    final ok = await NotificationService.instance
                        .requestPermission();
                    if (mounted) setState(() => _granted = ok);
                  },
                  child: Text(l10n.t('settings.grantPermission')),
                ),
              ),
            ),
          ],
          const SizedBox(height: 16),
          Text(
            l10n.t('settings.notifyModelNote'),
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

class _ThresholdTile extends StatelessWidget {
  const _ThresholdTile({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(label)),
              Text(
                value.toStringAsFixed(0),
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ],
          ),
          Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            divisions: ((max - min) / 10).round(),
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}

class AboutPage extends StatelessWidget {
  const AboutPage({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.t('settings.credits'))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.spa, color: scheme.primary),
                      const SizedBox(width: 12),
                      Text(
                        l10n.t('app.name'),
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(l10n.t('settings.aboutBody')),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l10n.t('settings.upstreamTitle'),
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  Text(l10n.t('settings.upstreamCredit')),
                  const SizedBox(height: 8),
                  SelectableText(
                    'github.com/xunxunProjects/Oyama-s-HRT-Tracker',
                    style: Theme.of(context).textTheme.bodySmall
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Model', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 8),
                  Text(l10n.t('settings.modelCredit')),
                  const SizedBox(height: 12),
                  Text(
                    'HRT-Recorder-PKcomponent-Test · MIT',
                    style: Theme.of(context).textTheme.bodySmall
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l10n.t('settings.license'),
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    l10n.t('settings.licenseLine') +
                        'Permission is hereby granted, free of charge, to any person obtaining a copy of this software '
                            'and associated documentation files (the "Software"), to deal in the Software without '
                            'restriction, including without limitation the rights to use, copy, modify, merge, publish, '
                            'distribute, sublicense, and/or sell copies of the Software, subject to the condition that '
                            'the above copyright notice and this permission notice are included in all copies.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),
          Center(
            child: Text(
              l10n.t('disclaimer.short'),
              style: Theme.of(context).textTheme.labelSmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    );
  }
}

/// Model parameters are edited one at a time; this keeps the type available to
/// the settings list without exposing the raw map.
typedef PkField = ({String key, String label});

PkParams unusedParams() => PkParams();
