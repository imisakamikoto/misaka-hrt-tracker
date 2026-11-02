import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/l10n.dart';
import '../state/app_state.dart';
import 'backup_page.dart';
import 'calibration_page.dart';
import 'settings_pages.dart';
import 'widgets/common.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          SliverAppBar.large(title: Text(l10n.t('settings.title'))),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 96),
            sliver: SliverList(
              delegate: SliverChildListDelegate([
                _Section(title: l10n.t('settings.general')),
                Card(
                  child: Column(
                    children: [
                      SettingsTile(
                        leading: const Icon(Icons.transgender),
                        title: l10n.t('settings.mode'),
                        subtitle: state.isTransfem
                            ? l10n.t('onboarding.mode.transfem')
                            : l10n.t('onboarding.mode.transmasc'),
                        onTap: () => _pickMode(context, state),
                      ),
                      SettingsTile(
                        leading: const Icon(Icons.language),
                        title: l10n.t('settings.language'),
                        subtitle: L10n.languages[state.lang],
                        onTap: () => _pickLanguage(context, state),
                      ),
                      SettingsTile(
                        leading: const Icon(Icons.palette_outlined),
                        title: l10n.t('settings.appearance'),
                        subtitle: l10n.t('settings.theme.${state.theme}'),
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => const AppearancePage(),
                          ),
                        ),
                      ),
                      SettingsTile(
                        leading: const Icon(Icons.monitor_weight_outlined),
                        title: l10n.t('settings.weight'),
                        subtitle: '${state.weight.toStringAsFixed(0)} kg',
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => const ProfilePage(),
                          ),
                        ),
                      ),
                      SettingsTile(
                        leading: const Icon(Icons.cake_outlined),
                        title: l10n.t('settings.birthYear'),
                        subtitle:
                            state.birthYear?.toString() ??
                            l10n.t('common.optional'),
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => const ProfilePage(),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                _Section(title: l10n.t('settings.display')),
                Card(
                  child: Column(
                    children: [
                      SwitchListTile(
                        secondary: const Icon(Icons.show_chart),
                        title: Text(l10n.t('settings.prediction')),
                        subtitle: Text(
                          l10n.t('settings.predictionDesc'),
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        value: state.showPrediction,
                        onChanged: state.setShowPrediction,
                      ),
                      SwitchListTile(
                        secondary: const Icon(Icons.visibility_off_outlined),
                        title: Text(l10n.t('settings.hideSiteLabel')),
                        subtitle: Text(
                          l10n.t('settings.hideSiteLabelDesc'),
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        value: state.hideSiteLabel,
                        onChanged: state.setHideSiteLabel,
                      ),
                      SwitchListTile(
                        secondary: const Icon(Icons.pets),
                        title: Text(l10n.t('settings.pixelCats')),
                        subtitle: Text(
                          l10n.t('settings.pixelCatsDesc'),
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        value: state.pixelCats,
                        onChanged: state.setPixelCats,
                      ),
                      if (state.pixelCats)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                          child: Row(
                            children: [
                              Text(
                                l10n.t('settings.catStyle'),
                                style: Theme.of(context).textTheme.bodyMedium,
                              ),
                              const Spacer(),
                              SegmentedButton<String>(
                                segments: [
                                  ButtonSegment(
                                    value: 'blue',
                                    label: Text(
                                      l10n.t('settings.catStyle.blue'),
                                    ),
                                  ),
                                  ButtonSegment(
                                    value: 'pink',
                                    label: Text(
                                      l10n.t('settings.catStyle.pink'),
                                    ),
                                  ),
                                  ButtonSegment(
                                    value: 'flag',
                                    label: Text(
                                      l10n.t('settings.catStyle.flag'),
                                    ),
                                  ),
                                ],
                                selected: {state.catStyle},
                                showSelectedIcon: false,
                                onSelectionChanged: (v) =>
                                    state.setCatStyle(v.first),
                              ),
                            ],
                          ),
                        ),
                      SettingsTile(
                        leading: const Icon(Icons.local_cafe_outlined),
                        title: l10n.t('settings.milkTea'),
                        subtitle: l10n.t('settings.milkTeaDesc'),
                        onTap: () => _milkTea(context, l10n),
                      ),
                    ],
                  ),
                ),
                _Section(title: l10n.t('settings.model')),
                Card(
                  child: Column(
                    children: [
                      SettingsTile(
                        leading: const Icon(Icons.tune),
                        title: l10n.t('settings.pkParams'),
                        subtitle: state.pkParams == null
                            ? (l10n.lang.startsWith('zh') ? '默认参数' : 'Defaults')
                            : (l10n.lang.startsWith('zh')
                                  ? '已自定义'
                                  : 'Customised'),
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => const PkParamsPage(),
                          ),
                        ),
                      ),
                      SettingsTile(
                        leading: const Icon(Icons.insights),
                        title: l10n.t('settings.calibration'),
                        subtitle: state.calibrationMethod == 'off'
                            ? l10n.t('cal.off')
                            : state.calibrationMethod,
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => const CalibrationPage(),
                          ),
                        ),
                      ),
                      SettingsTile(
                        leading: const Icon(Icons.inventory_2_outlined),
                        title: l10n.t('supplies.leadDays'),
                        subtitle:
                            '${state.supplyLeadDays} ${l10n.t('common.days')}',
                        onTap: () => _pickLeadDays(context, state),
                      ),
                    ],
                  ),
                ),
                _Section(title: l10n.t('settings.notifications')),
                Card(
                  child: Column(
                    children: [
                      SettingsTile(
                        leading: const Icon(
                          Icons.notifications_active_outlined,
                        ),
                        title: l10n.t('settings.notifications'),
                        subtitle: state.notifyEnabled
                            ? '${l10n.t('settings.notifyLead')} ${state.notifyLeadMinutes} ${l10n.t('common.minutes')}'
                            : l10n.t('cal.off'),
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => const NotificationsPage(),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                _Section(title: l10n.t('settings.data')),
                Card(
                  child: Column(
                    children: [
                      SettingsTile(
                        leading: const Icon(Icons.upload_file),
                        title: l10n.t('settings.export'),
                        subtitle: state.lastExportAt == null
                            ? l10n.t('common.never')
                            : l10n.t('settings.lastBackup') +
                                  ': ' +
                                  MaterialLocalizations.of(context)
                                      .formatShortDate(state.lastExportAt!),
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => const BackupPage(),
                          ),
                        ),
                      ),
                      SettingsTile(
                        leading: const Icon(Icons.download_outlined),
                        title: l10n.t('settings.import'),
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) =>
                                const BackupPage(startWithImport: true),
                          ),
                        ),
                      ),
                      SettingsTile(
                        leading: Icon(
                          Icons.delete_forever,
                          color: scheme.error,
                        ),
                        title: l10n.t('settings.clearData'),
                        onTap: () async {
                          final ok = await ConfirmDialog.show(
                            context,
                            title: l10n.t('settings.clearData'),
                            body: l10n.t('settings.clearConfirm'),
                            confirmLabel: l10n.t('common.delete'),
                            destructive: true,
                          );
                          if (ok) await state.eraseEverything();
                        },
                      ),
                    ],
                  ),
                ),
                _Section(title: l10n.t('settings.about')),
                Card(
                  child: Column(
                    children: [
                      SettingsTile(
                        leading: const Icon(Icons.favorite_outline),
                        title: l10n.t('settings.credits'),
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => const AboutPage(),
                          ),
                        ),
                      ),
                      SettingsTile(
                        leading: const Icon(Icons.info_outline),
                        title: l10n.t('settings.disclaimer'),
                        onTap: () => showDialog<void>(
                          context: context,
                          builder: (context) => AlertDialog(
                            title: Text(l10n.t('settings.disclaimer')),
                            content: Text(l10n.t('onboarding.disclaimer.body')),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(context),
                                child: Text(l10n.t('common.close')),
                              ),
                            ],
                          ),
                        ),
                      ),
                      SettingsTile(
                        leading: const Icon(Icons.lock_outline),
                        title: l10n.t('settings.privacy'),
                        onTap: () => showDialog<void>(
                          context: context,
                          builder: (context) => AlertDialog(
                            title: Text(l10n.t('settings.privacy')),
                            content: Text(l10n.t('settings.aboutBody')),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(context),
                                child: Text(l10n.t('common.close')),
                              ),
                            ],
                          ),
                        ),
                      ),
                      SettingsTile(
                        leading: const Icon(Icons.restart_alt),
                        title: l10n.t('settings.showIntro'),
                        onTap: state.resetOnboarding,
                      ),
                      ListTile(
                        leading: const Icon(Icons.numbers),
                        title: Text(l10n.t('settings.version')),
                        trailing: Text('1.0.0'),
                      ),
                      ListTile(
                        leading: const Icon(Icons.memory),
                        title: Text(l10n.t('settings.coreVersion')),
                        subtitle: Text(
                          state.coreError ?? 'Rust · libhrt_core.so',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                    ],
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
              ]),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _pickMode(BuildContext context, AppState state) async {
    final l10n = context.l10n;
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.spa_outlined),
              title: Text(l10n.t('onboarding.mode.transfem')),
              subtitle: Text(l10n.t('onboarding.mode.transfemDesc')),
              selected: state.isTransfem,
              trailing: state.isTransfem ? const Icon(Icons.check) : null,
              onTap: () => Navigator.pop(context, 'transfem'),
            ),
            ListTile(
              leading: const Icon(Icons.bolt_outlined),
              title: Text(l10n.t('onboarding.mode.transmasc')),
              subtitle: Text(l10n.t('onboarding.mode.transmascDesc')),
              selected: !state.isTransfem,
              trailing: !state.isTransfem ? const Icon(Icons.check) : null,
              onTap: () => Navigator.pop(context, 'transmasc'),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (choice != null) await state.setMode(choice);
  }

  Future<void> _pickLanguage(BuildContext context, AppState state) async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final entry in L10n.languages.entries)
              ListTile(
                title: Text(entry.value),
                subtitle: Text(entry.key),
                selected: state.lang == entry.key,
                trailing: state.lang == entry.key
                    ? const Icon(Icons.check)
                    : null,
                onTap: () => Navigator.pop(context, entry.key),
              ),
          ],
        ),
      ),
    );
    if (choice != null) await state.setLang(choice);
  }

  Future<void> _pickLeadDays(BuildContext context, AppState state) async {
    final choice = await showModalBottomSheet<int>(
      context: context,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final days in [0, 3, 7, 14, 30])
              ListTile(
                title: Text('$days ${context.l10n.t('common.days')}'),
                selected: state.supplyLeadDays == days,
                trailing: state.supplyLeadDays == days
                    ? const Icon(Icons.check)
                    : null,
                onTap: () => Navigator.pop(context, days),
              ),
          ],
        ),
      ),
    );
    if (choice != null) await state.setSupplyLeadDays(choice);
  }

  Future<void> _milkTea(BuildContext context, L10n l10n) async {
    final zh = l10n.lang.startsWith('zh');
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.local_cafe, size: 36),
        title: Text(zh ? '今天也辛苦了' : 'Take a break'),
        content: Text(
          zh ? '要不要去泡一杯奶茶？三分糖，少冰。\n记录很重要，休息也一样。' : 'Maybe make a milk tea? Half sugar, less ice.\nLogging matters; resting does too.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l10n.t('common.close')),
          ),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title});
  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 24, 4, 8),
      child: Text(
        title,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
          color: Theme.of(context).colorScheme.primary,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
