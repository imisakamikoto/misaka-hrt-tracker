// Throwaway diagnostic: decodes a backup file with the app's own codec and
// prints what the UI would end up with.
//
//   dart run tool/decode_check.dart ~/Downloads/hrt-complete-backup.json
import 'dart:io';

import 'package:hrt_tracker/data/backup.dart';

Future<void> main(List<String> args) async {
  final path = args.isEmpty ? '' : args.first;
  if (path.isEmpty) {
    stderr.writeln('usage: dart run tool/decode_check.dart <file>');
    exit(2);
  }
  final raw = File(path).readAsStringSync();
  final bundle = await BackupCodec.decode(raw);
  print('format=${bundle.format} mode=${bundle.activeMode} '
      'weight=${bundle.weight} year=${bundle.birthYear}');
  print('calibration=${bundle.calibrationMethod}/${bundle.calibrationHistory} '
      'theme=${bundle.theme} lang=${bundle.language} '
      'showPrediction=${bundle.showPrediction}');
  for (final entry in bundle.modeData.entries) {
    final d = entry.value;
    print('${entry.key}: doses=${d.doses.length} labs=${d.labs.length} '
        'plan=${d.plan.length} supplies=${d.supplies.length} '
        'quick=${d.quickDoses.length} templates=${d.templates.length}');
    if (d.doses.isNotEmpty) {
      final last = d.doses.reduce((a, b) => a.timeH >= b.timeH ? a : b);
      print('  last dose ${last.time.toLocal()} ${last.route.code} '
          '${last.doseMG}mg ${last.ester.code} extras=${last.extras}');
    }
    for (final s in d.supplies) {
      print('  supply ${s.pack.runtimeType} count=${s.count}');
    }
    for (final p in d.plan) {
      print('  plan ${p.route.code} ${p.doseMG}mg every ${p.everyDays}d '
          'x${p.timesPerDay}');
    }
  }
}
