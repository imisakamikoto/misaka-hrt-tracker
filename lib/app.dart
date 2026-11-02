import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';

import 'core/l10n.dart';
import 'core/notifications.dart';
import 'core/theme.dart';
import 'state/app_state.dart';
import 'ui/onboarding_page.dart';
import 'ui/shell.dart';

class HrtApp extends StatelessWidget {
  const HrtApp({super.key});

  static Locale localeFor(String lang) => switch (lang) {
    'zh-Hans' => const Locale.fromSubtags(
      languageCode: 'zh',
      scriptCode: 'Hans',
    ),
    'zh-Hant' => const Locale.fromSubtags(
      languageCode: 'zh',
      scriptCode: 'Hant',
    ),
    'yue' => const Locale.fromSubtags(
      languageCode: 'zh',
      scriptCode: 'Hant',
      countryCode: 'HK',
    ),
    'ja' => const Locale('ja'),
    'ko' => const Locale('ko'),
    'tr' => const Locale('tr'),
    _ => const Locale('en'),
  };

  /// dynamic_color ships its own copy of the material library, so its scheme is
  /// only read for the wallpaper's primary colour; the theme is then rebuilt
  /// from that seed. Anything unexpected leaves dynamic colour off.
  static Color? seedOf(Object? scheme) {
    if (scheme == null) return null;
    try {
      final dynamic primary = (scheme as dynamic).primary;
      if (primary is Color) return primary;
      final dynamic argb = primary.toARGB32();
      if (argb is int) return Color(argb);
    } catch (_) {
      // Fall through: the clay seed is used instead.
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();

    return DynamicColorBuilder(
      builder: (lightDynamic, darkDynamic) {
        final mono = state.theme == 'mono';
        return MaterialApp(
          title: "Misaka hrt记录器",
          debugShowCheckedModeBanner: false,
          themeMode: mono ? ThemeMode.light : AppTheme.themeMode(state.theme),
          theme: AppTheme.build(
            brightness: Brightness.light,
            mono: mono,
            dynamicSeed: seedOf(lightDynamic),
            useDynamic: state.useDynamicColor && !mono,
          ),
          darkTheme: AppTheme.build(
            brightness: Brightness.dark,
            mono: mono,
            dynamicSeed: seedOf(darkDynamic),
            useDynamic: state.useDynamicColor && !mono,
          ),
          locale: localeFor(state.lang),
          supportedLocales: const [
            Locale('en'),
            Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hans'),
            Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant'),
            Locale('ja'),
            Locale('ko'),
            Locale('tr'),
          ],
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          builder: (context, child) {
            final media = MediaQuery.of(context);
            // Respect the system font scale, but keep the overview readable.
            return MediaQuery(
              data: media.copyWith(
                textScaler: media.textScaler.clamp(
                  minScaleFactor: 0.9,
                  maxScaleFactor: 1.6,
                ),
              ),
              child: L10nProvider(
                lang: state.lang,
                child: child ?? const SizedBox.shrink(),
              ),
            );
          },
          home: const _Root(),
        );
      },
    );
  }
}

class _Root extends StatefulWidget {
  const _Root();

  @override
  State<_Root> createState() => _RootState();
}

class _RootState extends State<_Root> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _askForNotifications());
  }

  Future<void> _askForNotifications() async {
    final state = context.read<AppState>();
    if (!state.notifyEnabled) return;
    final granted = await NotificationService.instance.hasPermission();
    if (!granted && mounted) {
      final ok = await NotificationService.instance.requestPermission();
      if (ok) await state.refreshReminders();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState lifecycle) {
    if (lifecycle == AppLifecycleState.resumed) {
      final state = context.read<AppState>();
      state.refreshReminders();
      state.recompute();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    if (!state.ready) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 320),
      child: state.onboarded ? const AppShell() : const OnboardingPage(),
    );
  }
}
