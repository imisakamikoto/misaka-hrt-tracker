import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cryptography/cryptography.dart';

import 'models.dart';

/// Everything a backup file can be, in the formats the original app wrote.
enum BackupFormat { completeBundle, recordsV2, legacy, encrypted, unknown }

class ImportBundle {
  ImportBundle({
    required this.format,
    required this.modeData,
    this.activeMode,
    this.weight,
    this.birthYear,
    this.pkParams,
    this.calibrationMethod,
    this.calibrationHistory,
    this.theme,
    this.language,
    this.showPrediction,
    this.hideSiteLabel,
    this.supplyLeadDays,
  });

  final BackupFormat format;
  final String? activeMode;
  final Map<String, ModeData> modeData;
  final double? weight;
  final int? birthYear;
  final PkParams? pkParams;
  final String? calibrationMethod;
  final String? calibrationHistory;
  final String? theme;
  final String? language;
  final bool? showPrediction;
  final bool? hideSiteLabel;
  final int? supplyLeadDays;

  int get totalRecords => modeData.values.fold(0, (a, b) => a + b.total);
}

class ModeData {
  ModeData({
    this.doses = const [],
    this.labs = const [],
    this.measurements = const [],
    this.plan = const [],
    this.supplies = const [],
    this.quickDoses = const [],
    this.templates = const [],
  });

  final List<DoseEvent> doses;
  final List<LabResult> labs;
  final List<BodyMeasure> measurements;
  final List<PlanItem> plan;
  final List<Supply> supplies;
  final List<QuickDose> quickDoses;
  final List<DoseTemplate> templates;

  int get total =>
      doses.length +
      labs.length +
      measurements.length +
      plan.length +
      supplies.length +
      quickDoses.length +
      templates.length;

  bool get isEmpty => total == 0;

  Map<String, dynamic> toJson() => {
    'events': doses.map((e) => e.toJson()).toList(),
    'labResults': labs.map((e) => e.toJson()).toList(),
    'bodyMeasurements': measurements.map((e) => e.toJson()).toList(),
    'doseTemplates': templates.map((e) => e.toJson()).toList(),
    'quickDoses': quickDoses.map((e) => e.toJson()).toList(),
    'supplies': supplies.map((e) => e.toJson()).toList(),
    'plan': plan.map((e) => e.toJson()).toList(),
    'deletions': const <String, List<String>>{},
  };
}

class BackupException implements Exception {
  BackupException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Reading and writing the three on-disk shapes, plus the encrypted wrapper.
abstract final class BackupCodec {
  static const completeFormat = 'oyama-hrt-complete-backup';
  static const completeFormatVersion = 1;

  /// Decode any supported file into a normalised bundle.
  ///
  /// Returns [BackupFormat.encrypted] with no data when a password is needed.
  static Future<ImportBundle> decode(String rawText, {String? password}) async {
    final text = rawText.trim();
    if (text.isEmpty) throw BackupException('The file is empty.');

    var payload = _maybeDecompress(text);
    var json = _tryJson(payload);
    if (json == null) throw BackupException('This is not a JSON backup file.');

    // Encrypted envelope: {encrypted:true, iv, salt, iter, data}
    if (json is Map && json['encrypted'] == true) {
      if (password == null || password.isEmpty) {
        return ImportBundle(format: BackupFormat.encrypted, modeData: const {});
      }
      final decrypted = await decrypt(json.cast<String, dynamic>(), password);
      if (decrypted == null) {
        throw BackupException('Wrong password, or the file is damaged.');
      }
      payload = decrypted;
      json = _tryJson(payload);
      if (json == null)
        throw BackupException('Decrypted contents are not valid JSON.');
    }

    if (json is List) {
      final doses = <DoseEvent>[];
      for (final item in json) {
        if (item is Map) {
          final event = DoseEvent.fromJson(item.cast<String, dynamic>());
          if (event != null) doses.add(event);
        }
      }
      if (doses.isEmpty)
        throw BackupException(
          'The file has no doses this version understands.',
        );
      return ImportBundle(
        format: BackupFormat.legacy,
        modeData: {'transfem': ModeData(doses: doses)},
      );
    }

    if (json is! Map) throw BackupException('Unrecognised backup layout.');
    final map = json.cast<String, dynamic>();

    if (map['format'] == completeFormat) return _decodeComplete(map);
    if (map['meta'] is Map || map['modes'] is Map || map['events'] is List)
      return _decodeRecords(map);

    // A bare {events, labResults} object, or a single-mode export.
    if (map.containsKey('events') || map.containsKey('labResults'))
      return _decodeRecords(map);

    throw BackupException('Unrecognised backup layout.');
  }

  static String _maybeDecompress(String text) {
    // Some exports are gzip+base64 to keep the file small. A plausible base64
    // payload is tried and, if the gunzip fails, treated as plain text.
    if (text.startsWith('{') || text.startsWith('[')) return text;
    try {
      final bytes = base64.decode(text.replaceAll(RegExp(r'\s'), ''));
      if (bytes.length > 2 && bytes[0] == 0x1f && bytes[1] == 0x8b) {
        return utf8.decode(gzip.decode(bytes));
      }
    } catch (_) {}
    return text;
  }

  static Object? _tryJson(String text) {
    try {
      return jsonDecode(text);
    } catch (_) {
      return null;
    }
  }

  static ImportBundle _decodeComplete(Map<String, dynamic> map) {
    final modes = <String, ModeData>{};
    final rawModes = map['modes'];
    if (rawModes is Map) {
      for (final entry in rawModes.entries) {
        final block = entry.value;
        if (block is Map) {
          modes[entry.key.toString()] = _modeFromMap(
            block.cast<String, dynamic>(),
          );
        }
      }
    }

    final calibration = map['calibration'];
    final preferences = map['preferences'];
    return ImportBundle(
      format: BackupFormat.completeBundle,
      activeMode: _modeName(map['mode']),
      modeData: modes,
      weight: _num(map['weight']),
      pkParams: map['pkParams'] is Map
          ? PkParams.fromJson((map['pkParams'] as Map).cast<String, dynamic>())
          : null,
      calibrationMethod: calibration is Map
          ? calibration['method']?.toString()
          : null,
      calibrationHistory: calibration is Map
          ? calibration['historyMode']?.toString()
          : null,
      theme: preferences is Map ? preferences['app-theme']?.toString() : null,
      language: preferences is Map ? preferences['hrt-lang']?.toString() : null,
      showPrediction: preferences is Map
          ? preferences['app-show-prediction'] as bool?
          : null,
      hideSiteLabel: preferences is Map
          ? preferences['app-hide-site-label'] as bool?
          : null,
      supplyLeadDays: preferences is Map
          ? _num(preferences['hrt-supply-lead-days'])?.round()
          : null,
    );
  }

  static ImportBundle _decodeRecords(Map<String, dynamic> map) {
    final mode = _modeName(map['mode']) ?? 'transfem';
    final modes = <String, ModeData>{};
    final rawModes = map['modes'];
    if (rawModes is Map) {
      for (final entry in rawModes.entries) {
        final block = entry.value;
        if (block is Map) {
          modes[entry.key.toString()] = _modeFromMap(
            block.cast<String, dynamic>(),
          );
        }
      }
    }
    if (!modes.containsKey(mode)) {
      modes[mode] = _modeFromMap(map);
    }
    return ImportBundle(
      format: BackupFormat.recordsV2,
      activeMode: mode,
      modeData: modes,
      weight: _num(map['weight']),
      birthYear: _num(map['birthYear'])?.round(),
      pkParams: map['pkParams'] is Map
          ? PkParams.fromJson((map['pkParams'] as Map).cast<String, dynamic>())
          : null,
    );
  }

  static String? _modeName(Object? raw) {
    if (raw == 'transfem' || raw == 'transmasc') return raw as String;
    return null;
  }

  static ModeData _modeFromMap(Map<String, dynamic> map) {
    List<T> parse<T>(Object? raw, T? Function(Map<String, dynamic>) f) {
      final out = <T>[];
      if (raw is List) {
        for (final item in raw) {
          if (item is Map) {
            final value = f(item.cast<String, dynamic>());
            if (value != null) out.add(value);
          }
        }
      }
      return out;
    }

    return ModeData(
      doses: parse(map['events'], DoseEvent.fromJson),
      labs: parse(map['labResults'], LabResult.fromJson),
      measurements: parse(map['bodyMeasurements'], BodyMeasure.fromJson),
      plan: parse(map['plan'], PlanItem.fromJson),
      supplies: parse(map['supplies'], Supply.fromJson),
      quickDoses: parse(map['quickDoses'], QuickDose.fromJson),
      templates: parse(map['doseTemplates'], DoseTemplate.fromJson),
    );
  }

  // --- writing -----------------------------------------------------------

  static Map<String, dynamic> buildCompleteBundle({
    required String activeMode,
    required Map<String, ModeData> modes,
    required double weight,
    required PkParams? pkParams,
    required String calibrationMethod,
    required String calibrationHistory,
    required String theme,
    required String language,
    required bool showPrediction,
    required bool hideSiteLabel,
    required int supplyLeadDays,
  }) {
    final now = DateTime.now().toUtc().toIso8601String();
    return {
      'format': completeFormat,
      'formatVersion': completeFormatVersion,
      'createdAt': now,
      'mode': activeMode,
      'modes': {
        for (final mode in ['transfem', 'transmasc'])
          mode: (modes[mode] ?? ModeData()).toJson(),
      },
      'weight': weight,
      if (pkParams != null) 'pkParams': pkParams.toJson(),
      'calibration': {
        'method': calibrationMethod,
        'historyMode': calibrationHistory,
      },
      'preferences': {
        'app-theme': theme,
        'hrt-lang': language,
        'app-show-prediction': showPrediction,
        'app-hide-site-label': hideSiteLabel,
        'hrt-supply-lead-days': supplyLeadDays,
      },
    };
  }

  static Map<String, dynamic> buildRecordsV2({
    required String mode,
    required ModeData active,
    required Map<String, ModeData> modes,
    required double weight,
    required int? birthYear,
    required PkParams? pkParams,
  }) {
    return {
      'meta': {
        'version': 2,
        'exportedAt': DateTime.now().toUtc().toIso8601String(),
      },
      'mode': mode,
      'weight': weight,
      'birthYear': birthYear,
      'modes': {
        for (final key in ['transfem', 'transmasc'])
          key: {
            'events': (modes[key] ?? ModeData()).doses
                .map((e) => e.toJson())
                .toList(),
            'labResults': (modes[key] ?? ModeData()).labs
                .map((e) => e.toJson())
                .toList(),
            'doseTemplates': (modes[key] ?? ModeData()).templates
                .map((e) => e.toJson())
                .toList(),
            'deletions': const <String, List<String>>{},
          },
      },
      'events': active.doses.map((e) => e.toJson()).toList(),
      'labResults': active.labs.map((e) => e.toJson()).toList(),
      'doseTemplates': active.templates.map((e) => e.toJson()).toList(),
      'pkParams': pkParams?.toJson(),
    };
  }

  /// Encrypt a UTF-8 payload exactly as the original app did: PBKDF2-SHA256
  /// with 600 000 iterations, then AES-256-GCM with a 12-byte nonce.
  static Future<String> encrypt(String plaintext, String password) async {
    final salt = _randomBytes(16);
    final iv = _randomBytes(12);
    const iterations = 600000;
    final pbkdf2 = Pbkdf2(
      macAlgorithm: Hmac.sha256(),
      iterations: iterations,
      bits: 256,
    );
    final key = await pbkdf2.deriveKeyFromPassword(
      password: password,
      nonce: salt,
    );
    final box = await AesGcm.with256bits().encrypt(
      utf8.encode(plaintext),
      secretKey: key,
      nonce: iv,
    );
    final cipherAndTag = box.concatenation(nonce: false, mac: true);
    return jsonEncode({
      'encrypted': true,
      'iv': base64.encode(iv),
      'salt': base64.encode(salt),
      'iter': iterations,
      'data': base64.encode(cipherAndTag),
    });
  }

  /// Decrypt the envelope; null when the password is wrong.
  static Future<String?> decrypt(
    Map<String, dynamic> envelope,
    String password,
  ) async {
    try {
      final salt = base64.decode(envelope['salt'] as String);
      final iv = base64.decode(envelope['iv'] as String);
      final data = base64.decode(envelope['data'] as String);
      final declared = envelope['iter'];
      final iterations =
          (declared is int && declared >= 100000 && declared <= 1000000)
          ? declared
          : 100000;
      final pbkdf2 = Pbkdf2(
        macAlgorithm: Hmac.sha256(),
        iterations: iterations,
        bits: 256,
      );
      final key = await pbkdf2.deriveKeyFromPassword(
        password: password,
        nonce: salt,
      );
      final box = SecretBox(
        data.sublist(0, data.length - 16),
        nonce: iv,
        mac: Mac(data.sublist(data.length - 16)),
      );
      final clear = await AesGcm.with256bits().decrypt(box, secretKey: key);
      return utf8.decode(clear);
    } catch (_) {
      return null;
    }
  }

  static List<int> _randomBytes(int length) {
    final rnd = Random.secure();
    return List<int>.generate(length, (_) => rnd.nextInt(256));
  }
}

double? _num(Object? v) {
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v);
  return null;
}
