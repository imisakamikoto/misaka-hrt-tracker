import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

import '../data/models.dart';
import 'engine_models.dart';

/// Raised when the core rejects a request. The message is the engine's own,
/// which is written to be read by a person; [code] is what it calls the
/// failure internally.
class HrtEngineException implements Exception {
  HrtEngineException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => message.isEmpty ? code : message;
}

/// Dart side of the Rust core.
///
/// One convention on both sides: a function takes a JSON object and returns
/// `{"ok":true,"result":…}` or `{"ok":false,"code":…,"error":…}`. Nothing here
/// knows any pharmacokinetics — it shapes requests, reads answers, and lets the
/// library be the only place a number is produced.
class HrtEngine {
  HrtEngine._();

  static final HrtEngine instance = HrtEngine._();

  /// Bumped only when the wire format changes shape. The library refuses
  /// nothing on this, but the app refuses to run against a mismatched core
  /// rather than mis-reading its answers.
  static const abiVersion = 2;

  static bool _checked = false;

  /// Opened once per isolate; `dart:ffi` handles are not shareable.
  static DynamicLibrary? _lib;

  // --- loading ------------------------------------------------------------

  static DynamicLibrary _open() {
    final cached = _lib;
    if (cached != null) return cached;

    DynamicLibrary lib;
    if (Platform.isAndroid) {
      lib = DynamicLibrary.open('libhrt_core.so');
    } else if (Platform.isIOS) {
      // iOS cannot load a dylib that is not part of the bundle, so the core is
      // built as a static library and linked into the app executable. Its
      // symbols are in the process image, which is what `process()` exposes.
      lib = DynamicLibrary.process();
    } else if (Platform.isWindows) {
      lib = _openDesktop('hrt_core.dll');
    } else if (Platform.isMacOS) {
      lib = _openDesktop('libhrt_core.dylib');
    } else if (Platform.isLinux) {
      lib = _openDesktop('libhrt_core.so');
    } else {
      throw UnsupportedError('The PK core has no build for this platform.');
    }

    final abi = lib.lookupFunction<Int32 Function(), int Function()>(
      'hrt_abi_version',
    )();
    if (abi != abiVersion) {
      throw StateError('PK core ABI $abi, expected $abiVersion');
    }
    _checked = true;
    _lib = lib;
    return lib;
  }

  static DynamicLibrary _openDesktop(String name) {
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final candidates = [
      // Packaged builds: the library sits next to the executable.
      '$exeDir/$name',
      'rust/target/release/$name',
      'rust/target/debug/$name',
      '../rust/target/release/$name',
      '../rust/target/debug/$name',
      'build/windows/x64/runner/Release/$name',
    ];
    for (final path in candidates) {
      final file = File(path);
      if (file.existsSync()) return DynamicLibrary.open(file.absolute.path);
    }
    throw StateError(
      'Build the Rust core first: (cd rust && cargo build --release)',
    );
  }

  bool get isAvailable {
    try {
      _open();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Whether the shared library loaded, for the diagnostics row in settings.
  bool get checked => _checked;

  // --- identity -----------------------------------------------------------

  /// Synchronous on the calling isolate: cheap, and the settings screen wants
  /// it while building.
  String get version {
    final raw = _call('hrt_version', '{}');
    if (raw['ok'] != true) return '—';
    return raw['result'].toString();
  }

  /// What this build can do. Used by the diagnostics page instead of a
  /// hardcoded list that drifts.
  Future<EngineCapabilities?> capabilities() async {
    final raw = await Isolate.run(() => _call('hrt_capabilities', '{}'));
    _throwIfError(raw);
    return EngineCapabilities.fromJson(raw['result']);
  }

  // --- curves -------------------------------------------------------------

  Future<SimulationResult?> simulate({
    required List<DoseEvent> events,
    required double bodyWeightKg,
    int? birthYear,
    PkParams? params,
    double? nowH,
    double clearanceMult = 1.0,
    double? startH,
    double? endH,
    double? stepH,
    TargetRange? e2Target,
    TargetRange? tTarget,
  }) async {
    final payload = jsonEncode(
      _common(
        events: events,
        bodyWeightKg: bodyWeightKg,
        birthYear: birthYear,
        params: params,
        nowH: nowH,
        clearanceMult: clearanceMult,
        startH: startH,
        endH: endH,
        stepH: stepH,
        e2Target: e2Target,
        tTarget: tTarget,
      ),
    );
    final raw = await Isolate.run(() => _call('hrt_simulate', payload));
    _throwIfError(raw);
    final result = raw['result'];
    if (result is! Map) return null;
    return SimulationResult.fromJson(result.cast<String, dynamic>());
  }

  /// Peak, trough, time-weighted mean, AUC and time-in-range for a window.
  ///
  /// Passing `startH`/`endH` is what makes the numbers mean something: the
  /// automatic window includes the empty run-in before the first dose, which
  /// drags the trough to zero.
  Future<SimulationStats?> stats({
    required List<DoseEvent> events,
    required double bodyWeightKg,
    int? birthYear,
    PkParams? params,
    double? nowH,
    double clearanceMult = 1.0,
    double? startH,
    double? endH,
    double? stepH,
    TargetRange? e2Target,
    TargetRange? tTarget,
  }) async {
    final payload = jsonEncode(
      _common(
        events: events,
        bodyWeightKg: bodyWeightKg,
        birthYear: birthYear,
        params: params,
        nowH: nowH,
        clearanceMult: clearanceMult,
        startH: startH,
        endH: endH,
        stepH: stepH,
        e2Target: e2Target,
        tTarget: tTarget,
      ),
    );
    final raw = await Isolate.run(() => _call('hrt_stats', payload));
    _throwIfError(raw);
    return SimulationStats.fromJson(raw['result']);
  }

  /// Statistics and safety warnings in one crossing of the boundary.
  ///
  /// These two always run together after a recompute, and each one re-simulates
  /// the same events, so asking for both at once halves the work.
  Future<(SimulationStats?, List<SafetyWarning>)> audit({
    required List<DoseEvent> events,
    required double bodyWeightKg,
    int? birthYear,
    PkParams? params,
    double? nowH,
    double clearanceMult = 1.0,
    double? startH,
    double? endH,
    TargetRange? e2Target,
    TargetRange? tTarget,
    List<LabResult> labs = const [],
  }) async {
    if (events.isEmpty) return (null, const <SafetyWarning>[]);
    final common = _common(
      events: events,
      bodyWeightKg: bodyWeightKg,
      birthYear: birthYear,
      params: params,
      nowH: nowH,
      clearanceMult: clearanceMult,
      startH: startH,
      endH: endH,
      e2Target: e2Target,
      tTarget: tTarget,
    );
    final safetyPayload = {
      ...common,
      'labs': [for (final lab in labs) lab.toJson()],
    };
    final calls = <Map<String, dynamic>>[
      {'function': 'stats', 'input': common},
      {'function': 'safety', 'input': safetyPayload},
    ];
    final payload = jsonEncode({'calls': calls});
    final raw = await Isolate.run(() => _call('hrt_batch', payload));
    _throwIfError(raw);
    final results = raw['result'] is Map
        ? (raw['result'] as Map)['results']
        : null;
    SimulationStats? stats;
    var warnings = const <SafetyWarning>[];
    if (results is List) {
      if (results.isNotEmpty) {
        final first = results[0];
        if (first is Map && first['ok'] == true) {
          stats = SimulationStats.fromJson(first['result']);
        }
      }
      if (results.length > 1) {
        final second = results[1];
        if (second is Map && second['ok'] == true) {
          warnings = _warnings(second['result']);
        }
      }
    }
    return (stats, warnings);
  }

  // --- calibration --------------------------------------------------------

  Future<CalibrationResult> calibrate({
    required List<DoseEvent> events,
    required double bodyWeightKg,
    required List<LabResult> labs,
    int? birthYear,
    PkParams? params,
    String method = 'mipd',
    String historyMode = 'retrospective',
    double? nowH,
  }) async {
    final payload = jsonEncode({
      'events': events.map((e) => e.toJson()).toList(),
      'bodyWeightKg': bodyWeightKg,
      'birthYear': birthYear,
      'params': (params ?? PkParams()).toJson(),
      'labs': labs.map((l) => l.toJson()).toList(),
      'method': method,
      'historyMode': historyMode,
      'nowH': nowH ?? hoursFromDateTime(DateTime.now()),
    });
    final raw = await Isolate.run(() => _call('hrt_calibrate', payload));
    _throwIfError(raw);
    final result = raw['result'];
    if (result is! Map) return CalibrationResult.identity(method);
    return CalibrationResult.fromJson(result.cast<String, dynamic>());
  }

  // --- planning -----------------------------------------------------------

  /// Where a repeated schedule settles, without waiting months to find out.
  Future<SteadyState?> steadyState({
    required Schedule schedule,
    required double bodyWeightKg,
    int? birthYear,
    PkParams? params,
    int? maxCycles,
    TargetRange? e2Target,
    TargetRange? tTarget,
    bool includeSeries = false,
  }) async {
    final payload = jsonEncode({
      'schedule': schedule.toJson(),
      'bodyWeightKg': bodyWeightKg,
      'birthYear': birthYear,
      if (params != null) 'params': params.toJson(),
      if (maxCycles != null) 'maxCycles': maxCycles,
      if (e2Target != null && e2Target.isValid)
        'e2Target': e2Target.normalised.toJson(),
      if (tTarget != null && tTarget.isValid)
        'tTarget': tTarget.normalised.toJson(),
      'includeSeries': includeSeries,
    });
    final raw = await Isolate.run(() => _call('hrt_steady_state', payload));
    _throwIfError(raw);
    return SteadyState.fromJson(raw['result']);
  }

  /// The dose that puts a chosen statistic inside a target range.
  ///
  /// The answer is honest about infeasible intervals: [DoseSolution.feasible]
  /// is false and [DoseSolution.note] says which bound could not be met,
  /// rather than returning a number that merely looks plausible.
  Future<DoseSolution?> planDose({
    required Schedule schedule,
    required TargetRange target,
    required double bodyWeightKg,
    DoseObjective objective = DoseObjective.trough,
    int? birthYear,
    PkParams? params,
    int? maxCycles,
  }) async {
    final payload = jsonEncode({
      'schedule': schedule.toJson(),
      'target': target.normalised.toJson(),
      'objective': objective.code,
      'bodyWeightKg': bodyWeightKg,
      'birthYear': birthYear,
      if (params != null) 'params': params.toJson(),
      if (maxCycles != null) 'maxCycles': maxCycles,
    });
    final raw = await Isolate.run(() => _call('hrt_plan_dose', payload));
    _throwIfError(raw);
    return DoseSolution.fromJson(raw['result']);
  }

  /// How much the curve moves when one estimate is wrong.
  Future<List<SensitivityPoint>> sensitivity({
    required List<DoseEvent> events,
    required double bodyWeightKg,
    String parameter = 'clearance',
    double pct = 20,
    int? birthYear,
    PkParams? params,
    double? nowH,
    double clearanceMult = 1.0,
    double? startH,
    double? endH,
    TargetRange? e2Target,
    TargetRange? tTarget,
  }) async {
    final payload = jsonEncode({
      ..._common(
        events: events,
        bodyWeightKg: bodyWeightKg,
        birthYear: birthYear,
        params: params,
        nowH: nowH,
        clearanceMult: clearanceMult,
        startH: startH,
        endH: endH,
        e2Target: e2Target,
        tTarget: tTarget,
      ),
      'parameter': parameter,
      'pct': pct,
    });
    final raw = await Isolate.run(() => _call('hrt_sensitivity', payload));
    _throwIfError(raw);
    final result = raw['result'];
    if (result is! List) return const [];
    return [
      for (final entry in result)
        if (SensitivityPoint.fromJson(entry) case final point?) point,
    ];
  }

  // --- following through --------------------------------------------------

  /// When the level falls through [low], shifted earlier by [leadH].
  Future<ReminderReport?> reminders({
    required List<DoseEvent> events,
    required double low,
    required double bodyWeightKg,
    double? nowH,
    double horizonH = 24 * 14,
    double leadH = 12,
    double minGapH = 6,
    int? birthYear,
    PkParams? params,
    double clearanceMult = 1.0,
  }) async {
    final payload = jsonEncode({
      'events': events.map((e) => e.toJson()).toList(),
      'low': low,
      'bodyWeightKg': bodyWeightKg,
      'birthYear': birthYear,
      if (params != null) 'params': params.toJson(),
      'nowH': nowH ?? hoursFromDateTime(DateTime.now()),
      'clearanceMult': clearanceMult,
      'horizonH': horizonH,
      'leadH': leadH,
      'minGapH': minGapH,
    });
    final raw = await Isolate.run(() => _call('hrt_reminders', payload));
    _throwIfError(raw);
    return ReminderReport.fromJson(raw['result']);
  }

  /// Coverage, punctuality and gaps against a fixed interval.
  Future<AdherenceReport?> adherence({
    required List<DoseEvent> events,
    required double intervalH,
    required double fromH,
    required double toH,
  }) async {
    if (intervalH <= 0 || toH <= fromH) return null;
    final payload = jsonEncode({
      'events': events.map((e) => e.toJson()).toList(),
      'intervalH': intervalH,
      'fromH': fromH,
      'toH': toH,
    });
    final raw = await Isolate.run(() => _call('hrt_adherence', payload));
    _throwIfError(raw);
    return AdherenceReport.fromJson(raw['result']);
  }

  /// How long a supply lasts at the planned rate.
  Future<SupplyRunway?> supply({
    required double onHandMG,
    required Schedule schedule,
    double? asOfH,
  }) async {
    final payload = jsonEncode({
      'onHandMG': onHandMG,
      'schedule': schedule.toJson(),
      'asOfH': asOfH ?? hoursFromDateTime(DateTime.now()),
    });
    final raw = await Isolate.run(() => _call('hrt_supply', payload));
    _throwIfError(raw);
    return SupplyRunway.fromJson(raw['result']);
  }

  /// Which removal ended which application, and how long it was worn.
  Future<List<PatchPair>> patches(List<DoseEvent> events) async {
    if (events.isEmpty) return const [];
    final payload = jsonEncode({
      'events': events.map((e) => e.toJson()).toList(),
    });
    final raw = await Isolate.run(() => _call('hrt_patches', payload));
    _throwIfError(raw);
    final result = raw['result'];
    if (result is! List) return const [];
    return [
      for (final entry in result)
        if (PatchPair.fromJson(entry) case final pair?) pair,
    ];
  }

  /// What is wrong with the record or the plan.
  Future<List<SafetyWarning>> safety({
    required List<DoseEvent> events,
    required double bodyWeightKg,
    List<LabResult> labs = const [],
    int? birthYear,
    PkParams? params,
    double? nowH,
    double clearanceMult = 1.0,
    TargetRange? e2Target,
    TargetRange? tTarget,
  }) async {
    final payload = jsonEncode({
      ..._common(
        events: events,
        bodyWeightKg: bodyWeightKg,
        birthYear: birthYear,
        params: params,
        nowH: nowH,
        clearanceMult: clearanceMult,
        e2Target: e2Target,
        tTarget: tTarget,
      ),
      'labs': [for (final lab in labs) lab.toJson()],
    });
    final raw = await Isolate.run(() => _call('hrt_safety', payload));
    _throwIfError(raw);
    return _warnings(raw['result']);
  }

  /// Anti-androgen support: dose band, coverage, modelled level and the next
  /// dose due, per compound in the record.
  ///
  /// This is also where "am I late?" is answered for anti-androgens: the
  /// report carries [BlockadeCompound.nextDueH] and [BlockadeCompound.overdueH]
  /// computed from the same median interval the coverage figure uses.
  Future<BlockadeReport?> blockade({
    required List<DoseEvent> events,
    required double bodyWeightKg,
    double? nowH,
    double windowDays = 28,
    int? birthYear,
    PkParams? params,
    double clearanceMult = 1.0,
  }) async {
    if (events.isEmpty) return null;
    final payload = jsonEncode({
      'events': events.map((e) => e.toJson()).toList(),
      'bodyWeightKg': bodyWeightKg,
      'birthYear': birthYear,
      if (params != null) 'params': params.toJson(),
      'nowH': nowH ?? hoursFromDateTime(DateTime.now()),
      'clearanceMult': clearanceMult,
      'windowDays': windowDays,
    });
    final raw = await Isolate.run(() => _call('hrt_blockade', payload));
    _throwIfError(raw);
    return BlockadeReport.fromJson(raw['result']);
  }

  /// Conservative progress over a day, a month and a year.
  ///
  /// Both headline numbers are lower bounds, because the point is to be wrong
  /// in the safe direction: a single suppressed lab is not proof, and a
  /// regimen is only as good as its weaker half.
  Future<ProgressReport?> progress({
    required List<DoseEvent> events,
    required List<LabResult> labs,
    required double bodyWeightKg,
    double? nowH,
    int? birthYear,
    PkParams? params,
    double clearanceMult = 1.0,
    TargetRange? e2Target,
    TargetRange? tTarget,
  }) async {
    if (events.isEmpty) return null;
    final payload = jsonEncode({
      'events': events.map((e) => e.toJson()).toList(),
      'labs': [for (final lab in labs) lab.toJson()],
      'bodyWeightKg': bodyWeightKg,
      'birthYear': birthYear,
      if (params != null) 'params': params.toJson(),
      'nowH': nowH ?? hoursFromDateTime(DateTime.now()),
      'clearanceMult': clearanceMult,
      if (e2Target != null && e2Target.isValid)
        'e2Target': e2Target.normalised.toJson(),
      if (tTarget != null && tTarget.isValid)
        'tTarget': tTarget.normalised.toJson(),
    });
    final raw = await Isolate.run(() => _call('hrt_progress', payload));
    _throwIfError(raw);
    return ProgressReport.fromJson(raw['result']);
  }

  // --- body, comparison and scenarios -------------------------------------

  /// Bust, underbust and the cup size they imply.
  ///
  /// The underbust is optional per measurement: a bust alone is still a point
  /// on the chart, it just cannot be turned into a size. `system` picks which
  /// national convention comes first in [BodyReport.sizes]; the others follow
  /// it, because the same body is not one size.
  Future<BodyReport?> body({
    required List<BodyMeasure> measurements,
    String system = 'eu',
    double? heightCm,
    double? weightKg,
  }) async {
    if (measurements.isEmpty) return null;
    final payload = jsonEncode({
      'measurements': [
        for (final m in measurements)
          {
            'timeH': m.timeH,
            'bustCm': m.bustCm,
            if (m.underbustCm != null) 'underbustCm': m.underbustCm,
          },
      ],
      'system': system,
      if (heightCm != null && heightCm > 0) 'heightCm': heightCm,
      if (weightKg != null && weightKg > 0) 'weightKg': weightKg,
    });
    final raw = await Isolate.run(() => _call('hrt_body', payload));
    _throwIfError(raw);
    return BodyReport.fromJson(raw['result']);
  }

  /// Several regimens settled side by side.
  Future<Map<String, dynamic>?> compare({
    required List<Schedule> arms,
    required double bodyWeightKg,
    List<String>? labels,
    int? birthYear,
    PkParams? params,
    TargetRange? e2Target,
    TargetRange? tTarget,
    int maxCycles = 128,
  }) async {
    if (arms.isEmpty) return null;
    final payload = jsonEncode({
      'arms': [
        for (var i = 0; i < arms.length; i++)
          {
            if (labels != null && i < labels.length) 'label': labels[i],
            'schedule': arms[i].toJson(),
          },
      ],
      'bodyWeightKg': bodyWeightKg,
      'birthYear': birthYear,
      if (params != null) 'params': params.toJson(),
      if (e2Target != null && e2Target.isValid)
        'e2Target': e2Target.normalised.toJson(),
      if (tTarget != null && tTarget.isValid)
        'tTarget': tTarget.normalised.toJson(),
      'maxCycles': maxCycles,
    });
    final raw = await Isolate.run(() => _call('hrt_compare', payload));
    _throwIfError(raw);
    final result = raw['result'];
    return result is Map ? result.cast<String, dynamic>() : null;
  }

  /// The record with one dose changed, against the record as logged.
  ///
  /// `scenarios` accepts the engine's own shapes, for example
  /// `{'kind': 'skipNextDose'}` or `{'kind': 'delayNextDose', 'hours': 12}`.
  /// Nothing at or before `nowH` is altered.
  Future<Map<String, dynamic>?> whatIf({
    required List<DoseEvent> events,
    required double bodyWeightKg,
    double? nowH,
    String analyte = 'e2',
    double? horizonH,
    List<Map<String, Object?>>? scenarios,
    int? birthYear,
    PkParams? params,
    double clearanceMult = 1.0,
    TargetRange? e2Target,
    TargetRange? tTarget,
  }) async {
    if (events.isEmpty) return null;
    final payload = jsonEncode({
      'events': events.map((e) => e.toJson()).toList(),
      'bodyWeightKg': bodyWeightKg,
      'birthYear': birthYear,
      if (params != null) 'params': params.toJson(),
      'nowH': nowH ?? hoursFromDateTime(DateTime.now()),
      'clearanceMult': clearanceMult,
      'analyte': analyte,
      if (horizonH != null) 'horizonH': horizonH,
      if (scenarios != null) 'scenarios': scenarios,
      if (e2Target != null && e2Target.isValid)
        'e2Target': e2Target.normalised.toJson(),
      if (tTarget != null && tTarget.isValid)
        'tTarget': tTarget.normalised.toJson(),
    });
    final raw = await Isolate.run(() => _call('hrt_what_if', payload));
    _throwIfError(raw);
    final result = raw['result'];
    return result is Map ? result.cast<String, dynamic>() : null;
  }

  /// A lab panel read back rather than fitted: in range, moving, overdue.
  Future<Map<String, dynamic>?> labReview({
    required List<LabResult> labs,
    double? nowH,
    TargetRange? e2Target,
    TargetRange? tTarget,
    double? cadenceDays,
  }) async {
    if (labs.isEmpty) return null;
    final payload = jsonEncode({
      'labs': [for (final lab in labs) lab.toJson()],
      'nowH': nowH ?? hoursFromDateTime(DateTime.now()),
      if (e2Target != null && e2Target.isValid)
        'e2Target': e2Target.normalised.toJson(),
      if (tTarget != null && tTarget.isValid)
        'tTarget': tTarget.normalised.toJson(),
      if (cadenceDays != null) 'cadenceDays': cadenceDays,
    });
    final raw = await Isolate.run(() => _call('hrt_lab_review', payload));
    _throwIfError(raw);
    final result = raw['result'];
    return result is Map ? result.cast<String, dynamic>() : null;
  }

  // --- reference and conversion -------------------------------------------
  /// Everything the engine accepts, as data.
  Future<EngineCatalog?> catalog() async {
    final raw = await Isolate.run(() => _call('hrt_catalog', '{}'));
    _throwIfError(raw);
    return EngineCatalog.fromJson(raw['result']);
  }

  Future<ConcentrationConversion?> convertConcentration({
    required double value,
    required String from,
    required String to,
    String? analyte,
  }) async {
    final payload = jsonEncode({
      'kind': 'concentration',
      'value': value,
      'from': from,
      'to': to,
      if (analyte != null) 'analyte': analyte,
    });
    final raw = await Isolate.run(() => _call('hrt_convert', payload));
    _throwIfError(raw);
    return ConcentrationConversion.fromJson(raw['result']);
  }

  /// How much of one ester is the same dose of another, by active hormone.
  Future<DoseConversion?> convertDose({
    required double doseMG,
    required String fromEster,
    String? toEster,
  }) async {
    final payload = jsonEncode({
      'kind': 'dose',
      'doseMG': doseMG,
      'fromEster': fromEster,
      if (toEster != null) 'toEster': toEster,
    });
    final raw = await Isolate.run(() => _call('hrt_convert', payload));
    _throwIfError(raw);
    return DoseConversion.fromJson(raw['result']);
  }

  /// Hold time ↔ mucosal fraction, both directions, plus what it means for
  /// bioavailability.
  Future<SublingualInfo?> sublingual({
    double? holdMin,
    double? theta,
    PkParams? params,
  }) async {
    final payload = jsonEncode({
      if (holdMin != null) 'holdMin': holdMin,
      if (theta != null) 'theta': theta,
      if (params != null) 'params': params.toJson(),
    });
    final raw = await Isolate.run(() => _call('hrt_sublingual', payload));
    _throwIfError(raw);
    return SublingualInfo.fromJson(raw['result']);
  }

  /// Several calls in one crossing of the FFI boundary. Each entry is a full
  /// envelope: one failure does not cancel the rest.
  Future<List<Map<String, dynamic>>> batch(
    List<(String, Map<String, dynamic>)> calls,
  ) async {
    if (calls.isEmpty) return const [];
    final payload = jsonEncode({
      'calls': [
        for (final (function, input) in calls)
          {'function': function, 'input': input},
      ],
    });
    final raw = await Isolate.run(() => _call('hrt_batch', payload));
    _throwIfError(raw);
    final result = raw['result'];
    if (result is! Map) return const [];
    final results = result['results'];
    if (results is! List) return const [];
    return [
      for (final entry in results)
        if (entry is Map) entry.cast<String, dynamic>(),
    ];
  }

  // --- plumbing -----------------------------------------------------------

  static Map<String, dynamic> _common({
    required List<DoseEvent> events,
    required double bodyWeightKg,
    int? birthYear,
    PkParams? params,
    double? nowH,
    double clearanceMult = 1.0,
    double? startH,
    double? endH,
    double? stepH,
    TargetRange? e2Target,
    TargetRange? tTarget,
  }) => {
    'events': events.map((e) => e.toJson()).toList(),
    'bodyWeightKg': bodyWeightKg,
    'birthYear': birthYear,
    'params': (params ?? PkParams()).toJson(),
    'nowH': nowH ?? hoursFromDateTime(DateTime.now()),
    'clearanceMult': clearanceMult,
    if (startH != null) 'startH': startH,
    if (endH != null) 'endH': endH,
    if (stepH != null) 'stepH': stepH,
    if (e2Target != null && e2Target.isValid)
      'e2Target': e2Target.normalised.toJson(),
    if (tTarget != null && tTarget.isValid)
      'tTarget': tTarget.normalised.toJson(),
  };

  static List<SafetyWarning> _warnings(Object? json) {
    if (json is! List) return const [];
    return [
      for (final entry in json)
        if (SafetyWarning.fromJson(entry) case final warning?) warning,
    ];
  }

  /// A rejected payload used to come back as a silent `null`, which looked
  /// exactly like “no doses logged”. Turning it into an error means the
  /// dashboard can say what actually went wrong.
  static void _throwIfError(Map<String, dynamic> raw) {
    if (raw['ok'] == true) return;
    throw HrtEngineException(
      raw['code']?.toString() ?? 'engine',
      raw['error']?.toString() ?? 'unknown engine error',
    );
  }

  /// Runs in a background isolate: JSON in, JSON out.
  static Map<String, dynamic> _call(String symbol, String payload) {
    final lib = _open();
    final fn = lib
        .lookupFunction<
          Pointer<Utf8> Function(Pointer<Utf8>),
          Pointer<Utf8> Function(Pointer<Utf8>)
        >(symbol);
    final input = payload.toNativeUtf8();
    Pointer<Utf8> output = nullptr;
    try {
      output = fn(input);
      final text = output.toDartString();
      final decoded = jsonDecode(text);
      if (decoded is Map<String, dynamic>) return decoded;
      return {'ok': false, 'error': 'unexpected response'};
    } catch (e) {
      return {'ok': false, 'error': e.toString()};
    } finally {
      calloc.free(input);
      if (output != nullptr) _freeString(lib, output);
    }
  }

  static void _freeString(DynamicLibrary lib, Pointer<Utf8> ptr) {
    final free = lib
        .lookupFunction<
          Void Function(Pointer<Utf8>),
          void Function(Pointer<Utf8>)
        >('hrt_free');
    free(ptr);
  }
}
