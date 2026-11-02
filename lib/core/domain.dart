import 'dart:math' as math;

import '../data/models.dart';

/// Calendar-day arithmetic in local time. Day numbers count from the Unix
/// epoch so they survive a timezone change without shifting a record by a day.
int localDay(DateTime t) =>
    DateTime.utc(t.year, t.month, t.day).millisecondsSinceEpoch ~/ 86400000;

DateTime startOfDay(DateTime t) => DateTime(t.year, t.month, t.day);

/// Day number for an hour value as the database stores it.
int dayNumberFromHours(double hours) => localDay(dateTimeFromHours(hours));

/// Inverse of [localDay], always local midnight.
DateTime dayFromNumber(int dayNumber) {
  final utc = DateTime.fromMillisecondsSinceEpoch(
    dayNumber * 86400000,
    isUtc: true,
  );
  return DateTime(utc.year, utc.month, utc.day);
}

/// One line of "what the plan asks of me today".
class TodayDose {
  TodayDose({
    required this.item,
    required this.isDoseDay,
    required this.due,
    required this.taken,
  });

  final PlanItem item;
  final bool isDoseDay;

  /// How many doses the plan asks for today.
  final int due;

  /// How many of those have already been logged.
  final int taken;

  bool get isDone => due > 0 && taken >= due;
  bool get isPartial => taken > 0 && taken < due;
}

bool _sameDrug(PlanItem item, DoseEvent event) =>
    item.ester == event.ester && item.route == event.route;

/// The first day this regimen could have started: the earliest logged dose of
/// the same drug, or today when there is nothing logged yet.
int _anchorDay(PlanItem item, List<DoseEvent> doses, DateTime now) {
  int? earliest;
  for (final event in doses) {
    if (!_sameDrug(item, event)) continue;
    final day = localDay(event.time);
    if (earliest == null || day < earliest) earliest = day;
  }
  return earliest ?? localDay(now);
}

bool _isDoseDay(PlanItem item, int day, int anchor) {
  if (item.everyDays <= 1) return true;
  final offset = day - anchor;
  if (offset < 0) return false;
  final cycles = offset / item.everyDays;
  return (cycles - cycles.round()).abs() < 0.02;
}

/// The times of day this regimen is usually taken, learned from history.
List<double> _preferredHours(PlanItem item, List<DoseEvent> doses) {
  final seen = <double>[];
  for (final event in doses) {
    if (!_sameDrug(item, event)) continue;
    final t = event.time;
    seen.add(t.hour + t.minute / 60.0);
  }
  final count = item.timesPerDay;
  if (seen.isEmpty) {
    if (count <= 1) return const [9];
    if (count == 2) return const [9, 21];
    if (count == 3) return const [8, 14, 21];
    return [for (var i = 0; i < count; i++) 8 + i * (13.0 / (count - 1))];
  }
  seen.sort();
  if (count == 1) return [seen[seen.length ~/ 2]];
  return [
    for (var i = 0; i < count; i++)
      seen[((i + 0.5) * seen.length / count).floor().clamp(0, seen.length - 1)],
  ];
}

/// Everything the plan expects today, whether or not it has been logged.
List<TodayDose> todayDoses({
  required List<PlanItem> plan,
  required List<DoseEvent> doses,
  required DateTime now,
}) {
  final today = localDay(now);
  final out = <TodayDose>[];
  for (final item in plan) {
    final anchor = _anchorDay(item, doses, now);
    final due = _isDoseDay(item, today, anchor) ? item.timesPerDay : 0;
    final taken = doses
        .where((e) => _sameDrug(item, e) && localDay(e.time) == today)
        .length;
    out.add(TodayDose(item: item, isDoseDay: due > 0, due: due, taken: taken));
  }
  // Most urgent first: still to take, then already done, then not today.
  out.sort((a, b) {
    int rank(TodayDose d) => d.isDone ? 1 : (d.isDoseDay ? 0 : 2);
    final byRank = rank(a).compareTo(rank(b));
    if (byRank != 0) return byRank;
    return a.item.id.compareTo(b.item.id);
  });
  return out;
}

/// All planned doses in `(from, to]`, as events the model can simulate.
List<DoseEvent> futurePlanDoses(
  List<PlanItem> plan,
  DateTime from,
  DateTime to,
) {
  final out = <DoseEvent>[];
  final anchorDay = localDay(from);
  final spanDays = to.difference(startOfDay(from)).inHours / 24.0 + 2;
  for (final item in plan) {
    final hours = _preferredHours(item, const []);
    final cycles = (spanDays / item.everyDays).ceil() + 2;
    for (var cycle = 0; cycle < cycles; cycle++) {
      final day = dayFromNumber(anchorDay + (cycle * item.everyDays).round());
      if (day.isAfter(to)) break;
      for (var slot = 0; slot < item.timesPerDay; slot++) {
        final hour = hours[slot.clamp(0, hours.length - 1)];
        final at = day.add(Duration(minutes: (hour * 60).round()));
        if (!at.isAfter(from) || at.isAfter(to)) continue;
        out.add(
          DoseEvent(
            id: 'plan-${item.id}-$cycle-$slot',
            route: item.route,
            timeH: hoursFromDateTime(at),
            doseMG: item.doseMG,
            ester: item.ester,
            extras: Map.of(item.extras),
          ),
        );
      }
    }
  }
  out.sort((a, b) => a.timeH.compareTo(b.timeH));
  return out;
}

/// The next planned dose that has not been logged yet. Returns a past time when
/// one is overdue, so the overview can say so.
DateTime? nextDoseAt(List<PlanItem> plan, List<DoseEvent> doses, DateTime now) {
  final lower = now.subtract(const Duration(hours: 24));
  final upper = now.add(const Duration(days: 120));
  final candidates = <DateTime>[];
  for (final item in plan) {
    final anchor = _anchorDay(item, doses, now);
    final hours = _preferredHours(item, doses);
    for (var cycle = 0; ; cycle++) {
      final dayOffset = (cycle * item.everyDays).round();
      final day = dayFromNumber(anchor + dayOffset);
      if (day.isAfter(upper)) break;
      for (var slot = 0; slot < item.timesPerDay; slot++) {
        final hour = hours[slot.clamp(0, hours.length - 1)];
        final at = day.add(Duration(minutes: (hour * 60).round()));
        if (at.isBefore(lower) || at.isAfter(upper)) continue;
        final logged = doses
            .where(
              (e) => _sameDrug(item, e) && localDay(e.time) == localDay(at),
            )
            .length;
        if (logged > slot) continue;
        candidates.add(at);
      }
      if (candidates.length > 400) break;
    }
  }
  if (candidates.isEmpty) return null;
  candidates.sort();
  return candidates.first;
}

/// How much of a supply is left, and when it runs out at the current rate.
class SupplyStatus {
  SupplyStatus({
    required this.supply,
    required this.remaining,
    required this.dailyUse,
    required this.daysLeft,
    required this.runOut,
  });

  final Supply supply;

  /// Left over, in mg — or in patches for a patch supply.
  final double remaining;

  /// mg per day the plan (or recent history) implies.
  final double dailyUse;
  final double? daysLeft;
  final DateTime? runOut;
}

SupplyStatus supplyStatus(
  Supply supply,
  List<DoseEvent> doses,
  List<PlanItem> plan,
  DateTime now,
) {
  final isPatch = supply.route == DoseRoute.patchApply;
  double consumed;
  if (isPatch) {
    consumed = doses
        .where(
          (e) =>
              e.route == supply.route &&
              e.ester == supply.ester &&
              e.time.millisecondsSinceEpoch >= supply.startedAt,
        )
        .length
        .toDouble();
  } else {
    consumed = doses
        .where(
          (e) =>
              e.route == supply.route &&
              e.ester == supply.ester &&
              e.time.millisecondsSinceEpoch >= supply.startedAt,
        )
        .fold<double>(0, (sum, e) => sum + e.doseMG);
  }

  final total = isPatch ? supply.count : supply.count * supply.pack.unitMG;
  final remaining = math.max(0.0, total - consumed);

  var dailyUse = 0.0;
  for (final item in plan) {
    if (item.ester != supply.ester || item.route != supply.route) continue;
    dailyUse += isPatch ? 1 / item.everyDays : item.doseMG * item.dosesPerDay;
  }
  if (dailyUse <= 0) {
    // No plan for this drug: guess from the last 30 days of logging.
    final cutoff = now
        .subtract(const Duration(days: 30))
        .millisecondsSinceEpoch;
    final recent = doses.where(
      (e) =>
          e.route == supply.route &&
          e.ester == supply.ester &&
          e.time.millisecondsSinceEpoch >= cutoff,
    );
    if (isPatch) {
      dailyUse = recent.length / 30.0;
    } else {
      dailyUse = recent.fold<double>(0, (sum, e) => sum + e.doseMG) / 30.0;
    }
  }

  final daysLeft = dailyUse > 0 ? remaining / dailyUse : null;
  return SupplyStatus(
    supply: supply,
    remaining: remaining,
    dailyUse: dailyUse,
    daysLeft: daysLeft,
    runOut: daysLeft == null
        ? null
        : now.add(Duration(minutes: (daysLeft * 1440).round())),
  );
}

/// A single dose that is far above what is normally prescribed.
class DoseAdvisoryWarning {
  DoseAdvisoryWarning(this.kind);

  /// One of `e2`, `t`, `cpa`, `e2_cpa`.
  final String kind;
}

const _e2InjectionCeilingMG = 15.0;
const _e2OralCeilingMG = 6.0;
const _e2GelCeilingMG = 4.0;
const _tCeilingMG = 120.0;
const _cpaCeilingMG = 50.0;

DoseAdvisoryWarning? doseAdvisory(List<DoseEvent> doses, DateTime now) {
  final cutoff = now.subtract(const Duration(days: 7)).millisecondsSinceEpoch;
  var highE2 = false;
  var highT = false;
  var highCpa = false;
  for (final event in doses) {
    if (event.time.millisecondsSinceEpoch < cutoff) continue;
    final dose = event.doseMG;
    if (event.ester.isEstradiol) {
      final ceiling = switch (event.route) {
        DoseRoute.injection => _e2InjectionCeilingMG,
        DoseRoute.gel => _e2GelCeilingMG,
        _ => _e2OralCeilingMG,
      };
      if (dose > ceiling) highE2 = true;
    } else if (event.ester.isTestosterone) {
      if (dose > _tCeilingMG) highT = true;
    } else if (event.ester == Ester.CPA) {
      if (dose > _cpaCeilingMG) highCpa = true;
    }
  }
  if (highE2 && highCpa) return DoseAdvisoryWarning('e2_cpa');
  if (highE2) return DoseAdvisoryWarning('e2');
  if (highT) return DoseAdvisoryWarning('t');
  if (highCpa) return DoseAdvisoryWarning('cpa');
  return null;
}

/// A moment at which the modelled level is expected to fall below the low edge
/// of the target range, and the value it lands on.
class LevelDrop {
  LevelDrop({required this.at, required this.level});
  final DateTime at;
  final double level;
}

/// Where the level is predicted to cross *down* through [lowThreshold].
///
/// Only non-injection regimens are considered: an injection's curve is smooth
/// and predictable, while oral, gel, sublingual and patch curves are where a
/// reminder actually helps. The curve is walked hour by hour so a dip between
/// two sample points cannot be missed.
List<LevelDrop> predictedDrops({
  required SimulationResult sim,
  required List<PlanItem> plan,
  required bool transfem,
  required double lowThreshold,
  required DateTime now,
  int maxCount = 8,
  int horizonDays = 14,
}) {
  if (sim.isEmpty) return const [];
  final relevant = plan.where((p) => !p.route.isInjection).toList();
  if (relevant.isEmpty) return const [];
  if (!lowThreshold.isFinite || lowThreshold <= 0) return const [];

  final out = <LevelDrop>[];
  final startH = hoursFromDateTime(now);
  final endH = startH + horizonDays * 24;
  double levelAt(double h) => transfem ? sim.e2At(h) : sim.tAt(h);

  var below = levelAt(startH) < lowThreshold;
  for (var h = startH + 1; h <= endH; h += 1) {
    final value = levelAt(h);
    final nowBelow = value < lowThreshold;
    if (nowBelow && !below) {
      out.add(LevelDrop(at: dateTimeFromHours(h), level: value));
      if (out.length >= maxCount) break;
    }
    below = nowBelow;
  }
  return out;
}
