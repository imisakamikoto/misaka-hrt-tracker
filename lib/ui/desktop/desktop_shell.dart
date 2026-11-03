import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../core/domain.dart';
import '../../core/l10n.dart';
import '../../core/platform.dart';
import '../../state/app_state.dart';
import '../dose_page.dart';
import '../forecast_page.dart';
import '../labs_page.dart';
import '../plan_page.dart';
import '../settings_page.dart';
import '../supplies_page.dart';
import '../widgets/common.dart';
import 'desktop_history.dart';
import 'desktop_overview.dart';

/// The windowed shell.
///
/// Material 3 for a pointer and a keyboard rather than a thumb: a permanent
/// navigation drawer on the left, a single toolbar across the top, and content
/// that is allowed to use the whole window instead of one narrow column. The
/// same widgets are used on phones, but nothing here is a stretched phone
/// screen: navigation moves to the side, secondary sections that were pushed
/// routes on Android become destinations, and the dashboard becomes a two
/// column board.
class DesktopShell extends StatefulWidget {
  const DesktopShell({super.key});

  @override
  State<DesktopShell> createState() => _DesktopShellState();
}

class _DesktopShellState extends State<DesktopShell> {
  int _index = 0;
  bool _dropBannerDismissed = false;

  static const _railWidth = 268.0;

  /// Ctrl + 1 … 7, one per destination, in the order of [_sections].
  static const _numberKeys = <LogicalKeyboardKey>[
    LogicalKeyboardKey.digit1,
    LogicalKeyboardKey.digit2,
    LogicalKeyboardKey.digit3,
    LogicalKeyboardKey.digit4,
    LogicalKeyboardKey.digit5,
    LogicalKeyboardKey.digit6,
    LogicalKeyboardKey.digit7,
  ];

  static const _sections = <_Section>[
    _Section(Icons.insights_outlined, Icons.insights, 'nav.home'),
    _Section(Icons.history_outlined, Icons.history, 'nav.history'),
    _Section(Icons.timeline_outlined, Icons.timeline, 'nav.forecast'),
    _Section(Icons.science_outlined, Icons.science, 'nav.labs'),
    _Section(Icons.event_repeat_outlined, Icons.event_repeat, 'nav.plan'),
    _Section(Icons.inventory_2_outlined, Icons.inventory_2, 'nav.supplies'),
    _Section(Icons.settings_outlined, Icons.settings, 'nav.settings'),
  ];

  void _go(int index) {
    if (index == _index) return;
    setState(() {
      _index = index;
      _dropBannerDismissed = false;
    });
  }

  Future<void> _logDose() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => const DosePage(),
        fullscreenDialog: true,
      ),
    );
  }

  Future<void> _recompute() async {
    final state = context.read<AppState>();
    await state.recompute();
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(context.l10n.t('common.done'))));
  }

  Future<void> _showShortcuts() async {
    final l10n = context.l10n;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.keyboard_outlined),
        title: Text(l10n.t('desktop.shortcuts')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _ShortcutRow(keys: 'Ctrl + 1 … 7', label: l10n.t('desktop.scSections')),
            _ShortcutRow(keys: 'Ctrl + N', label: l10n.t('desktop.scDose')),
            _ShortcutRow(keys: 'Ctrl + R', label: l10n.t('desktop.scRefresh')),
            _ShortcutRow(keys: 'F1 / Ctrl + /', label: l10n.t('desktop.scHelp')),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(l10n.t('common.close')),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final scheme = Theme.of(context).colorScheme;

    final pages = <Widget>[
      DesktopOverview(
        onLogDose: _logDose,
        onOpenSection: _go,
        onNewDose: _logDose,
      ),
      const DesktopHistoryPage(),
      const ForecastPage(),
      const LabsPage(),
      const PlanPage(),
      const SuppliesPage(),
      const SettingsPage(),
    ];

    return CallbackShortcuts(
      bindings: {
        for (var i = 0; i < _sections.length && i < _numberKeys.length; i++)
          SingleActivator(_numberKeys[i], control: true): () => _go(i),
        const SingleActivator(LogicalKeyboardKey.keyN, control: true): _logDose,
        const SingleActivator(LogicalKeyboardKey.keyR, control: true):
            _recompute,
        const SingleActivator(LogicalKeyboardKey.f1): _showShortcuts,
        const SingleActivator(LogicalKeyboardKey.slash, control: true):
            _showShortcuts,
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          backgroundColor: scheme.surfaceContainerLowest,
          body: Row(
            children: [
              _NavigationPanel(
                width: _railWidth,
                index: _index,
                onSelect: _go,
                onLogDose: _logDose,
              ),
              VerticalDivider(width: 1, color: scheme.outlineVariant),
              Expanded(
                child: Column(
                  children: [
                    _TopBar(
                      onLogDose: _logDose,
                      onRefresh: _recompute,
                      onHelp: _showShortcuts,
                      onOpenSettings: () => _go(6),
                    ),
                    if (_reminderDrop(state) case final drop?
                        when !_dropBannerDismissed)
                      _DropBanner(
                        drop: drop,
                        onLogDose: _logDose,
                        onDismiss: () =>
                            setState(() => _dropBannerDismissed = true),
                      ),
                    Expanded(
                      child: IndexedStack(index: _index, children: pages),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// The next moment the modelled curve is expected to leave the target band,
  /// honoured in-app because a desktop toast cannot be scheduled by the OS.
  LevelDrop? _reminderDrop(AppState state) {
    if (!Host.isDesktop) return null;
    if (!state.notifyEnabled || !state.notifyDoseDue) return null;
    final sim = state.sim;
    if (sim == null || sim.isEmpty || state.plan.isEmpty) return null;
    final drops = predictedDrops(
      sim: sim,
      plan: state.plan,
      transfem: state.isTransfem,
      lowThreshold: state.isTransfem ? state.lowE2 : state.lowT,
      now: DateTime.now(),
      maxCount: 1,
      horizonDays: 3,
    );
    if (drops.isEmpty) return null;
    final lead = Duration(minutes: state.notifyLeadMinutes);
    return drops.first.at.isBefore(DateTime.now().add(lead))
        ? drops.first
        : null;
  }
}

class _Section {
  const _Section(this.icon, this.selectedIcon, this.label);
  final IconData icon;
  final IconData selectedIcon;
  final String label;
}

// --- navigation -------------------------------------------------------------

class _NavigationPanel extends StatelessWidget {
  const _NavigationPanel({
    required this.width,
    required this.index,
    required this.onSelect,
    required this.onLogDose,
  });

  final double width;
  final int index;
  final ValueChanged<int> onSelect;
  final VoidCallback onLogDose;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    return Container(
      width: width,
      color: scheme.surfaceContainerLow,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 22, 20, 8),
            child: Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: scheme.primaryContainer,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    Icons.water_drop_outlined,
                    size: 22,
                    color: scheme.onPrimaryContainer,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        l10n.t('app.name'),
                        style: text.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        l10n.t('app.tagline'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: FilledButton.icon(
              onPressed: onLogDose,
              icon: const Icon(Icons.add),
              label: Text(l10n.t('home.logDose')),
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
                alignment: Alignment.centerLeft,
                padding: const EdgeInsets.symmetric(horizontal: 20),
              ),
            ),
          ),
          const SizedBox(height: 4),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              children: [
                for (var i = 0; i < _DesktopShellState._sections.length; i++)
                  _NavTile(
                    section: _DesktopShellState._sections[i],
                    label: l10n.t(_DesktopShellState._sections[i].label),
                    selected: i == index,
                    shortcut: 'Ctrl+${i + 1}',
                    onTap: () => onSelect(i),
                  ),
              ],
            ),
          ),
          const Divider(height: 1),
          const _SideFooter(),
        ],
      ),
    );
  }
}

class _NavTile extends StatefulWidget {
  const _NavTile({
    required this.section,
    required this.label,
    required this.selected,
    required this.shortcut,
    required this.onTap,
  });

  final _Section section;
  final String label;
  final bool selected;
  final String shortcut;
  final VoidCallback onTap;

  @override
  State<_NavTile> createState() => _NavTileState();
}

class _NavTileState extends State<_NavTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final selected = widget.selected;
    final foreground = selected ? scheme.onSecondaryContainer : scheme.onSurface;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Tooltip(
        message: '${widget.label}  ·  ${widget.shortcut}',
        waitDuration: const Duration(milliseconds: 600),
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: Semantics(
            selected: selected,
            button: true,
            child: Material(
              color: selected
                  ? scheme.secondaryContainer
                  : _hovered
                  ? scheme.onSurface.withValues(alpha: 0.06)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(999),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: widget.onTap,
                child: SizedBox(
                  height: 52,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Row(
                      children: [
                        Icon(
                          selected ? widget.section.selectedIcon : widget.section.icon,
                          size: 22,
                          color: foreground,
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Text(
                            widget.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: text.labelLarge?.copyWith(
                              color: foreground,
                              fontWeight: selected
                                  ? FontWeight.w700
                                  : FontWeight.w500,
                            ),
                          ),
                        ),
                        if (selected)
                          Icon(
                            Icons.chevron_right,
                            size: 18,
                            color: foreground.withValues(alpha: 0.7),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SideFooter extends StatelessWidget {
  const _SideFooter();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    final (icon, label, colour) = state.coreError != null
        ? (Icons.error_outline, l10n.t('desktop.modelError'), scheme.error)
        : state.computing
        ? (Icons.sync, l10n.t('desktop.modelBusy'), scheme.onSurfaceVariant)
        : (Icons.check_circle_outline, l10n.t('desktop.modelReady'), scheme.primary);

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 16, 14),
      child: Row(
        children: [
          Icon(icon, size: 16, color: colour),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: text.labelSmall?.copyWith(color: colour),
            ),
          ),
        ],
      ),
    );
  }
}

// --- top bar ----------------------------------------------------------------

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.onLogDose,
    required this.onRefresh,
    required this.onHelp,
    required this.onOpenSettings,
  });

  final VoidCallback onLogDose;
  final VoidCallback onRefresh;
  final VoidCallback onHelp;
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final now = DateTime.now();
    final locale = Localizations.localeOf(context).toString();

    return Container(
      height: 68,
      padding: const EdgeInsets.symmetric(horizontal: 24),
      decoration: BoxDecoration(
        color: scheme.surface,
        border: Border(
          bottom: BorderSide(color: scheme.outlineVariant, width: 1),
        ),
      ),
      child: Row(
        children: [
          Icon(Icons.calendar_today_outlined, size: 16, color: scheme.onSurfaceVariant),
          const SizedBox(width: 8),
          Text(
            DateFormat.MMMMEEEEd(locale).format(now),
            style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(width: 10),
          Text(
            DateFormat.Hm(locale).format(now),
            style: text.bodyMedium?.copyWith(
              color: scheme.onSurface,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          const Spacer(),
          SegmentedButton<String>(
            segments: [
              ButtonSegment(
                value: 'transfem',
                label: Text(l10n.t('onboarding.mode.transfem')),
                icon: const Icon(Icons.spa_outlined, size: 18),
              ),
              ButtonSegment(
                value: 'transmasc',
                label: Text(l10n.t('onboarding.mode.transmasc')),
                icon: const Icon(Icons.bolt_outlined, size: 18),
              ),
            ],
            selected: {state.mode},
            showSelectedIcon: false,
            onSelectionChanged: (value) => state.setMode(value.first),
            style: ButtonStyle(
              visualDensity: VisualDensity.compact,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ),
          const SizedBox(width: 12),
          IconButton(
            onPressed: onRefresh,
            icon: const Icon(Icons.refresh),
            tooltip: '${l10n.t('common.retry')}  ·  Ctrl+R',
          ),
          IconButton(
            onPressed: onHelp,
            icon: const Icon(Icons.keyboard_outlined),
            tooltip: '${l10n.t('desktop.shortcuts')}  ·  F1',
          ),
          IconButton(
            onPressed: onOpenSettings,
            icon: const Icon(Icons.settings_outlined),
            tooltip: l10n.t('settings.title'),
          ),
          const SizedBox(width: 8),
          FilledButton.tonalIcon(
            onPressed: onLogDose,
            icon: const Icon(Icons.add),
            label: Text(l10n.t('home.logDose')),
            style: FilledButton.styleFrom(
              minimumSize: const Size(0, 44),
              padding: const EdgeInsets.symmetric(horizontal: 20),
            ),
          ),
        ],
      ),
    );
  }
}

class _ShortcutRow extends StatelessWidget {
  const _ShortcutRow({required this.keys, required this.label});
  final String keys;
  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(keys, style: Theme.of(context).textTheme.labelMedium),
          ),
          const SizedBox(width: 16),
          Expanded(child: Text(label)),
        ],
      ),
    );
  }
}

class _DropBanner extends StatelessWidget {
  const _DropBanner({
    required this.drop,
    required this.onLogDose,
    required this.onDismiss,
  });

  final LevelDrop drop;
  final VoidCallback onLogDose;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final unit = state.isTransfem ? 'pg/mL' : 'ng/dL';
    final low = (state.isTransfem ? state.lowE2 : state.lowT).toStringAsFixed(0);

    return Material(
      color: scheme.tertiaryContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 10, 12, 10),
        child: Row(
          children: [
            Icon(Icons.notifications_active_outlined,
                size: 20, color: scheme.onTertiaryContainer),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                l10n
                    .t('desktop.dropSoon')
                    .replaceAll('{low}', '$low $unit')
                    .replaceAll('{when}', formatDateTime(context, drop.at)),
                style: TextStyle(color: scheme.onTertiaryContainer),
              ),
            ),
            TextButton(
              onPressed: onLogDose,
              child: Text(l10n.t('home.logDose')),
            ),
            IconButton(
              onPressed: onDismiss,
              icon: const Icon(Icons.close),
              iconSize: 18,
              tooltip: l10n.t('common.close'),
            ),
          ],
        ),
      ),
    );
  }
}
