import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../../core/l10n.dart';
import '../../data/models.dart';

class SectionHeader extends StatelessWidget {
  const SectionHeader({
    super.key,
    required this.title,
    this.action,
    this.padding,
  });

  final String title;
  final Widget? action;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: padding ?? const EdgeInsets.fromLTRB(4, 24, 4, 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: text.titleMedium?.copyWith(
                color: scheme.onSurfaceVariant,
                letterSpacing: 0.2,
              ),
            ),
          ),
          if (action != null) action!,
        ],
      ),
    );
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.body,
    this.action,
  });

  final IconData icon;
  final String title;
  final String? body;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              shape: BoxShape.circle,
            ),
            child: Icon(icon, size: 28, color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 16),
          Text(title, style: text.titleMedium, textAlign: TextAlign.center),
          if (body != null) ...[
            const SizedBox(height: 6),
            Text(
              body!,
              style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
              textAlign: TextAlign.center,
            ),
          ],
          if (action != null) ...[const SizedBox(height: 20), action!],
        ],
      ),
    );
  }
}

class KeyValueRow extends StatelessWidget {
  const KeyValueRow({
    super.key,
    required this.label,
    required this.value,
    this.trailing,
  });

  final String label;
  final String value;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Text(
              label,
              style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
          const SizedBox(width: 12),
          Text(
            value,
            style: text.bodyLarge?.copyWith(fontWeight: FontWeight.w600),
          ),
          if (trailing != null) ...[const SizedBox(width: 8), trailing!],
        ],
      ),
    );
  }
}

/// Read-only row that opens a picker or a detail screen, MD3 list style.
class SettingsTile extends StatelessWidget {
  const SettingsTile({
    super.key,
    required this.title,
    this.subtitle,
    this.leading,
    this.trailing,
    this.onTap,
  });

  final String title;
  final String? subtitle;
  final Widget? leading;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: leading,
      title: Text(title),
      subtitle: subtitle == null
          ? null
          : Text(
              subtitle!,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
      trailing:
          trailing ?? (onTap == null ? null : const Icon(Icons.chevron_right)),
      onTap: onTap,
    );
  }
}

class NumberField extends StatelessWidget {
  const NumberField({
    super.key,
    required this.controller,
    required this.label,
    this.suffix,
    this.helper,
    this.decimal = true,
    this.onChanged,
    this.validator,
    this.autofocus = false,
    this.textInputAction,
  });

  final TextEditingController controller;
  final String label;
  final String? suffix;
  final String? helper;
  final bool decimal;
  final ValueChanged<String>? onChanged;
  final String? Function(String?)? validator;
  final bool autofocus;
  final TextInputAction? textInputAction;

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: controller,
      autofocus: autofocus,
      textInputAction: textInputAction,
      keyboardType: TextInputType.numberWithOptions(
        decimal: decimal,
        signed: false,
      ),
      inputFormatters: [
        FilteringTextInputFormatter.allow(
          decimal ? RegExp(r'[0-9.,]') : RegExp(r'[0-9]'),
        ),
      ],
      decoration: InputDecoration(
        labelText: label,
        suffixText: suffix,
        helperText: helper,
      ),
      onChanged: onChanged,
      validator: validator,
    );
  }
}

String formatDateTime(BuildContext context, DateTime t) {
  final locale = Localizations.localeOf(context).toString();
  final now = DateTime.now();
  final sameDay =
      t.year == now.year && t.month == now.month && t.day == now.day;
  if (sameDay) return DateFormat.Hm(locale).format(t);
  return DateFormat.MMMd(locale).add_Hm().format(t);
}

String formatDay(BuildContext context, DateTime t) {
  final locale = Localizations.localeOf(context).toString();
  return DateFormat.yMMMEd(locale).format(t);
}

/// Human-readable description of what a dose was.
String describeDose(
  BuildContext context,
  DoseEvent e, {
  bool hideSite = false,
}) {
  final l10n = context.l10n;
  final parts = <String>['${formatDose(e.doseMG)} mg', e.ester.label];
  if (e.route == DoseRoute.patchApply) {
    final rate = e.patchRateUgPerDay;
    if (rate != null) {
      return '${e.ester.label} · ${rate.toStringAsFixed(0)} µg/day';
    }
  }
  if (e.route == DoseRoute.gel && !hideSite) {
    parts.add(l10n.t('dose.site.${e.gelSite}'));
  }
  return parts.join(' · ');
}

String routeLabel(BuildContext context, DoseRoute route) {
  final l10n = context.l10n;
  return switch (route) {
    DoseRoute.oral =>
      l10n.t('dose.route') +
          ' · ' +
          (l10n.lang.startsWith('zh') ? '口服' : 'Oral'),
    DoseRoute.sublingual => l10n.lang.startsWith('zh') ? '舌下' : 'Sublingual',
    DoseRoute.injection => l10n.lang.startsWith('zh') ? '注射' : 'Injection',
    DoseRoute.gel => l10n.lang.startsWith('zh') ? '凝胶' : 'Gel',
    DoseRoute.patchApply => l10n.lang.startsWith('zh') ? '贴片' : 'Patch',
    DoseRoute.patchRemove =>
      l10n.lang.startsWith('zh') ? '取下贴片' : 'Patch removal',
  };
}

String esterLabel(Ester ester, String lang) {
  if (!lang.startsWith('zh')) return ester.label;
  return switch (ester) {
    Ester.E2 => '雌二醇',
    Ester.EB => '苯甲酸雌二醇',
    Ester.EV => '戊酸雌二醇',
    Ester.EC => '环丙酸雌二醇',
    Ester.EN => '庚酸雌二醇',
    Ester.EU => '十一酸雌二醇',
    Ester.CPA => '醋酸环丙孕酮',
    Ester.SPIRO => '螺内酯',
    Ester.BICA => '比卡鲁胺',
    Ester.MPA => '醋酸甲羟孕酮',
    Ester.LEUP => '亮丙瑞林',
    Ester.TRIP => '曲普瑞林',
    Ester.RLX => '雷洛昔芬',
    Ester.T => '睾酮',
    Ester.TC => '环丙酸睾酮',
    Ester.TE => '庚酸睾酮',
    Ester.TU => '十一酸睾酮',
  };
}

class ConfirmDialog extends StatelessWidget {
  const ConfirmDialog({
    super.key,
    required this.title,
    this.body,
    required this.confirmLabel,
    this.destructive = false,
  });

  final String title;
  final String? body;
  final String confirmLabel;
  final bool destructive;

  static Future<bool> show(
    BuildContext context, {
    required String title,
    String? body,
    required String confirmLabel,
    bool destructive = false,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => ConfirmDialog(
        title: title,
        body: body,
        confirmLabel: confirmLabel,
        destructive: destructive,
      ),
    );
    return result ?? false;
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(title),
      content: body == null ? null : Text(body!),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text(context.l10n.t('common.cancel')),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          style: destructive
              ? FilledButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.error,
                  foregroundColor: Theme.of(context).colorScheme.onError,
                )
              : null,
          child: Text(confirmLabel),
        ),
      ],
    );
  }
}
