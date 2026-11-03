import '../data/models.dart';

/// Typed views of what the core returns.
///
/// Every one of these is a thin reading of a JSON object the library already
/// shaped; none of them recompute anything. Keeping the arithmetic in Rust is
/// the whole point of the library — if a number is not understood here, it is
/// left out rather than guessed at.

double _num(Object? v, [double fallback = 0]) {
  if (v is num) return v.isFinite ? v.toDouble() : fallback;
  if (v is String) return double.tryParse(v) ?? fallback;
  return fallback;
}

double? _optNum(Object? v) {
  if (v is num) return v.isFinite ? v.toDouble() : null;
  if (v is String) return double.tryParse(v);
  return null;
}

int _int(Object? v, [int fallback = 0]) {
  if (v is num) return v.isFinite ? v.toInt() : fallback;
  if (v is String) return int.tryParse(v) ?? fallback;
  return fallback;
}

String _str(Object? v, [String fallback = '']) => v?.toString() ?? fallback;

/// A milligram field, under either spelling.
///
/// The app writes the unit in capitals everywhere (`doseMG`), and the core now
/// emits that spelling too, but a library built before the fix spelled it
/// `doseMg`. Reading only one of them silently turned every amount into zero,
/// which is worse than either spelling, so both are accepted.
double _mg(Map json, String base) => _num(json['${base}MG'] ?? json['${base}Mg']);

/// A band the level is meant to stay inside, in the model's own unit.
class TargetRange {
  const TargetRange(this.low, this.high);

  final double low;
  final double high;

  static const none = TargetRange(0, 0);

  bool get isValid => low > 0 && high > low && low.isFinite && high.isFinite;

  TargetRange get normalised =>
      low <= high ? this : TargetRange(high, low);

  bool contains(double value) => value >= low && value <= high;

  Map<String, dynamic> toJson() => {'low': low, 'high': high};

  static TargetRange? fromJson(Object? json) {
    if (json is! Map) return null;
    final low = _optNum(json['low']);
    final high = _optNum(json['high']);
    if (low == null || high == null) return null;
    return TargetRange(low, high);
  }

  @override
  String toString() => '${low.toStringAsFixed(0)}–${high.toStringAsFixed(0)}';
}

/// One repeating dose, the input shape of `steadyState`, `planDose` and
/// `supply`.
class Schedule {
  Schedule({
    required this.route,
    required this.ester,
    required this.doseMG,
    required this.intervalH,
    Map<String, double>? extras,
    this.startH = 0,
  }) : extras = extras ?? const {};

  final DoseRoute route;
  final Ester ester;
  final double doseMG;

  /// Days between doses × 24, already resolved by the caller.
  final double intervalH;
  final Map<String, double> extras;
  final double startH;

  /// Builds the schedule a plan line implies. A plan says "every N days, M
  /// times a day", which is an interval of `N / M` days per dose.
  factory Schedule.fromPlanItem(PlanItem item, {double startH = 0}) {
    final perDay = item.dosesPerDay;
    final interval = perDay > 0 ? 24 / perDay : 24.0;
    return Schedule(
      route: item.route,
      ester: item.ester,
      doseMG: item.doseMG,
      intervalH: interval,
      extras: Map.of(item.extras),
      startH: startH,
    );
  }

  Map<String, dynamic> toJson() => {
    'route': route.code,
    'ester': ester.code,
    'doseMG': doseMG,
    'intervalH': intervalH,
    'extras': extras,
    'startH': startH,
  };
}

/// Peak, trough, mean, area and time-in-range for one curve.
class CurveStats {
  const CurveStats({
    required this.n,
    required this.peak,
    required this.peakH,
    required this.trough,
    required this.troughH,
    required this.mean,
    required this.auc,
    required this.timeInRangeH,
    required this.timeInRangePct,
    required this.fluctuationPct,
    required this.spanH,
  });

  final int n;
  final double peak;

  /// When the peak happened, in hours since the epoch.
  final double peakH;
  final double trough;
  final double troughH;

  /// Time-weighted (`auc / span`), so a long flat stretch counts more than a
  /// brief spike — unlike the arithmetic mean of the samples.
  final double mean;

  /// Trapezoidal area, concentration × hour.
  final double auc;
  final double timeInRangeH;
  final double timeInRangePct;

  /// `(peak − trough) / trough` in percent.
  final double fluctuationPct;
  final double spanH;

  bool get isEmpty => n == 0 || peak <= 0;

  static CurveStats? fromJson(Object? json) {
    if (json is! Map) return null;
    final stats = CurveStats(
      n: _int(json['n']),
      peak: _num(json['peak']),
      peakH: _num(json['peakH']),
      trough: _num(json['trough']),
      troughH: _num(json['troughH']),
      mean: _num(json['mean']),
      auc: _num(json['auc']),
      timeInRangeH: _num(json['timeInRangeH']),
      timeInRangePct: _num(json['timeInRangePct']),
      fluctuationPct: _num(json['fluctuationPct']),
      spanH: _num(json['spanH']),
    );
    return stats.isEmpty ? null : stats;
  }
}

/// The four curves side by side over one window.
class SimulationStats {
  const SimulationStats({
    required this.e2,
    required this.t,
    required this.cpa,
    required this.spiro,
    required this.windowStartH,
    required this.windowEndH,
  });

  final CurveStats? e2;
  final CurveStats? t;
  final CurveStats? cpa;

  /// Canrenone, the active metabolite of spironolactone.
  final CurveStats? spiro;
  final double windowStartH;
  final double windowEndH;

  /// The curve the active mode cares about.
  CurveStats? forMode(bool transfem) => transfem ? e2 : t;

  double get spanH =>
      windowEndH > windowStartH ? windowEndH - windowStartH : 0;

  static SimulationStats? fromJson(Object? json) {
    if (json is! Map) return null;
    return SimulationStats(
      e2: CurveStats.fromJson(json['e2']),
      t: CurveStats.fromJson(json['t']),
      cpa: CurveStats.fromJson(json['cpa']),
      spiro: CurveStats.fromJson(json['spiro']),
      windowStartH: _num(json['windowStartH']),
      windowEndH: _num(json['windowEndH']),
    );
  }
}

/// Where a repeated schedule settles.
class SteadyState {
  const SteadyState({
    required this.cycles,
    required this.stable,
    required this.accumulationRatio,
    required this.intervalH,
    required this.cycle,
    this.series,
  });

  /// How many doses were simulated before the last cycle was read.
  final int cycles;

  /// False when the search hit its cycle cap first — the numbers are then the
  /// last cycle, not a plateau.
  final bool stable;

  /// Steady peak over the first cycle's peak.
  final double accumulationRatio;
  final double intervalH;
  final SimulationStats cycle;

  /// The last cycle's samples, when the caller asked for them.
  final SimulationResult? series;

  static SteadyState? fromJson(Object? json) {
    if (json is! Map) return null;
    final cycle = SimulationStats.fromJson(json['cycle']);
    if (cycle == null) return null;
    final rawSeries = json['series'];
    return SteadyState(
      cycles: _int(json['cycles']),
      stable: json['stable'] == true,
      accumulationRatio: _num(json['accumulationRatio']),
      intervalH: _num(json['intervalH']),
      cycle: cycle,
      series: rawSeries is Map
          ? SimulationResult.fromJson(rawSeries.cast<String, dynamic>())
          : null,
    );
  }
}

/// What to aim at when solving for a dose.
enum DoseObjective {
  trough('trough'),
  peak('peak'),
  mean('mean');

  const DoseObjective(this.code);
  final String code;
}

/// The dose that places a chosen statistic inside a target range.
class DoseSolution {
  const DoseSolution({
    required this.doseMG,
    required this.objective,
    required this.achievedPeak,
    required this.achievedTrough,
    required this.achievedMean,
    required this.inRange,
    required this.feasible,
    required this.cycles,
    required this.note,
  });

  final double doseMG;
  final String objective;

  /// From a second simulation at [doseMG], not extrapolated from the probe.
  final double achievedPeak;
  final double achievedTrough;
  final double achievedMean;

  /// Both bounds respected at the suggested dose.
  final bool inRange;

  /// False when no dose satisfies both bounds at this interval.
  final bool feasible;
  final int cycles;
  final String note;

  static DoseSolution? fromJson(Object? json) {
    if (json is! Map) return null;
    return DoseSolution(
      doseMG: _num(json['doseMG']),
      objective: _str(json['objective'], 'trough'),
      achievedPeak: _num(json['achievedPeak']),
      achievedTrough: _num(json['achievedTrough']),
      achievedMean: _num(json['achievedMean']),
      inRange: json['inRange'] == true,
      feasible: json['feasible'] == true,
      cycles: _int(json['cycles']),
      note: _str(json['note']),
    );
  }
}

/// A moment at which the level falls through a lower bound.
class LevelReminder {
  const LevelReminder({
    required this.atH,
    required this.crossingH,
    required this.level,
    required this.hoursUntil,
    required this.leadH,
  });

  /// When the notification should fire.
  final double atH;

  /// When the level actually crosses the bound.
  final double crossingH;
  final double level;
  final double hoursUntil;
  final double leadH;

  DateTime get at => dateTimeFromHours(atH);
  DateTime get crossing => dateTimeFromHours(crossingH);

  static LevelReminder? fromJson(Object? json) {
    if (json is! Map) return null;
    return LevelReminder(
      atH: _num(json['atH']),
      crossingH: _num(json['crossingH']),
      level: _num(json['level']),
      hoursUntil: _num(json['hoursUntil']),
      leadH: _num(json['leadH']),
    );
  }
}

class ReminderReport {
  const ReminderReport({
    required this.reminders,
    required this.hoursBelow,
    required this.horizonH,
    required this.low,
  });

  final List<LevelReminder> reminders;

  /// Time the curve spends under [low] across the horizon if nothing is taken.
  final double hoursBelow;
  final double horizonH;
  final double low;

  static ReminderReport? fromJson(Object? json) {
    if (json is! Map) return null;
    final raw = json['reminders'];
    return ReminderReport(
      reminders: [
        if (raw is List)
          for (final entry in raw)
            if (LevelReminder.fromJson(entry) case final r?) r,
      ],
      hoursBelow: _num(json['hoursBelow']),
      horizonH: _num(json['horizonH']),
      low: _num(json['low']),
    );
  }
}

/// How a log compares with a fixed interval.
class AdherenceReport {
  const AdherenceReport({
    required this.expected,
    required this.taken,
    required this.coveragePct,
    required this.onTimePct,
    required this.extraDoses,
    required this.longestGapH,
    required this.longestGapStartH,
    required this.gaps,
  });

  final int expected;
  final int taken;
  final double coveragePct;
  final double onTimePct;
  final int extraDoses;
  final double longestGapH;
  final double? longestGapStartH;

  /// Every stretch longer than 1.5 intervals, as `(startH, hours)`.
  final List<(double, double)> gaps;

  static AdherenceReport? fromJson(Object? json) {
    if (json is! Map) return null;
    final rawGaps = json['gaps'];
    return AdherenceReport(
      expected: _int(json['expected']),
      taken: _int(json['taken']),
      coveragePct: _num(json['coveragePct']),
      onTimePct: _num(json['onTimePct']),
      extraDoses: _int(json['extraDoses']),
      longestGapH: _num(json['longestGapH']),
      longestGapStartH: _optNum(json['longestGapStartH']),
      gaps: [
        if (rawGaps is List)
          for (final gap in rawGaps)
            if (gap is List && gap.length >= 2)
              (_num(gap[0]), _num(gap[1])),
      ],
    );
  }
}

/// Runway at the planned rate.
class SupplyRunway {
  const SupplyRunway({
    required this.onHandMG,
    required this.dailyMG,
    required this.weeklyMG,
    required this.dosesRemaining,
    required this.daysRemaining,
    required this.runOutH,
  });

  final double onHandMG;
  final double dailyMG;
  final double weeklyMG;
  final int dosesRemaining;
  final double daysRemaining;
  final double runOutH;

  DateTime get runOut => dateTimeFromHours(runOutH);

  static SupplyRunway? fromJson(Object? json) {
    if (json is! Map) return null;
    return SupplyRunway(
      onHandMG: _mg(json, 'onHand'),
      dailyMG: _mg(json, 'daily'),
      weeklyMG: _mg(json, 'weekly'),
      dosesRemaining: _int(json['dosesRemaining']),
      daysRemaining: _num(json['daysRemaining']),
      runOutH: _num(json['runOutH']),
    );
  }
}

/// A concentration converted between units.
class ConcentrationConversion {
  const ConcentrationConversion({
    required this.value,
    required this.from,
    required this.to,
    required this.analyte,
  });

  final double value;
  final String from;
  final String to;

  /// `e2` or `t` — it selects the molecular weight.
  final String analyte;

  static ConcentrationConversion? fromJson(Object? json) {
    if (json is! Map) return null;
    return ConcentrationConversion(
      value: _num(json['value']),
      from: _str(json['from']),
      to: _str(json['to']),
      analyte: _str(json['analyte'], 'e2'),
    );
  }
}

/// A dose translated from one ester to another.
class DoseConversion {
  const DoseConversion({
    required this.doseMG,
    required this.activeMG,
    required this.equivalentMG,
    required this.fromEster,
    required this.toEster,
  });

  final double doseMG;
  final double activeMG;
  final double equivalentMG;
  final String fromEster;
  final String toEster;

  static DoseConversion? fromJson(Object? json) {
    if (json is! Map) return null;
    return DoseConversion(
      doseMG: _num(json['doseMG']),
      activeMG: _num(json['activeMG']),
      equivalentMG: _num(json['equivalentMG']),
      fromEster: _str(json['fromEster']),
      toEster: _str(json['toEster']),
    );
  }
}

/// One ester as the engine knows it.
class EsterInfo {
  const EsterInfo({
    required this.code,
    required this.name,
    required this.molecularWeight,
    required this.activeFactor,
    required this.hormone,
    required this.modelled,
    required this.routes,
    required this.halfLifeHours,
    required this.note,
  });

  final String code;
  final String name;
  final double molecularWeight;

  /// Milligrams of active hormone per milligram of ester.
  final double activeFactor;

  /// `e2`, `t`, `cpa`, or null when the compound is not modelled.
  final String? hormone;
  final bool modelled;

  /// Routes that actually produce a curve for this ester.
  final List<String> routes;

  /// Descriptive only — the engine computes from rate constants.
  final double? halfLifeHours;
  final String? note;

  static EsterInfo? fromJson(Object? json) {
    if (json is! Map) return null;
    final rawRoutes = json['routes'];
    return EsterInfo(
      code: _str(json['code']),
      name: _str(json['name']),
      molecularWeight: _num(json['molecularWeight']),
      activeFactor: _num(json['activeFactor']),
      hormone: json['hormone'] as String?,
      modelled: json['modelled'] == true,
      routes: [
        if (rawRoutes is List) for (final r in rawRoutes) r.toString(),
      ],
      halfLifeHours: _optNum(json['halfLifeHours']),
      note: json['note'] as String?,
    );
  }
}

/// One route as the engine knows it.
class RouteInfo {
  const RouteInfo({
    required this.code,
    required this.name,
    required this.description,
    required this.extras,
    required this.isDose,
  });

  final String code;
  final String name;
  final String description;

  /// Keys that may appear in `extras` for this route.
  final List<String> extras;

  /// A patch removal is an event, not a dose.
  final bool isDose;

  static RouteInfo? fromJson(Object? json) {
    if (json is! Map) return null;
    final raw = json['extras'];
    return RouteInfo(
      code: _str(json['code']),
      name: _str(json['name']),
      description: _str(json['description']),
      extras: [if (raw is List) for (final e in raw) e.toString()],
      isDose: json['isDose'] != false,
    );
  }
}

class UnitInfo {
  const UnitInfo({
    required this.code,
    required this.analyte,
    required this.kind,
  });

  final String code;
  final String analyte;
  final String kind;

  /// Mass per volume (`pg/ml`) or amount per volume (`pmol/l`).
  bool get isMolar => kind == 'molar';

  static UnitInfo? fromJson(Object? json) {
    if (json is! Map) return null;
    return UnitInfo(
      code: _str(json['code']),
      analyte: _str(json['analyte']),
      kind: _str(json['kind']),
    );
  }
}

/// Everything the engine accepts, as data.
class EngineCatalog {
  const EngineCatalog({
    required this.version,
    required this.abi,
    required this.esters,
    required this.routes,
    required this.units,
    required this.e2Target,
    required this.tTarget,
    required this.targetNote,
    required this.disclaimer,
  });

  final String version;
  final int abi;
  final List<EsterInfo> esters;
  final List<RouteInfo> routes;
  final List<UnitInfo> units;
  final TargetRange e2Target;
  final TargetRange tTarget;
  final String targetNote;
  final String disclaimer;

  EsterInfo? ester(String code) {
    for (final e in esters) {
      if (e.code.toLowerCase() == code.toLowerCase()) return e;
    }
    return null;
  }

  static EngineCatalog? fromJson(Object? json) {
    if (json is! Map) return null;
    final defaults = json['targetDefaults'];
    final targetMap = defaults is Map ? defaults : const {};
    final e2 = TargetRange.fromJson(targetMap['e2PgMl']);
    final t = TargetRange.fromJson(targetMap['tNgDl']);
    return EngineCatalog(
      version: _str(json['version']),
      abi: _int(json['abi']),
      esters: [
        if (json['esters'] is List)
          for (final e in json['esters'] as List)
            if (EsterInfo.fromJson(e) case final info?) info,
      ],
      routes: [
        if (json['routes'] is List)
          for (final r in json['routes'] as List)
            if (RouteInfo.fromJson(r) case final info?) info,
      ],
      units: [
        if (json['units'] is List)
          for (final u in json['units'] as List)
            if (UnitInfo.fromJson(u) case final info?) info,
      ],
      e2Target: e2 ?? const TargetRange(100, 200),
      tTarget: t ?? const TargetRange(400, 700),
      targetNote: _str(targetMap['note']),
      disclaimer: _str(json['disclaimer']),
    );
  }
}

/// Hold time and mucosal fraction, in whichever direction was asked for.
class SublingualInfo {
  const SublingualInfo({
    required this.holdMin,
    required this.theta,
    required this.nearestTierName,
    required this.nearestTierHoldMin,
    required this.effectiveBioavailability,
  });

  final double holdMin;

  /// Share absorbed through the oral mucosa, 0–1.
  final double theta;
  final String? nearestTierName;
  final double? nearestTierHoldMin;

  /// `θ + (1 − θ) × oral bioavailability`.
  final double effectiveBioavailability;

  static SublingualInfo? fromJson(Object? json) {
    if (json is! Map) return null;
    final tier = json['nearestTier'];
    return SublingualInfo(
      holdMin: _num(json['holdMin'], 10),
      theta: _num(json['theta']),
      nearestTierName: tier is Map ? tier['name'] as String? : null,
      nearestTierHoldMin: tier is Map ? _optNum(tier['holdMin']) : null,
      effectiveBioavailability: _num(json['effectiveBioavailability']),
    );
  }
}

/// One patch application and the removal that ended it.
class PatchPair {
  const PatchPair({
    required this.index,
    required this.id,
    required this.applyH,
    required this.removeH,
    required this.wearH,
    required this.plannedWearH,
    required this.overWearH,
  });

  final int index;
  final String id;
  final double applyH;

  /// Null when the patch was never removed.
  final double? removeH;
  final double? wearH;
  final double? plannedWearH;

  /// Hours worn beyond the planned wear, never negative.
  final double? overWearH;

  bool get isOpen => removeH == null;

  static PatchPair? fromJson(Object? json) {
    if (json is! Map) return null;
    return PatchPair(
      index: _int(json['index']),
      id: _str(json['id']),
      applyH: _num(json['applyH']),
      removeH: _optNum(json['removeH']),
      wearH: _optNum(json['wearH']),
      plannedWearH: _optNum(json['plannedWearH']),
      overWearH: _optNum(json['overWearH']),
    );
  }
}

/// Something wrong with the record or the plan.
class SafetyWarning {
  const SafetyWarning({
    required this.code,
    required this.severity,
    required this.message,
    required this.atH,
    required this.value,
  });

  /// Stable machine-readable identifier, e.g. `routeNotModelled`.
  final String code;

  /// `info`, `warning` or `critical`.
  final String severity;
  final String message;
  final double? atH;
  final double? value;

  bool get isCritical => severity == 'critical';
  bool get isWarning => severity == 'warning';
  bool get isInfo => severity == 'info';

  static SafetyWarning? fromJson(Object? json) {
    if (json is! Map) return null;
    return SafetyWarning(
      code: _str(json['code']),
      severity: _str(json['severity'], 'info'),
      message: _str(json['message']),
      atH: _optNum(json['atH']),
      value: _optNum(json['value']),
    );
  }
}

/// How much the curve moves when one estimate is wrong.
class SensitivityPoint {
  const SensitivityPoint({
    required this.parameter,
    required this.deltaPct,
    required this.peakChangePct,
    required this.troughChangePct,
    required this.aucChangePct,
  });

  /// `clearance`, `weight` or `dose`.
  final String parameter;

  /// The perturbation applied, signed.
  final double deltaPct;
  final double peakChangePct;
  final double troughChangePct;
  final double aucChangePct;

  static SensitivityPoint? fromJson(Object? json) {
    if (json is! Map) return null;
    return SensitivityPoint(
      parameter: _str(json['parameter']),
      deltaPct: _num(json['deltaPct']),
      peakChangePct: _num(json['peakChangePct']),
      troughChangePct: _num(json['troughChangePct']),
      aucChangePct: _num(json['aucChangePct']),
    );
  }
}

/// One exported entry of the library, as `hrt_capabilities` describes it.
class EngineFunction {
  const EngineFunction({
    required this.name,
    required this.summary,
    required this.input,
  });

  final String name;
  final String summary;
  final List<String> input;

  static EngineFunction? fromJson(Object? json) {
    if (json is! Map) return null;
    final raw = json['input'];
    return EngineFunction(
      name: _str(json['name']),
      summary: _str(json['summary']),
      input: [if (raw is List) for (final i in raw) i.toString()],
    );
  }
}

class EngineCapabilities {
  const EngineCapabilities({
    required this.abi,
    required this.version,
    required this.functions,
  });

  final int abi;
  final String version;
  final List<EngineFunction> functions;

  static EngineCapabilities? fromJson(Object? json) {
    if (json is! Map) return null;
    return EngineCapabilities(
      abi: _int(json['abi']),
      version: _str(json['version']),
      functions: [
        if (json['functions'] is List)
          for (final f in json['functions'] as List)
            if (EngineFunction.fromJson(f) case final fn?) fn,
      ],
    );
  }
}

/// One anti-androgen in the record, assessed.
///
/// The verdict is about the record, not about the patient: whether the dose is
/// in a range that is commonly prescribed, whether the log shows it being
/// taken, and what the modelled level is. [expectsTestosteroneFall] is the
/// part that stops a reader from inferring suppression from the presence of a
/// drug that does not suppress.
class BlockadeCompound {
  const BlockadeCompound({
    required this.ester,
    required this.name,
    required this.modelled,
    required this.doseMG,
    required this.intervalH,
    required this.dailyMG,
    required this.band,
    required this.bandLowMG,
    required this.bandHighMG,
    required this.bandCeilingMG,
    required this.level,
    required this.coveragePct,
    required this.expected,
    required this.taken,
    required this.nextDueH,
    required this.overdueH,
    required this.verdict,
    required this.mechanism,
    required this.expectsTestosteroneFall,
    required this.mechanismNote,
    required this.notes,
  });

  /// Ester code, e.g. `SPIRO`.
  final String ester;
  final String name;
  final bool modelled;
  final double doseMG;

  /// Median spacing between doses, in hours.
  final double intervalH;
  final double dailyMG;

  /// `low`, `typical`, `high` or `aboveCeiling`.
  final String band;
  final double bandLowMG;
  final double bandHighMG;
  final double bandCeilingMG;

  /// Peak/trough/mean of the modelled curve, when there is one.
  final CurveStats? level;
  final double coveragePct;
  final int expected;
  final int taken;

  /// Last dose plus one interval.
  final double? nextDueH;

  /// Positive when the next dose is already late.
  final double overdueH;

  /// `adequate`, `lowDose`, `highDose`, `aboveCeiling`, `coverage`,
  /// `nothingLogged`.
  final String verdict;

  /// `receptorBlockade`, `synthesisAndReceptor` or `gonadotropinSuppression`.
  final String mechanism;

  /// Whether this compound alone is expected to lower testosterone.
  final bool expectsTestosteroneFall;
  final String mechanismNote;
  final List<String> notes;

  DateTime? get nextDue =>
      nextDueH == null ? null : dateTimeFromHours(nextDueH!);

  bool get isOverdue => overdueH > 1;

  /// Where the daily dose sits in its band, 0–1+, for a bar.
  double get bandPosition => bandCeilingMG <= 0
      ? 0
      : (dailyMG / bandCeilingMG).clamp(0.0, 1.2);

  static BlockadeCompound? fromJson(Object? json) {
    if (json is! Map) return null;
    final rawNotes = json['notes'];
    return BlockadeCompound(
      ester: _str(json['ester']),
      name: _str(json['name']),
      modelled: json['modelled'] == true,
      doseMG: _mg(json, 'dose'),
      intervalH: _num(json['intervalH']),
      dailyMG: _mg(json, 'daily'),
      band: _str(json['band'], 'typical'),
      bandLowMG: _mg(json, 'bandLow'),
      bandHighMG: _mg(json, 'bandHigh'),
      bandCeilingMG: _mg(json, 'bandCeiling'),
      level: CurveStats.fromJson(json['level']),
      coveragePct: _num(json['coveragePct']),
      expected: _int(json['expected']),
      taken: _int(json['taken']),
      nextDueH: _optNum(json['nextDueH']),
      overdueH: _num(json['overdueH']),
      verdict: _str(json['verdict'], 'unknown'),
      mechanism: _str(json['mechanism'], 'unknown'),
      expectsTestosteroneFall: json['expectsTestosteroneFall'] == true,
      mechanismNote: _str(json['mechanismNote']),
      notes: [if (rawNotes is List) for (final n in rawNotes) n.toString()],
    );
  }
}

/// Every anti-androgen in the record, plus the sentence about what the model
/// refuses to claim.
class BlockadeReport {
  const BlockadeReport({
    required this.compounds,
    required this.windowDays,
    required this.windowStartH,
    required this.windowEndH,
    required this.note,
  });

  final List<BlockadeCompound> compounds;
  final double windowDays;
  final double windowStartH;
  final double windowEndH;
  final String note;

  bool get isEmpty => compounds.isEmpty;

  /// The compound with the most overdue dose, if any.
  BlockadeCompound? get mostOverdue {
    BlockadeCompound? worst;
    for (final c in compounds) {
      if (worst == null || c.overdueH > worst.overdueH) worst = c;
    }
    return (worst != null && worst.overdueH > 1) ? worst : null;
  }

  static BlockadeReport? fromJson(Object? json) {
    if (json is! Map) return null;
    final raw = json['compounds'];
    return BlockadeReport(
      compounds: [
        if (raw is List)
          for (final entry in raw)
            if (BlockadeCompound.fromJson(entry) case final c?) c,
      ],
      windowDays: _num(json['windowDays']),
      windowStartH: _num(json['windowStartH']),
      windowEndH: _num(json['windowEndH']),
      note: _str(json['note']),
    );
  }
}

/// One look-back window: a day, a month or a year.
///
/// Both headline numbers are lower bounds on purpose. [tSuppressionPct] is the
/// 95% Wilson lower bound of the share of testosterone results under the
/// ceiling, and [effectivenessPct] is the weaker of modelled time in range and
/// logged coverage.
class WindowProgress {
  const WindowProgress({
    required this.label,
    required this.hours,
    required this.startH,
    required this.endH,
    required this.labsN,
    required this.tLabsN,
    required this.e2LabsN,
    required this.tMeanNgDl,
    required this.e2MeanPgMl,
    required this.tBelowCeiling,
    required this.tCeilingNgDl,
    required this.tSuppressionPct,
    required this.timeInRangePct,
    required this.coveragePct,
    required this.effectivenessPct,
  });

  /// `day`, `month` or `year`.
  final String label;
  final double hours;
  final double startH;
  final double endH;
  final int labsN;
  final int tLabsN;
  final int e2LabsN;
  final double? tMeanNgDl;
  final double? e2MeanPgMl;
  final int tBelowCeiling;
  final double tCeilingNgDl;
  final double? tSuppressionPct;
  final double? timeInRangePct;
  final double? coveragePct;
  final double? effectivenessPct;

  DateTime get start => dateTimeFromHours(startH);
  DateTime get end => dateTimeFromHours(endH);

  static WindowProgress? fromJson(Object? json) {
    if (json is! Map) return null;
    return WindowProgress(
      label: _str(json['label']),
      hours: _num(json['hours']),
      startH: _num(json['startH']),
      endH: _num(json['endH']),
      labsN: _int(json['labsN']),
      tLabsN: _int(json['tLabsN']),
      e2LabsN: _int(json['e2LabsN']),
      tMeanNgDl: _optNum(json['tMeanNgDl']),
      e2MeanPgMl: _optNum(json['e2MeanPgMl']),
      tBelowCeiling: _int(json['tBelowCeiling']),
      tCeilingNgDl: _num(json['tCeilingNgDl'], 50),
      tSuppressionPct: _optNum(json['tSuppressionPct']),
      timeInRangePct: _optNum(json['timeInRangePct']),
      coveragePct: _optNum(json['coveragePct']),
      effectivenessPct: _optNum(json['effectivenessPct']),
    );
  }
}

class ProgressReport {
  const ProgressReport({
    required this.windows,
    required this.tCeilingNgDl,
    required this.note,
  });

  final List<WindowProgress> windows;
  final double tCeilingNgDl;
  final String note;

  WindowProgress? window(String label) {
    for (final w in windows) {
      if (w.label == label) return w;
    }
    return null;
  }

  static ProgressReport? fromJson(Object? json) {
    if (json is! Map) return null;
    final raw = json['windows'];
    return ProgressReport(
      windows: [
        if (raw is List)
          for (final entry in raw)
            if (WindowProgress.fromJson(entry) case final w?) w,
      ],
      tCeilingNgDl: _num(json['tCeilingNgDl'], 50),
      note: _str(json['note']),
    );
  }
}

/// One size in one national convention.
///
/// The band and the cup letter are both conventions; the difference in
/// centimetres is the measurement underneath them.
class CupSize {
  const CupSize({
    required this.system,
    required this.band,
    required this.bandUnit,
    required this.cup,
    required this.label,
    required this.differenceCm,
    required this.differenceIn,
  });

  /// `eu`, `cn`, `uk` or `us`.
  final String system;
  final double band;

  /// `cm` or `in`.
  final String bandUnit;

  /// `AA`, `A` … `G`, or `H+` past the table.
  final String cup;

  /// `75C`, `34A`.
  final String label;
  final double differenceCm;
  final double differenceIn;

  static CupSize? fromJson(Object? json) {
    if (json is! Map) return null;
    return CupSize(
      system: _str(json['system']),
      band: _num(json['band']),
      bandUnit: _str(json['bandUnit'], 'cm'),
      cup: _str(json['cup']),
      label: _str(json['label']),
      differenceCm: _num(json['differenceCm']),
      differenceIn: _num(json['differenceIn']),
    );
  }
}

/// Growth of the difference between bust and underbust.
class GrowthReport {
  const GrowthReport({
    required this.points,
    required this.spanDays,
    required this.firstDifferenceCm,
    required this.lastDifferenceCm,
    required this.changeCm,
    required this.rateCmPerMonth,
    required this.nextCup,
    required this.monthsToNextCup,
  });

  final int points;
  final double spanDays;
  final double firstDifferenceCm;
  final double lastDifferenceCm;
  final double changeCm;

  /// Least-squares slope, in cm per 30.44 days.
  final double rateCmPerMonth;
  final String? nextCup;

  /// `null` when the rate is flat or negative; a stop cannot be projected.
  final double? monthsToNextCup;

  static GrowthReport? fromJson(Object? json) {
    if (json is! Map) return null;
    return GrowthReport(
      points: _int(json['points']),
      spanDays: _num(json['spanDays']),
      firstDifferenceCm: _num(json['firstDifferenceCm']),
      lastDifferenceCm: _num(json['lastDifferenceCm']),
      changeCm: _num(json['changeCm']),
      rateCmPerMonth: _num(json['rateCmPerMonth']),
      nextCup: json['nextCup']?.toString(),
      monthsToNextCup: _optNum(json['monthsToNextCup']),
    );
  }
}

/// Bust, underbust and the cup size they imply.
class BodyReport {
  const BodyReport({
    required this.system,
    required this.bustCm,
    required this.underbustCm,
    required this.differenceCm,
    required this.differenceIn,
    required this.sizes,
    required this.ratio,
    required this.bmi,
    required this.paired,
    required this.cupProgress,
    required this.growth,
    required this.note,
  });

  final String system;
  final double? bustCm;
  final double? underbustCm;
  final double? differenceCm;
  final double? differenceIn;

  /// The requested system first, then the others.
  final List<CupSize> sizes;

  /// Bust ÷ underbust, independent of any sizing convention.
  final double? ratio;
  final double? bmi;
  final bool paired;

  /// Where the difference sits between two cup boundaries, 0–1.
  final double? cupProgress;
  final GrowthReport? growth;
  final String note;

  CupSize? sizeIn(String code) {
    for (final s in sizes) {
      if (s.system == code) return s;
    }
    return null;
  }

  static BodyReport? fromJson(Object? json) {
    if (json is! Map) return null;
    final raw = json['sizes'];
    return BodyReport(
      system: _str(json['system'], 'eu'),
      bustCm: _optNum(json['bustCm']),
      underbustCm: _optNum(json['underbustCm']),
      differenceCm: _optNum(json['differenceCm']),
      differenceIn: _optNum(json['differenceIn']),
      sizes: [
        if (raw is List)
          for (final entry in raw)
            if (CupSize.fromJson(entry) case final s?) s,
      ],
      ratio: _optNum(json['ratio']),
      bmi: _optNum(json['bmi']),
      paired: json['paired'] == true,
      cupProgress: _optNum(json['cupProgress']),
      growth: GrowthReport.fromJson(json['growth']),
      note: _str(json['note']),
    );
  }
}
