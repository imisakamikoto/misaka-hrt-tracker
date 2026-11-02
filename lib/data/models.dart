import 'dart:math' as math;

/// Route a dose takes into the body. String codes match the original storage.
enum DoseRoute {
  sublingual('sublingual'),
  injection('injection'),
  patchApply('patchApply'),
  patchRemove('patchRemove'),
  gel('gel'),
  oral('oral');

  const DoseRoute(this.code);
  final String code;

  bool get isInjection => this == DoseRoute.injection;
  bool get isPatch =>
      this == DoseRoute.patchApply || this == DoseRoute.patchRemove;

  static DoseRoute? tryParse(String? code) {
    for (final v in values) {
      if (v.code == code) return v;
    }
    return null;
  }
}

/// Every drug the app can log. Codes match the original storage exactly.
enum Ester {
  E2('Estradiol', 272.38),
  EB('Estradiol benzoate', 376.5),
  EV('Estradiol valerate', 356.5),
  EC('Estradiol cypionate', 396.58),
  EN('Estradiol enanthate', 384.56),
  EU('Estradiol undecylate', 440.66),
  CPA('Cyproterone acetate', 416.94),
  SPIRO('Spironolactone', 416.57),
  BICA('Bicalutamide', 430.37),
  MPA('Medroxyprogesterone acetate', 386.52),
  LEUP('Leuprorelin', 1209.42),
  TRIP('Triptorelin', 1311.45),
  RLX('Raloxifene', 473.58),
  T('Testosterone', 288.42),
  TC('Testosterone cypionate', 412.6),
  TE('Testosterone enanthate', 400.59),
  TU('Testosterone undecanoate', 456.7);

  const Ester(this.label, this.mw);
  final String label;
  final double mw;

  String get code => name;

  static Ester? tryParse(String? code) {
    if (code == null) return null;
    for (final v in values) {
      if (v.name == code) return v;
    }
    return null;
  }

  bool get isTestosterone =>
      this == T || this == TC || this == TE || this == TU;

  bool get isUnmodelled =>
      this == SPIRO ||
      this == BICA ||
      this == MPA ||
      this == LEUP ||
      this == TRIP ||
      this == RLX;

  bool get isEstradiol => !isTestosterone && this != CPA && !isUnmodelled;

  bool get isGnrhAgonist => this == LEUP || this == TRIP;

  /// mg of active hormone per mg of logged ester.
  double get toActiveFactor {
    if (isUnmodelled || this == CPA || this == E2) return 1.0;
    if (isTestosterone) return Ester.T.mw / mw;
    return Ester.E2.mw / mw;
  }
}

/// Keys allowed in [DoseEvent.extras].
abstract final class ExtraKey {
  static const concentration = 'concentrationMGmL';
  static const area = 'areaCM2';
  static const releaseRate = 'releaseRateUGPerDay';
  static const sublingualTheta = 'sublingualTheta';
  static const sublingualTier = 'sublingualTier';
  static const gelSite = 'gelSite';
  static const patchWear = 'patchWearH';
}

const gelSites = ['arm', 'thigh', 'scrotal'];

double hoursFromDateTime(DateTime t) => t.millisecondsSinceEpoch / 3600000.0;
DateTime dateTimeFromHours(double h) =>
    DateTime.fromMillisecondsSinceEpoch((h * 3600000).round(), isUtc: false);

class DoseEvent {
  DoseEvent({
    required this.id,
    required this.route,
    required this.timeH,
    required this.doseMG,
    required this.ester,
    Map<String, double>? extras,
    this.updatedAt,
  }) : extras = extras ?? <String, double>{};

  final String id;
  final DoseRoute route;
  final double timeH;
  final double doseMG;
  final Ester ester;
  final Map<String, double> extras;
  int? updatedAt;

  DateTime get time => dateTimeFromHours(timeH);

  double? extra(String key) => extras[key];

  int get gelSiteIndex {
    final v = extras[ExtraKey.gelSite];
    if (v == null || !v.isFinite) return 0;
    return v.round().clamp(0, gelSites.length - 1);
  }

  String get gelSite => gelSites[gelSiteIndex];

  double? get patchRateUgPerDay {
    final v = extras[ExtraKey.releaseRate];
    return v != null && v > 0 ? v : null;
  }

  double? get patchWearH {
    final v = extras[ExtraKey.patchWear];
    return v != null && v > 0 ? v : null;
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'route': route.code,
    'timeH': timeH,
    'doseMG': doseMG,
    'ester': ester.code,
    'extras': extras,
    if (updatedAt != null) 'updatedAt': updatedAt,
  };

  static DoseEvent? fromJson(Map<String, dynamic> json) {
    final route = DoseRoute.tryParse(json['route'] as String?);
    final ester = Ester.tryParse(json['ester'] as String?);
    if (route == null || ester == null) return null;
    final timeH = _num(json['timeH']);
    final doseMG = _num(json['doseMG']);
    if (timeH == null || doseMG == null) return null;
    if (timeH < 0 || timeH > 1500000 || doseMG < 0 || doseMG > 10000)
      return null;
    final extras = <String, double>{};
    final raw = json['extras'];
    if (raw is Map) {
      for (final entry in raw.entries) {
        final v = _num(entry.value);
        if (v != null) extras[entry.key.toString()] = v;
      }
    }
    return DoseEvent(
      id: (json['id'] ?? '').toString(),
      route: route,
      timeH: timeH,
      doseMG: doseMG,
      ester: ester,
      extras: extras,
      updatedAt: (json['updatedAt'] as num?)?.toInt(),
    );
  }

  DoseEvent copyWith({
    String? id,
    DoseRoute? route,
    double? timeH,
    double? doseMG,
    Ester? ester,
    Map<String, double>? extras,
    int? updatedAt,
  }) => DoseEvent(
    id: id ?? this.id,
    route: route ?? this.route,
    timeH: timeH ?? this.timeH,
    doseMG: doseMG ?? this.doseMG,
    ester: ester ?? this.ester,
    extras: extras ?? Map.of(this.extras),
    updatedAt: updatedAt ?? this.updatedAt,
  );
}

enum LabUnit {
  pgMl('pg/ml'),
  pmolL('pmol/l'),
  ngDl('ng/dl'),
  nmolL('nmol/l');

  const LabUnit(this.code);
  final String code;

  bool get isTestosterone => this == ngDl || this == nmolL;

  double toModelUnit(double value) => switch (this) {
    LabUnit.pgMl || LabUnit.ngDl => value,
    LabUnit.pmolL => value / 3.671,
    LabUnit.nmolL => value * 28.842,
  };

  static LabUnit? tryParse(String? code) {
    for (final v in values) {
      if (v.code == code) return v;
    }
    return null;
  }
}

class LabResult {
  LabResult({
    required this.id,
    required this.timeH,
    required this.concValue,
    required this.unit,
    this.assay,
    this.updatedAt,
  });

  final String id;
  final double timeH;
  final double concValue;
  final LabUnit unit;
  final String? assay;
  int? updatedAt;

  DateTime get time => dateTimeFromHours(timeH);

  Map<String, dynamic> toJson() => {
    'id': id,
    'timeH': timeH,
    'concValue': concValue,
    'unit': unit.code,
    if (assay != null) 'assay': assay,
    if (updatedAt != null) 'updatedAt': updatedAt,
  };

  static LabResult? fromJson(Map<String, dynamic> json) {
    final unit = LabUnit.tryParse(json['unit'] as String?);
    final timeH = _num(json['timeH']);
    final value = _num(json['concValue']);
    if (unit == null || timeH == null || value == null) return null;
    return LabResult(
      id: (json['id'] ?? '').toString(),
      timeH: timeH,
      concValue: value,
      unit: unit,
      assay: json['assay'] as String?,
      updatedAt: (json['updatedAt'] as num?)?.toInt(),
    );
  }

  LabResult copyWith({
    String? id,
    double? timeH,
    double? concValue,
    LabUnit? unit,
    String? assay,
    int? updatedAt,
  }) => LabResult(
    id: id ?? this.id,
    timeH: timeH ?? this.timeH,
    concValue: concValue ?? this.concValue,
    unit: unit ?? this.unit,
    assay: assay ?? this.assay,
    updatedAt: updatedAt ?? this.updatedAt,
  );
}

class Frequency {
  const Frequency(this.key, this.everyDays, this.timesPerDay);
  final String key;
  final double everyDays;
  final int timesPerDay;
}

const frequencyPresets = <Frequency>[
  Frequency('d1', 1, 1),
  Frequency('d2', 1, 2),
  Frequency('d3', 1, 3),
  Frequency('e2', 2, 1),
  Frequency('e3', 3, 1),
  Frequency('e3.5', 3.5, 1),
  Frequency('e5', 5, 1),
  Frequency('e7', 7, 1),
  Frequency('e10', 10, 1),
  Frequency('e14', 14, 1),
  Frequency('e28', 28, 1),
  Frequency('e84', 84, 1),
];

Frequency? parseFrequency(String key) {
  for (final f in frequencyPresets) {
    if (f.key == key) return f;
  }
  final every = RegExp(r'^e(\d{1,3}(?:\.\d+)?)$').firstMatch(key);
  if (every != null) {
    final n = double.tryParse(every.group(1)!);
    if (n != null && n >= 1 && n <= 180) return Frequency(key, n, 1);
    return null;
  }
  final daily = RegExp(r'^d(\d{1,2})$').firstMatch(key);
  if (daily != null) {
    final n = int.tryParse(daily.group(1)!);
    if (n != null && n >= 1 && n <= 8) return Frequency(key, 1, n);
  }
  return null;
}

String frequencyKey(double everyDays, int timesPerDay) =>
    everyDays <= 1 ? 'd$timesPerDay' : 'e${_trimNumber(everyDays)}';

String _trimNumber(double v) {
  if (v == v.roundToDouble()) return v.toInt().toString();
  return v.toString();
}

/// What the person takes and how often.
class PlanItem {
  PlanItem({
    required this.id,
    required this.route,
    required this.ester,
    required this.doseMG,
    Map<String, double>? extras,
    this.everyDays = 1,
    this.timesPerDay = 1,
  }) : extras = extras ?? <String, double>{};

  final String id;
  final DoseRoute route;
  final Ester ester;
  final double doseMG;
  final Map<String, double> extras;
  final double everyDays;
  final int timesPerDay;

  String get key => frequencyKey(everyDays, timesPerDay);

  /// Doses per day this item asks for.
  double get dosesPerDay =>
      everyDays <= 1 ? timesPerDay.toDouble() : 1 / everyDays;

  Map<String, dynamic> toJson() => {
    'id': id,
    'route': route.code,
    'ester': ester.code,
    'doseMG': doseMG,
    'extras': extras,
    'everyDays': everyDays,
    'timesPerDay': timesPerDay,
  };

  static PlanItem? fromJson(Map<String, dynamic> json) {
    final route = DoseRoute.tryParse(json['route'] as String?);
    final ester = Ester.tryParse(json['ester'] as String?);
    final dose = _num(json['doseMG']);
    if (route == null || ester == null || dose == null) return null;
    final extras = <String, double>{};
    final raw = json['extras'];
    if (raw is Map) {
      for (final e in raw.entries) {
        final v = _num(e.value);
        if (v != null) extras[e.key.toString()] = v;
      }
    }
    return PlanItem(
      id: (json['id'] ?? '').toString(),
      route: route,
      ester: ester,
      doseMG: dose,
      extras: extras,
      everyDays: (_num(json['everyDays']) ?? 1).clamp(1, 3650),
      timesPerDay: ((_num(json['timesPerDay']) ?? 1).round()).clamp(1, 24),
    );
  }

  PlanItem copyWith({
    String? id,
    DoseRoute? route,
    Ester? ester,
    double? doseMG,
    Map<String, double>? extras,
    double? everyDays,
    int? timesPerDay,
  }) => PlanItem(
    id: id ?? this.id,
    route: route ?? this.route,
    ester: ester ?? this.ester,
    doseMG: doseMG ?? this.doseMG,
    extras: extras ?? Map.of(this.extras),
    everyDays: everyDays ?? this.everyDays,
    timesPerDay: timesPerDay ?? this.timesPerDay,
  );
}

/// How a medicine comes, so a count on the shelf converts to mg.
sealed class Pack {
  const Pack();
  String get kind;
  double get unitMG;
  Map<String, dynamic> toJson();

  static Pack? fromJson(Map<String, dynamic> json) {
    switch (json['kind']) {
      case 'vial':
        return VialPack(
          ml: _num(json['ml']) ?? 1,
          mgPerMl: _num(json['mgPerMl']) ?? 1,
        );
      case 'pill':
        return PillPack(mg: _num(json['mg']) ?? 1);
      case 'pump':
        return PumpPack(mg: _num(json['mg']) ?? 1);
      case 'sachet':
        return SachetPack(mg: _num(json['mg']) ?? 1);
      case 'patch':
        return const PatchPack();
      case 'bulk':
        return const BulkPack();
    }
    return null;
  }
}

class VialPack extends Pack {
  const VialPack({required this.ml, required this.mgPerMl});
  final double ml;
  final double mgPerMl;
  @override
  String get kind => 'vial';
  @override
  double get unitMG => ml * mgPerMl;
  @override
  Map<String, dynamic> toJson() => {'kind': kind, 'ml': ml, 'mgPerMl': mgPerMl};
}

class PillPack extends Pack {
  const PillPack({required this.mg});
  final double mg;
  @override
  String get kind => 'pill';
  @override
  double get unitMG => mg;
  @override
  Map<String, dynamic> toJson() => {'kind': kind, 'mg': mg};
}

class PumpPack extends Pack {
  const PumpPack({required this.mg});
  final double mg;
  @override
  String get kind => 'pump';
  @override
  double get unitMG => mg;
  @override
  Map<String, dynamic> toJson() => {'kind': kind, 'mg': mg};
}

class SachetPack extends Pack {
  const SachetPack({required this.mg});
  final double mg;
  @override
  String get kind => 'sachet';
  @override
  double get unitMG => mg;
  @override
  Map<String, dynamic> toJson() => {'kind': kind, 'mg': mg};
}

class PatchPack extends Pack {
  const PatchPack();
  @override
  String get kind => 'patch';
  @override
  double get unitMG => 1;
  @override
  Map<String, dynamic> toJson() => {'kind': kind};
}

class BulkPack extends Pack {
  const BulkPack();
  @override
  String get kind => 'bulk';
  @override
  double get unitMG => 1;
  @override
  Map<String, dynamic> toJson() => {'kind': kind};
}

List<String> packKindsFor(DoseRoute route) => switch (route) {
  DoseRoute.injection => const ['vial', 'ampoule', 'bulk'],
  DoseRoute.patchApply => const ['patch'],
  DoseRoute.gel => const ['pump', 'sachet', 'bulk'],
  DoseRoute.oral || DoseRoute.sublingual => const ['pill', 'bulk'],
  _ => const ['bulk'],
};

Pack defaultPackFor(DoseRoute route) => switch (route) {
  DoseRoute.injection => const VialPack(ml: 1, mgPerMl: 10),
  DoseRoute.patchApply => const PatchPack(),
  DoseRoute.gel => const PumpPack(mg: 1),
  _ => const PillPack(mg: 1),
};

class Supply {
  Supply({
    required this.id,
    required this.route,
    required this.ester,
    required this.pack,
    required this.count,
    required this.startedAt,
  });

  final String id;
  final DoseRoute route;
  final Ester ester;
  final Pack pack;
  final double count;

  /// Epoch ms from which logged doses are subtracted.
  final int startedAt;

  Map<String, dynamic> toJson() => {
    'id': id,
    'route': route.code,
    'ester': ester.code,
    'pack': pack.toJson(),
    'count': count,
    'startedAt': startedAt,
  };

  static Supply? fromJson(Map<String, dynamic> json) {
    final route = DoseRoute.tryParse(json['route'] as String?);
    final ester = Ester.tryParse(json['ester'] as String?);
    final pack = json['pack'] is Map
        ? Pack.fromJson(json['pack'] as Map<String, dynamic>)
        : null;
    final count = _num(json['count']);
    if (route == null || ester == null || pack == null || count == null)
      return null;
    return Supply(
      id: (json['id'] ?? '').toString(),
      route: route,
      ester: ester,
      pack: pack,
      count: count,
      startedAt: (json['startedAt'] as num?)?.toInt() ?? 0,
    );
  }
}

class QuickDose {
  QuickDose({
    required this.id,
    required this.route,
    required this.ester,
    required this.value,
    required this.createdAt,
  });

  final String id;
  final DoseRoute route;
  final Ester ester;
  final double value;
  final int createdAt;

  Map<String, dynamic> toJson() => {
    'id': id,
    'route': route.code,
    'ester': ester.code,
    'value': value,
    'createdAt': createdAt,
  };

  static QuickDose? fromJson(Map<String, dynamic> json) {
    final route = DoseRoute.tryParse(json['route'] as String?);
    final ester = Ester.tryParse(json['ester'] as String?);
    final value = _num(json['value']);
    if (route == null || ester == null || value == null) return null;
    return QuickDose(
      id: (json['id'] ?? '').toString(),
      route: route,
      ester: ester,
      value: value,
      createdAt: (json['createdAt'] as num?)?.toInt() ?? 0,
    );
  }
}

class DoseTemplate {
  DoseTemplate({
    required this.id,
    required this.name,
    required this.route,
    required this.ester,
    required this.doseMG,
    Map<String, double>? extras,
    required this.createdAt,
    this.updatedAt,
  }) : extras = extras ?? <String, double>{};

  final String id;
  final String name;
  final DoseRoute route;
  final Ester ester;
  final double doseMG;
  final Map<String, double> extras;
  final int createdAt;
  int? updatedAt;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'route': route.code,
    'ester': ester.code,
    'doseMG': doseMG,
    'extras': extras,
    'createdAt': createdAt,
    if (updatedAt != null) 'updatedAt': updatedAt,
  };

  static DoseTemplate? fromJson(Map<String, dynamic> json) {
    final route = DoseRoute.tryParse(json['route'] as String?);
    final ester = Ester.tryParse(json['ester'] as String?);
    final dose = _num(json['doseMG']);
    if (route == null || ester == null || dose == null) return null;
    final extras = <String, double>{};
    final raw = json['extras'];
    if (raw is Map) {
      for (final e in raw.entries) {
        final v = _num(e.value);
        if (v != null) extras[e.key.toString()] = v;
      }
    }
    return DoseTemplate(
      id: (json['id'] ?? '').toString(),
      name: (json['name'] ?? '').toString(),
      route: route,
      ester: ester,
      doseMG: dose,
      extras: extras,
      createdAt: (json['createdAt'] as num?)?.toInt() ?? 0,
      updatedAt: (json['updatedAt'] as num?)?.toInt(),
    );
  }
}

/// Tunable PK parameters, mirroring the Rust struct.
class PkParams {
  PkParams({
    this.e2KClear = 0.41,
    this.e2KClearInj = 0.041,
    this.e2FfEb = 0.1092,
    this.e2FfEv = 0.0623,
    this.e2FfEc = 0.1173,
    this.e2FfEn = 0.12,
    this.e2FfEu = 0.04,
    this.e2OralBio = 0.03,
    this.e2SlQuick = 0.01,
    this.e2SlCasual = 0.04,
    this.e2SlStandard = 0.11,
    this.e2SlStrict = 0.18,
    this.e2GelArm = 0.05,
    this.e2GelThigh = 0.05,
    this.e2GelScrotal = 0.25,
    this.tKClear = 0.5,
    this.tKClearInj = 0.035,
    this.tFfTc = 0.043,
    this.tFfTe = 0.043,
    this.tFfTu = 0.043,
    this.tGelArm = 0.1,
    this.tGelThigh = 0.1,
    this.tGelScrotal = 0.5,
  });

  final double e2KClear;
  final double e2KClearInj;
  final double e2FfEb;
  final double e2FfEv;
  final double e2FfEc;
  final double e2FfEn;
  final double e2FfEu;
  final double e2OralBio;
  final double e2SlQuick;
  final double e2SlCasual;
  final double e2SlStandard;
  final double e2SlStrict;
  final double e2GelArm;
  final double e2GelThigh;
  final double e2GelScrotal;
  final double tKClear;
  final double tKClearInj;
  final double tFfTc;
  final double tFfTe;
  final double tFfTu;
  final double tGelArm;
  final double tGelThigh;
  final double tGelScrotal;

  Map<String, dynamic> toJson() => {
    'e2KClear': e2KClear,
    'e2KClearInj': e2KClearInj,
    'e2FfEb': e2FfEb,
    'e2FfEv': e2FfEv,
    'e2FfEc': e2FfEc,
    'e2FfEn': e2FfEn,
    'e2FfEu': e2FfEu,
    'e2OralBio': e2OralBio,
    'e2SlQuick': e2SlQuick,
    'e2SlCasual': e2SlCasual,
    'e2SlStandard': e2SlStandard,
    'e2SlStrict': e2SlStrict,
    'e2GelArm': e2GelArm,
    'e2GelThigh': e2GelThigh,
    'e2GelScrotal': e2GelScrotal,
    'tKClear': tKClear,
    'tKClearInj': tKClearInj,
    'tFfTc': tFfTc,
    'tFfTe': tFfTe,
    'tFfTu': tFfTu,
    'tGelArm': tGelArm,
    'tGelThigh': tGelThigh,
    'tGelScrotal': tGelScrotal,
  };

  static PkParams fromJson(Map<String, dynamic> json) {
    double read(String key, double fallback) {
      final v = _num(json[key]);
      return v ?? fallback;
    }

    final d = _PkDefaults();
    return PkParams(
      e2KClear: read('e2KClear', d.e2KClear),
      e2KClearInj: read('e2KClearInj', d.e2KClearInj),
      e2FfEb: read('e2FfEb', d.e2FfEb),
      e2FfEv: read('e2FfEv', d.e2FfEv),
      e2FfEc: read('e2FfEc', d.e2FfEc),
      e2FfEn: read('e2FfEn', d.e2FfEn),
      e2FfEu: read('e2FfEu', d.e2FfEu),
      e2OralBio: read('e2OralBio', d.e2OralBio),
      e2SlQuick: read('e2SlQuick', d.e2SlQuick),
      e2SlCasual: read('e2SlCasual', d.e2SlCasual),
      e2SlStandard: read('e2SlStandard', d.e2SlStandard),
      e2SlStrict: read('e2SlStrict', d.e2SlStrict),
      e2GelArm: read('e2GelArm', d.e2GelArm),
      e2GelThigh: read('e2GelThigh', d.e2GelThigh),
      e2GelScrotal: read('e2GelScrotal', d.e2GelScrotal),
      tKClear: read('tKClear', d.tKClear),
      tKClearInj: read('tKClearInj', d.tKClearInj),
      tFfTc: read('tFfTc', d.tFfTc),
      tFfTe: read('tFfTe', d.tFfTe),
      tFfTu: read('tFfTu', d.tFfTu),
      tGelArm: read('tGelArm', d.tGelArm),
      tGelThigh: read('tGelThigh', d.tGelThigh),
      tGelScrotal: read('tGelScrotal', d.tGelScrotal),
    );
  }

  bool get isDefault => toJson().entries.every((e) {
    final defaults = PkParams().toJson();
    return (defaults[e.key] as double) == e.value;
  });

  (double, double) rangeFor(String field) => switch (field) {
    'e2KClear' || 'tKClear' => (0.001, 5),
    'e2KClearInj' || 'tKClearInj' => (0.001, 1),
    _ => (0, 1),
  };

  PkParams withField(String field, double value) {
    final json = toJson();
    json[field] = value;
    return PkParams.fromJson(json);
  }
}

class _PkDefaults {
  final double e2KClear = 0.41;
  final double e2KClearInj = 0.041;
  final double e2FfEb = 0.1092;
  final double e2FfEv = 0.0623;
  final double e2FfEc = 0.1173;
  final double e2FfEn = 0.12;
  final double e2FfEu = 0.04;
  final double e2OralBio = 0.03;
  final double e2SlQuick = 0.01;
  final double e2SlCasual = 0.04;
  final double e2SlStandard = 0.11;
  final double e2SlStrict = 0.18;
  final double e2GelArm = 0.05;
  final double e2GelThigh = 0.05;
  final double e2GelScrotal = 0.25;
  final double tKClear = 0.5;
  final double tKClearInj = 0.035;
  final double tFfTc = 0.043;
  final double tFfTe = 0.043;
  final double tFfTu = 0.043;
  final double tGelArm = 0.1;
  final double tGelThigh = 0.1;
  final double tGelScrotal = 0.5;
}

// --- Simulation mirrors of the Rust result -------------------------------

class SimulationResult {
  SimulationResult({
    required this.timeH,
    required this.e2PgMl,
    required this.cpaNgMl,
    required this.tNgDl,
    required this.auc,
  });

  final List<double> timeH;
  final List<double> e2PgMl;
  final List<double> cpaNgMl;
  final List<double> tNgDl;
  final double auc;

  bool get isEmpty => timeH.isEmpty;

  static SimulationResult? fromJson(Map<String, dynamic> json) {
    final time = _numList(json['timeH']);
    final e2 = _numList(json['e2PgMl']);
    final cpa = _numList(json['cpaNgMl']);
    final t = _numList(json['tNgDl']);
    if (time.isEmpty || time.length != e2.length) return null;
    return SimulationResult(
      timeH: time,
      e2PgMl: e2,
      cpaNgMl: cpa,
      tNgDl: t,
      auc: _num(json['auc']) ?? 0,
    );
  }

  int _indexBefore(double hour) {
    if (hour <= timeH.first) return 0;
    if (hour >= timeH.last) return timeH.length - 1;
    var lo = 0;
    var hi = timeH.length - 1;
    while (hi - lo > 1) {
      final mid = (lo + hi) ~/ 2;
      if (timeH[mid] <= hour) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  double _interp(List<double> values, double hour) {
    if (values.isEmpty) return 0;
    final i = _indexBefore(hour);
    if (i + 1 >= timeH.length) return values[i];
    final t0 = timeH[i];
    final t1 = timeH[i + 1];
    final c0 = values[i];
    final c1 = values[i + 1];
    if (t1 <= t0) return c0;
    return c0 + (c1 - c0) * (hour - t0) / (t1 - t0);
  }

  double e2At(double hour) => _interp(e2PgMl, hour);
  double cpaAt(double hour) => _interp(cpaNgMl, hour);
  double tAt(double hour) => _interp(tNgDl, hour);

  double get e2Max => e2PgMl.isEmpty ? 0 : e2PgMl.reduce(math.max);
  double get tMax => tNgDl.isEmpty ? 0 : tNgDl.reduce(math.max);
  double get cpaMax => cpaNgMl.isEmpty ? 0 : cpaNgMl.reduce(math.max);
}

class CalibrationPoint {
  CalibrationPoint({
    required this.timeH,
    required this.obs,
    required this.model,
    required this.ratio,
    required this.hormone,
  });

  final double timeH;
  final double obs;
  final double model;
  final double ratio;
  final String hormone;

  DateTime get time => dateTimeFromHours(timeH);

  static CalibrationPoint fromJson(Map<String, dynamic> j) => CalibrationPoint(
    timeH: (_num(j['timeH']) ?? 0),
    obs: (_num(j['obs']) ?? 0),
    model: (_num(j['model']) ?? 0),
    ratio: (_num(j['ratio']) ?? 1),
    hormone: (j['hormone'] ?? 'e2').toString(),
  );
}

class FactorSegment {
  FactorSegment(this.timeH, this.factor);
  final double timeH;
  final double factor;
}

class CalibrationResult {
  CalibrationResult({
    required this.method,
    required this.scale,
    required this.clearanceMult,
    required this.halfLifeDeltaPct,
    required this.n,
    required this.fitErrPct,
    required this.points,
    required this.segments,
  });

  final String method;
  final double scale;
  final double clearanceMult;
  final double halfLifeDeltaPct;
  final int n;
  final double? fitErrPct;
  final List<CalibrationPoint> points;
  final List<FactorSegment> segments;

  static CalibrationResult identity(String method) => CalibrationResult(
    method: method,
    scale: 1,
    clearanceMult: 1,
    halfLifeDeltaPct: 0,
    n: 0,
    fitErrPct: null,
    points: const [],
    segments: const [],
  );

  static CalibrationResult fromJson(Map<String, dynamic> j) {
    final points = <CalibrationPoint>[];
    final rawPoints = j['points'];
    if (rawPoints is List) {
      for (final p in rawPoints) {
        if (p is Map)
          points.add(CalibrationPoint.fromJson(p.cast<String, dynamic>()));
      }
    }
    final segments = <FactorSegment>[];
    final rawSegments = j['segments'];
    if (rawSegments is List) {
      for (final s in rawSegments) {
        if (s is Map) {
          segments.add(
            FactorSegment(_num(s['timeH']) ?? 0, _num(s['factor']) ?? 1),
          );
        }
      }
    }
    return CalibrationResult(
      method: (j['method'] ?? 'off').toString(),
      scale: _num(j['scale']) ?? 1,
      clearanceMult: _num(j['clearanceMult']) ?? 1,
      halfLifeDeltaPct: _num(j['halfLifeDeltaPct']) ?? 0,
      n: (j['n'] as num?)?.toInt() ?? points.length,
      fitErrPct: _num(j['fitErrPct']),
      points: points,
      segments: segments,
    );
  }

  /// Factor applied at a given hour.
  double factorAt(double hour) {
    if (segments.isEmpty) return 1;
    var value = segments.first.factor;
    for (final s in segments) {
      if (s.timeH <= hour) value = s.factor;
    }
    return value;
  }
}

// --- helpers -------------------------------------------------------------

double? _num(Object? v) {
  if (v is num) {
    final d = v.toDouble();
    return d.isFinite ? d : null;
  }
  if (v is String) {
    final d = double.tryParse(v.trim());
    return (d != null && d.isFinite) ? d : null;
  }
  return null;
}

List<double> _numList(Object? v) {
  if (v is! List) return const [];
  final out = <double>[];
  for (final e in v) {
    final d = _num(e);
    if (d == null) return const [];
    out.add(d);
  }
  return out;
}

String formatDose(double mg) {
  if (mg == mg.roundToDouble()) return mg.toInt().toString();
  final s = mg.toStringAsFixed(2);
  return s.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
}
