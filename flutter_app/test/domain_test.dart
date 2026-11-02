import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:hrt_tracker/core/domain.dart';
import 'package:hrt_tracker/core/l10n.dart';
import 'package:hrt_tracker/data/backup.dart';
import 'package:hrt_tracker/data/models.dart';

PlanItem _plan({
  String id = 'p1',
  DoseRoute route = DoseRoute.injection,
  Ester ester = Ester.EV,
  double dose = 5,
  double everyDays = 1,
  int timesPerDay = 1,
}) => PlanItem(
  id: id,
  route: route,
  ester: ester,
  doseMG: dose,
  everyDays: everyDays,
  timesPerDay: timesPerDay,
);

DoseEvent _dose(
  DateTime at, {
  Ester ester = Ester.EV,
  DoseRoute route = DoseRoute.injection,
  double mg = 5,
}) => DoseEvent(
  id: 'd-${at.millisecondsSinceEpoch}',
  route: route,
  timeH: hoursFromDateTime(at),
  doseMG: mg,
  ester: ester,
);

void main() {
  group('calendar days', () {
    test('a day number round-trips through local midnight', () {
      final day = DateTime(2026, 3, 8, 23, 40);
      final number = localDay(day);
      final back = dayFromNumber(number);
      expect(back.year, 2026);
      expect(back.month, 3);
      expect(back.day, 8);
      expect(back.hour, 0);
    });

    test('hours from the database land on the right day', () {
      final at = DateTime(2026, 11, 2, 9, 30);
      expect(dayNumberFromHours(hoursFromDateTime(at)), localDay(at));
    });
  });

  group('today', () {
    test('a daily plan is due once and not yet taken', () {
      final now = DateTime(2026, 11, 2, 12);
      final today = todayDoses(plan: [_plan()], doses: const [], now: now);
      expect(today, hasLength(1));
      expect(today.first.isDoseDay, isTrue);
      expect(today.first.due, 1);
      expect(today.first.taken, 0);
      expect(today.first.isDone, isFalse);
    });

    test('a logged dose marks the plan line done', () {
      final now = DateTime(2026, 11, 2, 12);
      final today = todayDoses(
        plan: [_plan()],
        doses: [_dose(DateTime(2026, 11, 2, 9))],
        now: now,
      );
      expect(today.first.taken, 1);
      expect(today.first.isDone, isTrue);
    });

    test('twice a day needs two doses', () {
      final now = DateTime(2026, 11, 2, 20);
      final today = todayDoses(
        plan: [
          _plan(
            route: DoseRoute.sublingual,
            ester: Ester.E2,
            dose: 1,
            timesPerDay: 2,
          ),
        ],
        doses: [
          _dose(
            DateTime(2026, 11, 2, 9),
            ester: Ester.E2,
            route: DoseRoute.sublingual,
            mg: 1,
          ),
        ],
        now: now,
      );
      expect(today.first.due, 2);
      expect(today.first.taken, 1);
      expect(today.first.isDone, isFalse);
      expect(today.first.isPartial, isTrue);
    });

    test('an every-other-day plan skips the day after the anchor', () {
      final anchor = DateTime(2026, 11, 1, 9);
      final tomorrow = DateTime(2026, 11, 2, 12);
      final today = todayDoses(
        plan: [_plan(everyDays: 2)],
        doses: [_dose(anchor)],
        now: tomorrow,
      );
      expect(today.first.isDoseDay, isFalse);
      expect(today.first.due, 0);
    });
  });

  group('projection', () {
    test('future doses stay inside the requested window', () {
      final from = DateTime(2026, 11, 2, 10);
      final to = from.add(const Duration(days: 7));
      final events = futurePlanDoses([_plan()], from, to);
      expect(events, isNotEmpty);
      for (final event in events) {
        expect(event.time.isAfter(from), isTrue);
        expect(event.time.isAfter(to), isFalse);
      }
      expect(events.length, inInclusiveRange(6, 8));
    });

    test('the next dose is the first one not yet logged', () {
      final now = DateTime(2026, 11, 2, 12);
      final next = nextDoseAt(
        [_plan()],
        [_dose(DateTime(2026, 11, 2, 9))],
        now,
      );
      expect(next, isNotNull);
      expect(next!.isAfter(now), isTrue);
    });
  });

  group('supplies', () {
    test('a full vial lasts as long as the plan says', () {
      final supply = Supply(
        id: 's1',
        route: DoseRoute.injection,
        ester: Ester.EV,
        pack: const VialPack(ml: 10, mgPerMl: 10),
        count: 1,
        startedAt: DateTime(2026, 10, 1).millisecondsSinceEpoch,
      );
      final status = supplyStatus(supply, const [], [
        _plan(dose: 2),
      ], DateTime(2026, 11, 2));
      expect(status.remaining, closeTo(100, 0.001));
      expect(status.daysLeft, closeTo(50, 0.001));
      expect(status.runOut, isNotNull);
    });

    test('logged doses eat into the remaining amount', () {
      final start = DateTime(2026, 10, 1);
      final supply = Supply(
        id: 's2',
        route: DoseRoute.injection,
        ester: Ester.EV,
        pack: const VialPack(ml: 10, mgPerMl: 10),
        count: 1,
        startedAt: start.millisecondsSinceEpoch,
      );
      final status = supplyStatus(
        supply,
        [
          _dose(start.add(const Duration(days: 1))),
          _dose(start.add(const Duration(days: 8))),
        ],
        const [],
        DateTime(2026, 11, 2),
      );
      expect(status.remaining, closeTo(90, 0.001));
    });
  });

  group('advisory', () {
    test('a large estradiol injection is flagged', () {
      final now = DateTime(2026, 11, 2, 12);
      final warning = doseAdvisory([
        _dose(DateTime(2026, 11, 2, 9), mg: 40),
      ], now);
      expect(warning, isNotNull);
      expect(warning!.kind, 'e2');
    });

    test('a normal dose is not', () {
      final now = DateTime(2026, 11, 2, 12);
      expect(
        doseAdvisory([_dose(DateTime(2026, 11, 2, 9), mg: 5)], now),
        isNull,
      );
    });
  });

  group('backup', () {
    test('a complete bundle decodes into both modes', () async {
      final raw = jsonEncode({
        'format': 'oyama-hrt-complete-backup',
        'formatVersion': 1,
        'mode': 'transmasc',
        'modes': {
          'transfem': {
            'events': [_dose(DateTime(2026, 10, 5, 9)).toJson()],
            'labResults': <Object>[],
          },
          'transmasc': {'events': <Object>[], 'labResults': <Object>[]},
        },
        'weight': 82.5,
        'calibration': {'method': 'ekf', 'historyMode': 'forward'},
        'preferences': {'app-theme': 'dark', 'hrt-lang': 'zh-Hans'},
      });
      final bundle = await BackupCodec.decode(raw);
      expect(bundle.format, BackupFormat.completeBundle);
      expect(bundle.activeMode, 'transmasc');
      expect(bundle.weight, 82.5);
      expect(bundle.calibrationMethod, 'ekf');
      expect(bundle.language, 'zh-Hans');
      expect(bundle.modeData['transfem']!.doses, hasLength(1));
    });

    test('a legacy array of doses is accepted', () async {
      final raw = jsonEncode([
        _dose(DateTime(2026, 10, 5, 9)).toJson(),
        _dose(DateTime(2026, 10, 8, 9)).toJson(),
      ]);
      final bundle = await BackupCodec.decode(raw);
      expect(bundle.format, BackupFormat.legacy);
      expect(bundle.modeData['transfem']!.doses, hasLength(2));
    });

    test('an encrypted file asks for a password instead of failing', () async {
      final raw = jsonEncode({
        'encrypted': true,
        'iv': 'AAAA',
        'salt': 'AAAA',
        'iter': 600000,
        'data': 'AAAA',
      });
      final bundle = await BackupCodec.decode(raw);
      expect(bundle.format, BackupFormat.encrypted);
      expect(bundle.modeData, isEmpty);
    });
  });

  group('strings', () {
    test('every language names the app the same way', () {
      for (final lang in L10n.languages.keys) {
        expect(L10n(lang).t('app.name'), 'Misaka hrt记录器');
      }
    });

    test('an unknown key falls back to the key itself', () {
      expect(L10n('en').t('nothing.here'), 'nothing.here');
    });
  });
}
