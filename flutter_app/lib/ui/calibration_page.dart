import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../core/l10n.dart';
import '../data/models.dart';
import '../state/app_state.dart';
import 'widgets/common.dart';

class CalibrationPage extends StatelessWidget {
  const CalibrationPage({super.key});

  static const _methods = [
    (value: 'off', titleKey: 'cal.off', descKey: 'cal.offDesc'),
    (value: 'ekf', titleKey: 'cal.ekf', descKey: 'cal.ekfDesc'),
    (value: 'ou_kalman', titleKey: 'cal.ou', descKey: 'cal.ouDesc'),
    (value: 'mipd', titleKey: 'cal.mipd', descKey: 'cal.mipdDesc'),
  ];

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final cal = state.calibration;
    final enough = state.labs.length >= 2;

    return Scaffold(
      appBar: AppBar(title: Text(l10n.t('cal.title'))),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          Text(
            l10n.t('cal.intro'),
            style: Theme.of(context).textTheme.bodyMedium
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
          SectionHeader(
            title: l10n.t('cal.method'),
            padding: const EdgeInsets.only(top: 20, bottom: 8),
          ),
          Card(
            child: RadioGroup<String>(
              groupValue: state.calibrationMethod,
              onChanged: (v) {
                if (v != null) state.setCalibrationMethod(v);
              },
              child: Column(
                children: [
                  for (var i = 0; i < _methods.length; i++) ...[
                    if (i > 0)
                      const Divider(height: 1, indent: 16, endIndent: 16),
                    RadioListTile<String>(
                      value: _methods[i].value,
                      title: Text(l10n.t(_methods[i].titleKey)),
                      subtitle: Text(
                        l10n.t(_methods[i].descKey),
                        style: Theme.of(context).textTheme.bodySmall
                            ?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          if (state.calibrationMethod != 'off') ...[
            SectionHeader(
              title: l10n.t('cal.history'),
              padding: const EdgeInsets.only(top: 24, bottom: 8),
            ),
            SegmentedButton<String>(
              segments: [
                ButtonSegment(
                  value: 'retrospective',
                  label: Text(l10n.t('cal.retrospective')),
                ),
                ButtonSegment(
                  value: 'forward',
                  label: Text(l10n.t('cal.forward')),
                ),
              ],
              selected: {state.calibrationHistory},
              onSelectionChanged: (v) => state.setCalibrationHistory(v.first),
            ),
            const SizedBox(height: 8),
            Text(
              l10n.t(
                state.calibrationHistory == 'forward'
                    ? 'cal.forwardDesc'
                    : 'cal.retrospectiveDesc',
              ),
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
            SectionHeader(
              title: l10n.t('labs.title'),
              padding: const EdgeInsets.only(top: 24, bottom: 8),
            ),
            if (!enough)
              Card(
                child: EmptyState(
                  icon: Icons.science_outlined,
                  title: l10n.t('cal.none'),
                  body: l10n.t('labs.emptyBody'),
                ),
              )
            else if (cal == null || cal.n == 0)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(l10n.t('labs.offCurve')),
                ),
              )
            else ...[
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    children: [
                      KeyValueRow(
                        label: l10n.t('cal.scale'),
                        value: '×${cal.scale.toStringAsFixed(3)}',
                      ),
                      KeyValueRow(
                        label: l10n.t('cal.halfLife'),
                        value:
                            '${cal.halfLifeDeltaPct >= 0 ? '+' : ''}${cal.halfLifeDeltaPct.toStringAsFixed(1)}%',
                      ),
                      if (cal.fitErrPct != null)
                        KeyValueRow(
                          label: l10n.t('cal.fit'),
                          value: '${cal.fitErrPct!.toStringAsFixed(0)}%',
                        ),
                      KeyValueRow(label: l10n.t('cal.n'), value: '${cal.n}'),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Card(
                child: Column(
                  children: [
                    for (var i = 0; i < cal.points.length; i++) ...[
                      if (i > 0)
                        const Divider(height: 1, indent: 16, endIndent: 16),
                      ListTile(
                        title: Text(
                          '${formatDose(cal.points[i].obs)} ${cal.points[i].hormone == 't' ? 'ng/dL' : 'pg/mL'}',
                        ),
                        subtitle: Text(
                          DateFormat.yMMMd(
                            Localizations.localeOf(context).toString(),
                          ).add_Hm().format(cal.points[i].time),
                        ),
                        trailing: Text(
                          '×${cal.points[i].ratio.toStringAsFixed(2)}',
                          style: Theme.of(context).textTheme.titleSmall
                              ?.copyWith(
                                color: cal.points[i].ratio >= 1
                                    ? scheme.primary
                                    : scheme.tertiary,
                              ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ],
        ],
      ),
    );
  }
}
