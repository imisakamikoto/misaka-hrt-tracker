import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

import '../data/models.dart';

/// Dart side of the Rust core.
///
/// The library is a plain `.so` (built with `cargo ndk`) dropped into
/// `android/app/src/main/jniLibs`, so it stays usable from any other Android
/// client later: the ABI is JSON in, JSON out, five symbols, no Dart runtime
/// needed.
class HrtEngine {
  HrtEngine._();

  static final HrtEngine instance = HrtEngine._();

  static const _abiVersion = 1;
  static bool _checked = false;

  /// Opened once per isolate; `dart:ffi` handles are not shareable.
  static DynamicLibrary? _lib;

  static DynamicLibrary _open() {
    final cached = _lib;
    if (cached != null) return cached;

    DynamicLibrary lib;
    if (Platform.isAndroid) {
      lib = DynamicLibrary.open('libhrt_core.so');
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
    if (abi != _abiVersion) {
      throw StateError('PK core ABI $abi, expected $_abiVersion');
    }
    _checked = true;
    _lib = lib;
    return lib;
  }

  static DynamicLibrary _openDesktop(String name) {
    final candidates = [
      'rust/target/release/$name',
      'rust/target/debug/$name',
      '../rust/target/release/$name',
      '../rust/target/debug/$name',
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

  String get version {
    final lib = _open();
    final fn = lib
        .lookupFunction<Pointer<Utf8> Function(), Pointer<Utf8> Function()>(
          'hrt_version',
        );
    final ptr = fn();
    try {
      return (jsonDecode(ptr.toDartString()) as Map)['result'].toString();
    } finally {
      _freeString(lib, ptr);
    }
  }

  Future<SimulationResult?> simulate({
    required List<DoseEvent> events,
    required double bodyWeightKg,
    int? birthYear,
    PkParams? params,
    double? nowH,
    double clearanceMult = 1.0,
  }) async {
    final payload = jsonEncode({
      'events': events.map((e) => e.toJson()).toList(),
      'bodyWeightKg': bodyWeightKg,
      'birthYear': birthYear,
      'params': (params ?? PkParams()).toJson(),
      'nowH': nowH ?? hoursFromDateTime(DateTime.now()),
      'clearanceMult': clearanceMult,
    });
    final raw = await Isolate.run(() => _call('hrt_simulate', payload));
    _throwIfError(raw);
    final result = raw['result'];
    if (result is! Map) return null;
    return SimulationResult.fromJson(result.cast<String, dynamic>());
  }

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

  /// A rejected payload used to come back as a silent `null`, which looked
  /// exactly like “no doses logged”. Turning it into an error means the
  /// dashboard can say what actually went wrong.
  static void _throwIfError(Map<String, dynamic> raw) {
    if (raw['ok'] == true) return;
    throw StateError('${raw['error'] ?? 'unknown engine error'}');
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

  /// Whether the shared library loaded, for the diagnostics row in settings.
  bool get checked => _checked;
}
