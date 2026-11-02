import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/l10n.dart';
import '../state/app_state.dart';
import 'widgets/common.dart';

class OnboardingPage extends StatefulWidget {
  const OnboardingPage({super.key});

  @override
  State<OnboardingPage> createState() => _OnboardingPageState();
}

class _OnboardingPageState extends State<OnboardingPage> {
  final _controller = PageController();
  int _step = 0;

  String _lang = 'zh-Hans';
  String _mode = 'transfem';
  double _weight = 70;
  final _weightController = TextEditingController(text: '70');
  final _birthYearController = TextEditingController();

  static const _steps = 5;

  @override
  void initState() {
    super.initState();
    final state = context.read<AppState>();
    _lang = state.lang;
    _mode = state.mode;
    _weight = state.weight;
    _weightController.text = state.weight.toStringAsFixed(0);
    if (state.birthYear != null)
      _birthYearController.text = state.birthYear.toString();
  }

  @override
  void dispose() {
    _controller.dispose();
    _weightController.dispose();
    _birthYearController.dispose();
    super.dispose();
  }

  void _next() {
    if (_step < _steps - 1) {
      _controller.nextPage(
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeOutCubic,
      );
    } else {
      _finish();
    }
  }

  void _back() {
    if (_step > 0) {
      _controller.previousPage(
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOutCubic,
      );
    }
  }

  Future<void> _finish() async {
    final state = context.read<AppState>();
    final year = int.tryParse(_birthYearController.text);
    final weight =
        double.tryParse(_weightController.text.replaceAll(',', '.')) ?? _weight;
    await state.completeOnboarding(
      mode: _mode,
      weight: weight.clamp(20, 400),
      birthYear: (year != null && year >= 1900 && year <= DateTime.now().year)
          ? year
          : null,
      lang: _lang,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = L10n(_lang);
    final scheme = Theme.of(context).colorScheme;
    return L10nProvider(
      lang: _lang,
      child: Scaffold(
        body: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: Row(
                  children: [
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: (_step + 1) / _steps,
                          minHeight: 6,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      '${_step + 1}/$_steps',
                      style: Theme.of(context).textTheme.labelMedium,
                    ),
                  ],
                ),
              ),
              Expanded(
                child: PageView(
                  controller: _controller,
                  physics: const NeverScrollableScrollPhysics(),
                  onPageChanged: (i) => setState(() => _step = i),
                  children: [
                    _LanguageStep(
                      lang: _lang,
                      onChanged: (v) => setState(() => _lang = v),
                    ),
                    _ModeStep(
                      l10n: l10n,
                      mode: _mode,
                      onChanged: (v) => setState(() => _mode = v),
                    ),
                    _WeightStep(
                      l10n: l10n,
                      controller: _weightController,
                      weight: _weight,
                      onChanged: (v) => setState(() => _weight = v),
                    ),
                    _BirthYearStep(
                      l10n: l10n,
                      controller: _birthYearController,
                    ),
                    _DisclaimerStep(l10n: l10n),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
                child: Row(
                  children: [
                    if (_step > 0)
                      TextButton.icon(
                        onPressed: _back,
                        icon: const Icon(Icons.arrow_back),
                        label: Text(l10n.t('common.back')),
                      ),
                    const Spacer(),
                    FilledButton.icon(
                      onPressed: _next,
                      icon: Icon(
                        _step == _steps - 1 ? Icons.check : Icons.arrow_forward,
                      ),
                      label: Text(
                        _step == _steps - 1
                            ? l10n.t('onboarding.start')
                            : l10n.t('common.next'),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        backgroundColor: scheme.surface,
      ),
    );
  }
}

class _StepScaffold extends StatelessWidget {
  const _StepScaffold({required this.title, this.body, required this.child});

  final String title;
  final String? body;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 32, 24, 24),
      children: [
        Text(title, style: text.headlineMedium),
        if (body != null) ...[
          const SizedBox(height: 8),
          Text(
            body!,
            style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
        const SizedBox(height: 24),
        child,
      ],
    );
  }
}

class _LanguageStep extends StatelessWidget {
  const _LanguageStep({required this.lang, required this.onChanged});
  final String lang;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = L10n(lang);
    return _StepScaffold(
      title: l10n.t('onboarding.language'),
      child: Card(
        child: Column(
          children: [
            RadioGroup<String>(
              groupValue: lang,
              onChanged: (v) {
                if (v != null) onChanged(v);
              },
              child: Column(
                children: [
                  for (final entry in L10n.languages.entries)
                    RadioListTile<String>(
                      value: entry.key,
                      title: Text(entry.value),
                      secondary: Text(
                        entry.key,
                        style: Theme.of(context).textTheme.labelSmall,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ModeStep extends StatelessWidget {
  const _ModeStep({
    required this.l10n,
    required this.mode,
    required this.onChanged,
  });
  final L10n l10n;
  final String mode;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget card({
      required String value,
      required IconData icon,
      required String title,
      required String description,
      required Color accent,
    }) {
      final selected = mode == value;
      return Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Card(
          color: selected
              ? scheme.secondaryContainer
              : scheme.surfaceContainerLow,
          child: InkWell(
            borderRadius: BorderRadius.circular(20),
            onTap: () => onChanged(value),
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Row(
                children: [
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: accent.withValues(alpha: 0.18),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(icon, color: accent),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          description,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                  Icon(
                    selected
                        ? Icons.radio_button_checked
                        : Icons.radio_button_off,
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return _StepScaffold(
      title: l10n.t('onboarding.mode.title'),
      body: l10n.t('onboarding.mode.subtitle'),
      child: Column(
        children: [
          card(
            value: 'transfem',
            icon: Icons.spa_outlined,
            title: l10n.t('onboarding.mode.transfem'),
            description: l10n.t('onboarding.mode.transfemDesc'),
            accent: const Color(0xFFD98BA6),
          ),
          card(
            value: 'transmasc',
            icon: Icons.bolt_outlined,
            title: l10n.t('onboarding.mode.transmasc'),
            description: l10n.t('onboarding.mode.transmascDesc'),
            accent: const Color(0xFF6FA8C9),
          ),
        ],
      ),
    );
  }
}

class _WeightStep extends StatelessWidget {
  const _WeightStep({
    required this.l10n,
    required this.controller,
    required this.weight,
    required this.onChanged,
  });

  final L10n l10n;
  final TextEditingController controller;
  final double weight;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return _StepScaffold(
      title: l10n.t('onboarding.weight.title'),
      body: l10n.t('onboarding.weight.desc'),
      child: Column(
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                children: [
                  Text(
                    '${weight.toStringAsFixed(0)} kg',
                    style: Theme.of(context).textTheme.displaySmall,
                  ),
                  Slider(
                    value: weight.clamp(20, 200),
                    min: 20,
                    max: 200,
                    divisions: 180,
                    label: '${weight.toStringAsFixed(0)} kg',
                    onChanged: (v) {
                      onChanged(v);
                      controller.text = v.toStringAsFixed(0);
                    },
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          NumberField(
            controller: controller,
            label: l10n.t('onboarding.weight.title'),
            suffix: 'kg',
            onChanged: (v) {
              final parsed = double.tryParse(v.replaceAll(',', '.'));
              if (parsed != null) onChanged(parsed.clamp(20, 400));
            },
          ),
        ],
      ),
    );
  }
}

class _BirthYearStep extends StatelessWidget {
  const _BirthYearStep({required this.l10n, required this.controller});
  final L10n l10n;
  final TextEditingController controller;

  @override
  Widget build(BuildContext context) {
    return _StepScaffold(
      title: l10n.t('onboarding.birthYear.title'),
      body: l10n.t('onboarding.birthYear.desc'),
      child: NumberField(
        controller: controller,
        label: l10n.t('onboarding.birthYear.title'),
        decimal: false,
        suffix: l10n.lang.startsWith('zh') ? '年' : 'year',
      ),
    );
  }
}

class _DisclaimerStep extends StatelessWidget {
  const _DisclaimerStep({required this.l10n});
  final L10n l10n;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return _StepScaffold(
      title: l10n.t('onboarding.disclaimer.title'),
      child: Card(
        color: scheme.tertiaryContainer,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.warning_amber_rounded,
                color: scheme.onTertiaryContainer,
              ),
              const SizedBox(height: 12),
              Text(
                l10n.t('onboarding.disclaimer.body'),
                style: Theme.of(context).textTheme.bodyMedium
                    ?.copyWith(color: scheme.onTertiaryContainer),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Icon(
                    Icons.lock_outline,
                    size: 18,
                    color: scheme.onTertiaryContainer,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      l10n.t('settings.aboutBody'),
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.onTertiaryContainer.withValues(
                          alpha: 0.85,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
