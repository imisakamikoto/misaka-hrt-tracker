import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../data/backup.dart';
import '../data/db.dart';
import '../data/models.dart';
import '../core/domain.dart';
import '../core/engine_ffi.dart';
import '../core/boot.dart';
import '../core/l10n.dart';
import '../core/notifications.dart';

/// One store for everything the UI reads. Writes go straight to SQLite, then
/// the model is recomputed in the Rust core off the UI isolate.
class AppState extends ChangeNotifier {
  AppState(this._db, this._engine);

  final AppDatabase _db;
  final HrtEngine _engine;

  bool ready = false;
  bool computing = false;
  String? coreError;

  // --- settings ----------------------------------------------------------
  String mode = 'transfem';
  double weight = 70;
  int? birthYear;
  String theme = 'system';
  bool useDynamicColor = false;
  String lang = 'en';
  bool showPrediction = true;
  bool hideSiteLabel = false;
  int supplyLeadDays = 7;
  bool pixelCats = true;
  String catStyle = 'blue';
  String calibrationMethod = 'off';
  String calibrationHistory = 'retrospective';
  PkParams? pkParams;
  bool onboarded = false;
  DateTime? lastExportAt;

  bool notifyEnabled = false;
  int notifyLeadMinutes = 60;
  double lowE2 = 100;
  double lowT = 400;
  bool notifyDoseDue = false;
  bool bootAutostart = false;

  // --- data --------------------------------------------------------------
  final Map<String, List<DoseEvent>> _doses = {'transfem': [], 'transmasc': []};
  final Map<String, List<LabResult>> _labs = {'transfem': [], 'transmasc': []};
  final Map<String, List<PlanItem>> _plan = {'transfem': [], 'transmasc': []};
  final Map<String, List<Supply>> _supplies = {'transfem': [], 'transmasc': []};
  final Map<String, List<QuickDose>> _quick = {'transfem': [], 'transmasc': []};
  final Map<String, List<DoseTemplate>> _templates = {
    'transfem': [],
    'transmasc': [],
  };

  SimulationResult? sim;
  CalibrationResult? calibration;

  int _computeToken = 0;
  Timer? _clock;
  int _clockTicks = 0;

  /// The concentration is a continuous function of time, so the dashboard is
  /// repainted on a timer instead of only when data changes. Every
  /// [_clockResimTicks] ticks the model is rebuilt as well, which also slides
  /// the simulated window forward and refreshes the reminders.
  static const _clockResimTicks = 40;

  void startClock({Duration interval = const Duration(seconds: 15)}) {
    _clock?.cancel();
    _clockTicks = 0;
    _clock = Timer.periodic(interval, (_) {
      if (!ready || sim == null) return;
      _clockTicks++;
      if (_clockTicks % _clockResimTicks == 0) {
        unawaited(recompute(reminders: false));
      } else {
        notifyListeners();
      }
    });
  }

  @override
  void dispose() {
    _clock?.cancel();
    super.dispose();
  }

  bool get isTransfem => mode == 'transfem';

  List<DoseEvent> get doses => List.unmodifiable(_doses[mode] ?? const []);
  List<LabResult> get labs => List.unmodifiable(_labs[mode] ?? const []);
  List<PlanItem> get plan => List.unmodifiable(_plan[mode] ?? const []);
  List<Supply> get supplies => List.unmodifiable(_supplies[mode] ?? const []);
  List<QuickDose> get quickDoses => List.unmodifiable(_quick[mode] ?? const []);
  List<DoseTemplate> get templates =>
      List.unmodifiable(_templates[mode] ?? const []);

  double get nowH => hoursFromDateTime(DateTime.now());

  PkParams get effectivePkParams => pkParams ?? PkParams();

  /// Usual target band for the active mode, in the model's own unit.
  double get targetLow => isTransfem ? 100 : 400;
  double get targetHigh => isTransfem ? 200 : 700;

  double? get levelNow {
    final s = sim;
    if (s == null || s.isEmpty) return null;
    final raw = isTransfem ? s.e2At(nowH) : s.tAt(nowH);
    return raw * (calibration?.factorAt(nowH) ?? 1);
  }

  double? get cpaNow {
    final s = sim;
    if (s == null || s.isEmpty) return null;
    final v = s.cpaAt(nowH);
    return v < 0.1 ? null : v;
  }

  /// Level at an arbitrary hour, calibrated.
  double levelAt(double hour) {
    final s = sim;
    if (s == null || s.isEmpty) return 0;
    final raw = isTransfem ? s.e2At(hour) : s.tAt(hour);
    return raw * (calibration?.factorAt(hour) ?? 1);
  }

  Future<void> init() async {
    try {
      final settings = await _db.loadSettings();
      _applySettings(settings);
      for (final m in ['transfem', 'transmasc']) {
        _doses[m] = await _db.loadDoses(m);
        _labs[m] = await _db.loadLabs(m);
        _plan[m] = await _db.loadPlan(m);
        _supplies[m] = await _db.loadSupplies(m);
        _quick[m] = await _db.loadQuickDoses(m);
        _templates[m] = await _db.loadTemplates(m);
      }
      if (!_engine.isAvailable) {
        coreError = 'The Rust core did not load.';
      }
      ready = true;
      notifyListeners();
      await recompute();
      startClock();
    } catch (e) {
      coreError = e.toString();
      ready = true;
      notifyListeners();
    }
  }

  void _applySettings(Map<String, dynamic> s) {
    mode = (s['mode'] == 'transmasc') ? 'transmasc' : 'transfem';
    weight = (s['weight'] as num?)?.toDouble() ?? 70;
    birthYear = (s['birthYear'] as num?)?.toInt();
    theme = (s['theme'] ?? 'system').toString();
    useDynamicColor = s['dynamicColor'] == true;
    lang = (s['lang'] ?? 'en').toString();
    showPrediction = s['showPrediction'] != false;
    hideSiteLabel = s['hideSiteLabel'] == true;
    supplyLeadDays = (s['supplyLeadDays'] as num?)?.toInt() ?? 7;
    pixelCats = s['pixelCats'] != false;
    catStyle = (s['catStyle'] ?? 'blue').toString();
    calibrationMethod = (s['calMethod'] ?? 'off').toString();
    calibrationHistory = (s['calHistory'] ?? 'retrospective').toString();
    pkParams = s['pkParams'] is Map
        ? PkParams.fromJson((s['pkParams'] as Map).cast<String, dynamic>())
        : null;
    onboarded = s['onboarded'] == true;
    notifyEnabled = s['notifyEnabled'] == true;
    notifyLeadMinutes = (s['notifyLead'] as num?)?.toInt() ?? 60;
    lowE2 = (s['lowE2'] as num?)?.toDouble() ?? 100;
    lowT = (s['lowT'] as num?)?.toDouble() ?? 400;
    notifyDoseDue = s['notifyDoseDue'] == true;
    bootAutostart = s['bootAutostart'] == true;
    final last = (s['lastExportAt'] as num?)?.toInt();
    lastExportAt = last == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(last);
  }

  Future<void> _set(String key, Object? value) => _db.setSetting(key, value);

  // --- settings writers --------------------------------------------------

  Future<void> setMode(String value) async {
    if (value == mode) return;
    mode = value;
    await _set('mode', value);
    notifyListeners();
    await recompute();
  }

  Future<void> setWeight(double value) async {
    weight = value.clamp(20, 400);
    await _set('weight', weight);
    notifyListeners();
    await recompute();
  }

  Future<void> setBirthYear(int? value) async {
    birthYear = value;
    if (value == null) {
      await _db.removeSetting('birthYear');
    } else {
      await _set('birthYear', value);
    }
    notifyListeners();
    await recompute();
  }

  Future<void> setTheme(String value) async {
    theme = value;
    await _set('theme', value);
    notifyListeners();
  }

  Future<void> setDynamicColor(bool value) async {
    useDynamicColor = value;
    await _set('dynamicColor', value);
    notifyListeners();
  }

  Future<void> setLang(String value) async {
    lang = value;
    await _set('lang', value);
    notifyListeners();
  }

  Future<void> setShowPrediction(bool value) async {
    showPrediction = value;
    await _set('showPrediction', value);
    notifyListeners();
  }

  Future<void> setHideSiteLabel(bool value) async {
    hideSiteLabel = value;
    await _set('hideSiteLabel', value);
    notifyListeners();
  }

  Future<void> setSupplyLeadDays(int value) async {
    supplyLeadDays = value.clamp(0, 90);
    await _set('supplyLeadDays', supplyLeadDays);
    notifyListeners();
  }

  Future<void> setPixelCats(bool value) async {
    pixelCats = value;
    await _set('pixelCats', value);
    notifyListeners();
  }

  Future<void> setCatStyle(String value) async {
    catStyle = value;
    await _set('catStyle', value);
    notifyListeners();
  }

  Future<void> setCalibrationMethod(String value) async {
    calibrationMethod = value;
    await _set('calMethod', value);
    notifyListeners();
    await recompute();
  }

  Future<void> setCalibrationHistory(String value) async {
    calibrationHistory = value;
    await _set('calHistory', value);
    notifyListeners();
    await recompute();
  }

  Future<void> setPkParams(PkParams? value) async {
    pkParams = value;
    if (value == null) {
      await _db.removeSetting('pkParams');
    } else {
      await _set('pkParams', value.toJson());
    }
    notifyListeners();
    await recompute();
  }

  Future<void> completeOnboarding({
    required String mode,
    required double weight,
    int? birthYear,
    required String lang,
  }) async {
    this.mode = mode;
    this.weight = weight;
    this.birthYear = birthYear;
    this.lang = lang;
    onboarded = true;
    await _set('mode', mode);
    await _set('weight', weight);
    await _set('birthYear', birthYear);
    await _set('lang', lang);
    await _set('onboarded', true);
    notifyListeners();
    await recompute();
  }

  Future<void> resetOnboarding() async {
    onboarded = false;
    await _set('onboarded', false);
    notifyListeners();
  }

  Future<void> setNotifyEnabled(bool value) async {
    notifyEnabled = value;
    await _set('notifyEnabled', value);
    notifyListeners();
    if (value) {
      await refreshReminders();
    } else {
      await NotificationService.instance.cancelAll();
    }
  }

  Future<void> setNotifyLead(int minutes) async {
    notifyLeadMinutes = minutes;
    await _set('notifyLead', minutes);
    notifyListeners();
    await refreshReminders();
  }

  Future<void> setLowThresholds({double? e2, double? t}) async {
    if (e2 != null) lowE2 = e2;
    if (t != null) lowT = t;
    await _set('lowE2', lowE2);
    await _set('lowT', lowT);
    notifyListeners();
    await refreshReminders();
  }

  Future<void> setNotifyDoseDue(bool value) async {
    notifyDoseDue = value;
    await _set('notifyDoseDue', value);
    notifyListeners();
    await refreshReminders();
  }

  Future<void> setBootAutostart(bool value) async {
    bootAutostart = value;
    await _set('bootAutostart', value);
    notifyListeners();
    // The boot receiver reads its own copy of the flag; keep them in step.
    await BootHost.setEnabled(value);
  }

  // --- dose CRUD ---------------------------------------------------------

  String newId(String prefix) =>
      '$prefix-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}-${Random().nextInt(1 << 16).toRadixString(36)}';

  Future<void> addDose(DoseEvent event) async {
    final stamped = event.copyWith(
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
    await _db.upsertDose(mode, stamped);
    _doses[mode] = [...(_doses[mode] ?? const []), stamped]
      ..sort((a, b) => a.timeH.compareTo(b.timeH));
    notifyListeners();
    await recompute();
  }

  Future<void> updateDose(DoseEvent event) async {
    await addDose(event);
  }

  Future<void> deleteDose(String id) async {
    await _db.deleteDose(mode, id);
    _doses[mode] = (_doses[mode] ?? const []).where((e) => e.id != id).toList();
    notifyListeners();
    await recompute();
  }

  Future<void> addQuickDose(QuickDose q) async {
    await _db.replaceQuickDoses(mode, [...(_quick[mode] ?? const []), q]);
    _quick[mode] = [...(_quick[mode] ?? const []), q];
    notifyListeners();
  }

  Future<void> removeQuickDose(String id) async {
    final next = (_quick[mode] ?? const []).where((e) => e.id != id).toList();
    await _db.replaceQuickDoses(mode, next);
    _quick[mode] = next;
    notifyListeners();
  }

  Future<void> saveTemplate(DoseTemplate template) async {
    await _db.upsertTemplate(mode, template);
    final list = <DoseTemplate>[...(_templates[mode] ?? const [])];
    final index = list.indexWhere((e) => e.id == template.id);
    if (index >= 0) {
      list[index] = template;
    } else {
      list.add(template);
    }
    _templates[mode] = list;
    notifyListeners();
  }

  Future<void> deleteTemplate(String id) async {
    await _db.deleteTemplate(mode, id);
    _templates[mode] = (_templates[mode] ?? const [])
        .where((e) => e.id != id)
        .toList();
    notifyListeners();
  }

  // --- labs --------------------------------------------------------------

  Future<void> saveLab(LabResult lab) async {
    final stamped = lab.copyWith(
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
    await _db.upsertLab(mode, stamped);
    final list = <LabResult>[...(_labs[mode] ?? const [])];
    final index = list.indexWhere((e) => e.id == stamped.id);
    if (index >= 0) {
      list[index] = stamped;
    } else {
      list.add(stamped);
    }
    list.sort((a, b) => a.timeH.compareTo(b.timeH));
    _labs[mode] = list;
    notifyListeners();
    await recompute();
  }

  Future<void> deleteLab(String id) async {
    await _db.deleteLab(mode, id);
    _labs[mode] = (_labs[mode] ?? const []).where((e) => e.id != id).toList();
    notifyListeners();
    await recompute();
  }

  // --- plan --------------------------------------------------------------

  Future<void> savePlanItem(PlanItem item) async {
    final list = <PlanItem>[...(_plan[mode] ?? const [])];
    final index = list.indexWhere((e) => e.id == item.id);
    if (index >= 0) {
      list[index] = item;
    } else {
      list.add(item);
    }
    await _db.replacePlan(mode, list);
    _plan[mode] = list;
    notifyListeners();
    await recompute();
  }

  Future<void> deletePlanItem(String id) async {
    final list = (_plan[mode] ?? const <PlanItem>[])
        .where((e) => e.id != id)
        .toList();
    await _db.replacePlan(mode, list);
    _plan[mode] = list;
    notifyListeners();
    await recompute();
  }

  // --- supplies ----------------------------------------------------------

  Future<void> saveSupply(Supply supply) async {
    await _db.upsertSupply(mode, supply);
    final list = <Supply>[...(_supplies[mode] ?? const [])];
    final index = list.indexWhere((e) => e.id == supply.id);
    if (index >= 0) {
      list[index] = supply;
    } else {
      list.add(supply);
    }
    _supplies[mode] = list;
    notifyListeners();
  }

  Future<void> deleteSupply(String id) async {
    await _db.deleteSupply(mode, id);
    _supplies[mode] = (_supplies[mode] ?? const [])
        .where((e) => e.id != id)
        .toList();
    notifyListeners();
  }

  List<SupplyStatus> get supplyStatuses {
    final now = DateTime.now();
    return supplies.map((s) => supplyStatus(s, doses, plan, now)).toList()
      ..sort((a, b) {
        final da = a.daysLeft ?? double.infinity;
        final db = b.daysLeft ?? double.infinity;
        return da.compareTo(db);
      });
  }

  // --- computation -------------------------------------------------------

  Future<void> recompute({bool reminders = true}) async {
    final token = ++_computeToken;
    computing = true;
    notifyListeners();
    try {
      final events = doses;
      final results = labs;
      if (events.isEmpty) {
        if (token == _computeToken) {
          sim = null;
          calibration = null;
          computing = false;
          notifyListeners();
        }
        return;
      }

      SimulationResult? base = await _engine.simulate(
        events: events,
        bodyWeightKg: weight,
        birthYear: birthYear,
        params: effectivePkParams,
      );
      CalibrationResult? cal;
      if (calibrationMethod != 'off' && results.isNotEmpty) {
        cal = await _engine.calibrate(
          events: events,
          bodyWeightKg: weight,
          labs: results,
          birthYear: birthYear,
          params: effectivePkParams,
          method: calibrationMethod,
          historyMode: calibrationHistory,
        );
      }
      if (cal != null && cal.clearanceMult != 1) {
        base = await _engine.simulate(
          events: events,
          bodyWeightKg: weight,
          birthYear: birthYear,
          params: effectivePkParams,
          clearanceMult: cal.clearanceMult,
        );
      }
      if (token != _computeToken) return;
      sim = base;
      calibration = cal;
      coreError = null;
    } catch (e) {
      coreError = e.toString();
      sim = null;
    } finally {
      if (token == _computeToken) {
        computing = false;
        notifyListeners();
        if (reminders) unawaited(refreshReminders());
      }
    }
  }

  /// Simulate an arbitrary set of doses, e.g. a what-if scenario.
  Future<SimulationResult?> simulateEvents(
    List<DoseEvent> events, {
    double clearanceMult = 1,
  }) {
    if (events.isEmpty) return Future.value(null);
    return _engine.simulate(
      events: events,
      bodyWeightKg: weight,
      birthYear: birthYear,
      params: effectivePkParams,
      clearanceMult: clearanceMult,
    );
  }

  Future<void> refreshReminders() async {
    if (!notifyEnabled) return;
    try {
      final planItems = plan;
      if (planItems.isEmpty) return;
      final now = DateTime.now();
      final future = futurePlanDoses(
        planItems,
        now,
        now.add(const Duration(days: 14)),
      );
      final past = doses.where((e) => e.timeH > nowH - 60 * 24).toList();
      final events = [...past, ...future]
        ..sort((a, b) => a.timeH.compareTo(b.timeH));
      final projected = await _engine.simulate(
        events: events,
        bodyWeightKg: weight,
        birthYear: birthYear,
        params: effectivePkParams,
        clearanceMult: calibration?.clearanceMult ?? 1,
      );
      if (projected == null) return;

      final scale = calibration?.scale ?? 1;
      final scaled = _ScaledSimulation(projected, scale);
      final drops = predictedDrops(
        sim: scaled,
        plan: planItems,
        transfem: isTransfem,
        lowThreshold: isTransfem ? lowE2 : lowT,
        now: now,
        maxCount: 8,
        horizonDays: 14,
      );

      final l10n = L10n(lang);
      final reminders = <LevelGuardReminder>[];
      for (final drop in drops) {
        final at = drop.at.subtract(Duration(minutes: notifyLeadMinutes));
        final when = at.isBefore(now)
            ? now.add(const Duration(minutes: 2))
            : at;
        reminders.add(
          LevelGuardReminder(
            at: when,
            title: l10n.t('settings.notifyEnable'),
            body: isTransfem
                ? '${l10n.t('home.current')}: ${drop.level.toStringAsFixed(0)} pg/mL — ${l10n.t('home.logDose')}'
                : '${l10n.t('home.current')}: ${drop.level.toStringAsFixed(0)} ng/dL — ${l10n.t('home.logDose')}',
          ),
        );
      }
      await NotificationService.instance.scheduleLevelGuards(reminders);

      if (notifyDoseDue) {
        final due = <LevelGuardReminder>[];
        for (final event in future.take(12)) {
          due.add(
            LevelGuardReminder(
              at: event.time,
              title: l10n.t('home.today'),
              body: '${formatDose(event.doseMG)} mg ${event.ester.label}',
            ),
          );
        }
        await NotificationService.instance.scheduleDoseDue(due);
      }
    } catch (_) {
      // A reminder that cannot be scheduled must never break logging.
    }
  }

  // --- import / export ---------------------------------------------------

  Map<String, ModeData> get bundleModes => {
    for (final m in ['transfem', 'transmasc'])
      m: ModeData(
        doses: _doses[m] ?? const [],
        labs: _labs[m] ?? const [],
        plan: _plan[m] ?? const [],
        supplies: _supplies[m] ?? const [],
        quickDoses: _quick[m] ?? const [],
        templates: _templates[m] ?? const [],
      ),
  };

  String exportComplete() {
    final bundle = BackupCodec.buildCompleteBundle(
      activeMode: mode,
      modes: bundleModes,
      weight: weight,
      pkParams: pkParams,
      calibrationMethod: calibrationMethod,
      calibrationHistory: calibrationHistory,
      theme: theme,
      language: lang,
      showPrediction: showPrediction,
      hideSiteLabel: hideSiteLabel,
      supplyLeadDays: supplyLeadDays,
    );
    return const JsonEncoder.withIndent('  ').convert(bundle);
  }

  String exportRecords() {
    final records = BackupCodec.buildRecordsV2(
      mode: mode,
      active: ModeData(
        doses: doses,
        labs: labs,
        plan: plan,
        supplies: supplies,
        quickDoses: quickDoses,
        templates: templates,
      ),
      modes: bundleModes,
      weight: weight,
      birthYear: birthYear,
      pkParams: pkParams,
    );
    return const JsonEncoder.withIndent('  ').convert(records);
  }

  /// A shareable snapshot: the logged doses and the modelled curve, nothing
  /// else. No lab results, weight, year of birth or free-text notes, so it is
  /// safe to hand to someone else or drop into a chat.
  String exportSnapshot({double stepH = 6}) {
    final s = sim;
    final scale = calibration?.scale ?? 1;
    final now = nowH;
    final start = now - 24 * 7;
    final end = now + 24 * 14;
    final curve = <List<double>>[];
    if (s != null && !s.isEmpty) {
      for (var h = start; h <= end; h += stepH) {
        curve.add([
          double.parse(h.toStringAsFixed(3)),
          double.parse(levelAt(h).toStringAsFixed(3)),
          double.parse((s.cpaAt(h) * scale).toStringAsFixed(3)),
          double.parse((s.tAt(h) * scale).toStringAsFixed(3)),
        ]);
      }
    }

    return const JsonEncoder.withIndent('  ').convert({
      'format': 'oyama-hrt-snapshot',
      'formatVersion': 1,
      'createdAt': DateTime.now().toUtc().toIso8601String(),
      'mode': mode,
      'unit': isTransfem ? 'pg/mL' : 'ng/dL',
      'targetRange': [targetLow, targetHigh],
      'levelNow': levelNow == null
          ? null
          : double.parse(levelNow!.toStringAsFixed(2)),
      'doses': [
        for (final e in doses)
          {
            't': double.parse(e.timeH.toStringAsFixed(3)),
            'route': e.route.code,
            'ester': e.ester.code,
            'mg': e.doseMG,
            if (e.route == DoseRoute.gel &&
                e.extras.containsKey(ExtraKey.gelSite))
              'site': e.gelSite,
            if (e.route.isPatch && e.patchRateUgPerDay != null)
              'rateUgPerDay': e.patchRateUgPerDay,
          },
      ],
      'curveColumns': ['timeH', 'e2', 'cpa', 't'],
      'curveStepH': stepH,
      'curve': curve,
      'note': 'Estimates from a model. Not medical advice.',
    });
  }

  Future<void> markExported() async {
    lastExportAt = DateTime.now();
    await _set('lastExportAt', lastExportAt!.millisecondsSinceEpoch);
    notifyListeners();
  }

  Future<ImportSummary> importText(
    String text, {
    String? password,
    bool replace = false,
  }) async {
    final bundle = await BackupCodec.decode(text, password: password);
    if (bundle.format == BackupFormat.encrypted) {
      throw BackupException('password-required');
    }

    var imported = 0;
    for (final entry in bundle.modeData.entries) {
      final m = entry.key;
      if (!_doses.containsKey(m)) continue;
      final data = entry.value;
      await _db.applyImport(
        mode: m,
        doses: data.doses,
        labs: data.labs,
        plan: data.plan,
        supplies: data.supplies,
        quickDoses: data.quickDoses,
        templates: data.templates,
        replace: replace,
      );
      imported += data.total;
    }

    if (bundle.weight != null) {
      weight = bundle.weight!.clamp(20, 400);
      await _set('weight', weight);
    }
    if (bundle.birthYear != null) {
      birthYear = bundle.birthYear;
      await _set('birthYear', birthYear);
    }
    if (bundle.pkParams != null) {
      pkParams = bundle.pkParams;
      await _set('pkParams', pkParams!.toJson());
    }
    if (bundle.calibrationMethod != null) {
      calibrationMethod = bundle.calibrationMethod!;
      await _set('calMethod', calibrationMethod);
    }
    if (bundle.calibrationHistory != null) {
      calibrationHistory = bundle.calibrationHistory!;
      await _set('calHistory', calibrationHistory);
    }
    if (bundle.theme != null) {
      theme = bundle.theme!;
      await _set('theme', theme);
    }
    if (bundle.language != null) {
      lang = bundle.language!;
      await _set('lang', lang);
    }
    if (bundle.showPrediction != null) {
      showPrediction = bundle.showPrediction!;
      await _set('showPrediction', showPrediction);
    }
    if (bundle.hideSiteLabel != null) {
      hideSiteLabel = bundle.hideSiteLabel!;
      await _set('hideSiteLabel', hideSiteLabel);
    }
    if (bundle.supplyLeadDays != null) {
      supplyLeadDays = bundle.supplyLeadDays!;
      await _set('supplyLeadDays', supplyLeadDays);
    }
    if (bundle.activeMode != null &&
        bundle.modeData.containsKey(bundle.activeMode)) {
      mode = bundle.activeMode!;
      await _set('mode', mode);
    }

    await reload();
    return ImportSummary(
      count: imported,
      format: bundle.format,
      replace: replace,
    );
  }

  Future<void> reload() async {
    for (final m in ['transfem', 'transmasc']) {
      _doses[m] = await _db.loadDoses(m);
      _labs[m] = await _db.loadLabs(m);
      _plan[m] = await _db.loadPlan(m);
      _supplies[m] = await _db.loadSupplies(m);
      _quick[m] = await _db.loadQuickDoses(m);
      _templates[m] = await _db.loadTemplates(m);
    }
    notifyListeners();
    await recompute();
  }

  Future<void> eraseEverything() async {
    await _db.clearAll();
    for (final m in ['transfem', 'transmasc']) {
      _doses[m] = [];
      _labs[m] = [];
      _plan[m] = [];
      _supplies[m] = [];
      _quick[m] = [];
      _templates[m] = [];
    }
    sim = null;
    calibration = null;
    await NotificationService.instance.cancelAll();
    notifyListeners();
  }
}

class ImportSummary {
  ImportSummary({
    required this.count,
    required this.format,
    required this.replace,
  });
  final int count;
  final BackupFormat format;
  final bool replace;
}

/// Applies the calibration amplitude to a simulation without copying it.
class _ScaledSimulation extends SimulationResult {
  _ScaledSimulation(this.inner, this.scale)
    : super(
        timeH: inner.timeH,
        e2PgMl: inner.e2PgMl,
        cpaNgMl: inner.cpaNgMl,
        tNgDl: inner.tNgDl,
        auc: inner.auc,
      );

  final SimulationResult inner;
  final double scale;

  @override
  double e2At(double hour) => inner.e2At(hour) * scale;

  @override
  double tAt(double hour) => inner.tAt(hour) * scale;

  @override
  double cpaAt(double hour) => inner.cpaAt(hour) * scale;
}
