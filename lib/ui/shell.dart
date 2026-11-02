import 'package:flutter/material.dart';

import '../core/l10n.dart';
import 'dose_page.dart';
import 'forecast_page.dart';
import 'history_page.dart';
import 'home_page.dart';
import 'labs_page.dart';
import 'plan_page.dart';
import 'settings_page.dart';
import 'supplies_page.dart';

class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _index = 0;

  static const _destinations = [
    (icon: Icons.insights_outlined, selected: Icons.insights),
    (icon: Icons.history_outlined, selected: Icons.history),
    (icon: Icons.timeline_outlined, selected: Icons.timeline),
    (icon: Icons.science_outlined, selected: Icons.science),
    (icon: Icons.settings_outlined, selected: Icons.settings),
  ];

  void _go(int index) => setState(() => _index = index);

  Future<void> _logDose() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => const DosePage(),
        fullscreenDialog: true,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final wide = MediaQuery.sizeOf(context).width >= 720;

    final pages = [
      HomePage(
        onOpenPlan: () =>
            Navigator.of(context)
                .push(MaterialPageRoute<void>(builder: (_) => PlanPage())),
        onOpenSupplies: () =>
            Navigator.of(context)
                .push(MaterialPageRoute<void>(builder: (_) => SuppliesPage())),
        onOpenLabs: () => _go(3),
        onLogDose: _logDose,
        onOpenForecast: () => _go(2),
      ),
      const HistoryPage(),
      const ForecastPage(),
      const LabsPage(),
      const SettingsPage(),
    ];

    final labels = [
      l10n.t('nav.home'),
      l10n.t('nav.history'),
      l10n.t('nav.forecast'),
      l10n.t('nav.labs'),
      l10n.t('nav.settings'),
    ];

    final body = SafeArea(
      top: false,
      bottom: false,
      child: IndexedStack(index: _index, children: pages),
    );

    if (wide) {
      return Scaffold(
        body: Row(
          children: [
            NavigationRail(
              selectedIndex: _index,
              onDestinationSelected: _go,
              labelType: NavigationRailLabelType.all,
              leading: Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: FloatingActionButton(
                  onPressed: _logDose,
                  tooltip: l10n.t('home.logDose'),
                  child: const Icon(Icons.add),
                ),
              ),
              destinations: [
                for (var i = 0; i < _destinations.length; i++)
                  NavigationRailDestination(
                    icon: Icon(_destinations[i].icon),
                    selectedIcon: Icon(_destinations[i].selected),
                    label: Text(labels[i]),
                  ),
              ],
            ),
            const VerticalDivider(width: 1),
            Expanded(child: body),
          ],
        ),
      );
    }

    return Scaffold(
      body: body,
      floatingActionButton: _index <= 1
          ? FloatingActionButton.extended(
              onPressed: _logDose,
              icon: const Icon(Icons.add),
              label: Text(l10n.t('home.logDose')),
            )
          : null,
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: _go,
        destinations: [
          for (var i = 0; i < _destinations.length; i++)
            NavigationDestination(
              icon: Icon(_destinations[i].icon),
              selectedIcon: Icon(_destinations[i].selected),
              label: labels[i],
            ),
        ],
      ),
    );
  }
}
