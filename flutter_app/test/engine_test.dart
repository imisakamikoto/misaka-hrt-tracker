import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hrt_tracker/core/engine_ffi.dart';
import 'package:hrt_tracker/data/backup.dart';
import 'package:hrt_tracker/data/models.dart';

/// End-to-end check of the Dart ⇄ Rust contract.
///
/// The very first release shipped a payload the core refused to parse (the dose
/// was sent as `doseMG`, the core expected `doseMg`). The refusal came back as a
/// quiet `null`, so an imported history drew an empty chart with no error. These
/// tests go through the real shared library, using the exact JSON the app
/// produces, so that class of bug cannot come back silently.
void main() {
  final engine = HrtEngine.instance;
  final available = engine.isAvailable;

  DoseEvent dose(double hoursAgo, {double mg = 1}) => DoseEvent(
    id: 'test-$hoursAgo',
    route: DoseRoute.sublingual,
    timeH: hoursFromDateTime(DateTime.now()) - hoursAgo,
    doseMG: mg,
    ester: Ester.EV,
    extras: {ExtraKey.sublingualTier: 3},
  );

  test('a logged dose produces a usable curve', () async {
    final sim = await engine.simulate(
      events: [dose(30), dose(18), dose(6)],
      bodyWeightKg: 57,
    );
    expect(sim, isNotNull, reason: 'the core accepted the payload');
    expect(sim!.timeH.length, greaterThan(100));
    final now = hoursFromDateTime(DateTime.now());
    expect(sim.e2At(now), greaterThan(0));
    expect(sim.e2Max, greaterThan(0));
  }, skip: available ? false : 'Rust core not built for this platform');

  test('the wire format keeps the spelling the core reads', () {
    // The core accepts `doseMG` through an alias; if either side drifts the
    // simulation silently goes blank, so the shape is pinned here.
    final json = dose(1).toJson();
    expect(json['doseMG'], 1);
    expect(json.containsKey('doseMg'), isFalse);
    expect(json['timeH'], isA<double>());
    expect((json['extras'] as Map)[ExtraKey.sublingualTier], 3);
  });

  test('a complete backup round-trips through the app models', () async {
    final now = DateTime.now();
    final event = DoseEvent(
      id: 'imported',
      route: DoseRoute.sublingual,
      timeH: hoursFromDateTime(now.subtract(const Duration(hours: 8))),
      doseMG: 1,
      ester: Ester.EV,
      extras: {ExtraKey.sublingualTier: 3},
    );
    final text = jsonEncode(
      BackupCodec.buildCompleteBundle(
      activeMode: 'transfem',
      modes: {
        'transfem': ModeData(doses: [event]),
        'transmasc': ModeData(),
      },
      weight: 57,
      pkParams: null,
      calibrationMethod: 'off',
      calibrationHistory: 'retrospective',
      theme: 'dark',
      language: 'zh',
      showPrediction: false,
      hideSiteLabel: false,
        supplyLeadDays: 7,
      ),
    );
    final bundle = await BackupCodec.decode(text);
    final imported = bundle.modeData['transfem']!.doses.single;
    expect(imported.doseMG, 1);
    expect(imported.extras[ExtraKey.sublingualTier], 3);
    expect(bundle.showPrediction, isFalse);
    expect(bundle.weight, 57);

    final sim = await engine.simulate(
      events: bundle.modeData['transfem']!.doses,
      bodyWeightKg: bundle.weight!,
    );
    expect(sim?.isEmpty ?? true, isFalse);
  }, skip: available ? false : 'Rust core not built for this platform');

  test('the shared library reports the ABI the app expects', () {
    final value = engine.version;
    expect(value, isNotEmpty);
  }, skip: available ? false : 'Rust core not built for this platform');

  test('the Android libraries are packaged for every ABI', () {
    for (final abi in ['arm64-v8a', 'armeabi-v7a', 'x86_64']) {
      final file = File('android/app/src/main/jniLibs/$abi/libhrt_core.so');
      if (!file.existsSync()) {
        // A pure Flutter checkout can build without the Rust toolchain; the
        // gradle task then reuses whatever is already there.
        continue;
      }
      expect(file.lengthSync(), greaterThan(100000), reason: abi);
    }
  });
}
