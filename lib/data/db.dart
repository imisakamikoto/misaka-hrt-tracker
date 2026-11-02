import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import 'models.dart';

/// Local, on-device storage. There is no server and no account: a single
/// SQLite file holds everything, and it is included in Android's backup rules
/// only if the person exports a file themselves.
class AppDatabase {
  AppDatabase._(this._db);

  final Database _db;
  static AppDatabase? _instance;

  static Future<AppDatabase> open() async {
    final existing = _instance;
    if (existing != null) return existing;
    final dir = await getDatabasesPath();
    final path = p.join(dir, 'hrt_tracker.db');
    final db = await openDatabase(
      path,
      version: 1,
      onConfigure: (db) async {
        await db.execute('PRAGMA foreign_keys = ON');
      },
      onCreate: (db, version) async {
        final batch = db.batch();
        batch.execute('''
          CREATE TABLE doses(
            id TEXT PRIMARY KEY,
            mode TEXT NOT NULL,
            route TEXT NOT NULL,
            time_h REAL NOT NULL,
            dose_mg REAL NOT NULL,
            ester TEXT NOT NULL,
            extras TEXT NOT NULL DEFAULT '{}',
            updated_at INTEGER
          )
        ''');
        batch.execute(
          'CREATE INDEX idx_doses_mode_time ON doses(mode, time_h)',
        );
        batch.execute('''
          CREATE TABLE labs(
            id TEXT PRIMARY KEY,
            mode TEXT NOT NULL,
            time_h REAL NOT NULL,
            conc_value REAL NOT NULL,
            unit TEXT NOT NULL,
            assay TEXT,
            updated_at INTEGER
          )
        ''');
        batch.execute('CREATE INDEX idx_labs_mode_time ON labs(mode, time_h)');
        batch.execute('''
          CREATE TABLE plan_items(
            id TEXT PRIMARY KEY,
            mode TEXT NOT NULL,
            route TEXT NOT NULL,
            ester TEXT NOT NULL,
            dose_mg REAL NOT NULL,
            extras TEXT NOT NULL DEFAULT '{}',
            every_days REAL NOT NULL,
            times_per_day INTEGER NOT NULL,
            sort INTEGER NOT NULL DEFAULT 0
          )
        ''');
        batch.execute('''
          CREATE TABLE supplies(
            id TEXT PRIMARY KEY,
            mode TEXT NOT NULL,
            route TEXT NOT NULL,
            ester TEXT NOT NULL,
            pack TEXT NOT NULL,
            count REAL NOT NULL,
            started_at INTEGER NOT NULL
          )
        ''');
        batch.execute('''
          CREATE TABLE quick_doses(
            id TEXT PRIMARY KEY,
            mode TEXT NOT NULL,
            route TEXT NOT NULL,
            ester TEXT NOT NULL,
            value REAL NOT NULL,
            created_at INTEGER NOT NULL
          )
        ''');
        batch.execute('''
          CREATE TABLE templates(
            id TEXT PRIMARY KEY,
            mode TEXT NOT NULL,
            name TEXT NOT NULL,
            route TEXT NOT NULL,
            ester TEXT NOT NULL,
            dose_mg REAL NOT NULL,
            extras TEXT NOT NULL DEFAULT '{}',
            created_at INTEGER NOT NULL,
            updated_at INTEGER
          )
        ''');
        batch.execute(
          'CREATE TABLE settings(key TEXT PRIMARY KEY, value TEXT NOT NULL)',
        );
        batch.execute('''
          CREATE TABLE tombstones(
            kind TEXT NOT NULL,
            id TEXT NOT NULL,
            mode TEXT NOT NULL,
            deleted_at INTEGER NOT NULL,
            PRIMARY KEY(kind, id, mode)
          )
        ''');
        await batch.commit(noResult: true);
      },
    );
    _instance = AppDatabase._(db);
    return _instance!;
  }

  Database get raw => _db;

  // --- settings ----------------------------------------------------------

  Future<Map<String, dynamic>> loadSettings() async {
    final rows = await _db.query('settings');
    final out = <String, dynamic>{};
    for (final row in rows) {
      final key = row['key'] as String;
      try {
        out[key] = jsonDecode(row['value'] as String);
      } catch (_) {
        out[key] = row['value'];
      }
    }
    return out;
  }

  Future<void> setSetting(String key, Object? value) async {
    await _db.insert('settings', {
      'key': key,
      'value': jsonEncode(value),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> removeSetting(String key) async {
    await _db.delete('settings', where: 'key = ?', whereArgs: [key]);
  }

  // --- doses -------------------------------------------------------------

  Future<List<DoseEvent>> loadDoses(String mode) async {
    final rows = await _db.query(
      'doses',
      where: 'mode = ?',
      whereArgs: [mode],
      orderBy: 'time_h ASC',
    );
    final out = <DoseEvent>[];
    for (final row in rows) {
      final event = _doseFromRow(row);
      if (event != null) out.add(event);
    }
    return out;
  }

  DoseEvent? _doseFromRow(Map<String, Object?> row) {
    final route = DoseRoute.tryParse(row['route'] as String?);
    final ester = Ester.tryParse(row['ester'] as String?);
    if (route == null || ester == null) return null;
    Map<String, double> extras = {};
    try {
      final decoded = jsonDecode((row['extras'] as String?) ?? '{}');
      if (decoded is Map) {
        for (final e in decoded.entries) {
          final v = e.value;
          if (v is num && v.toDouble().isFinite)
            extras[e.key.toString()] = v.toDouble();
        }
      }
    } catch (_) {}
    return DoseEvent(
      id: row['id'] as String,
      route: route,
      timeH: (row['time_h'] as num).toDouble(),
      doseMG: (row['dose_mg'] as num).toDouble(),
      ester: ester,
      extras: extras,
      updatedAt: (row['updated_at'] as num?)?.toInt(),
    );
  }

  Future<void> upsertDose(String mode, DoseEvent event) async {
    await _db.insert('doses', {
      'id': event.id,
      'mode': mode,
      'route': event.route.code,
      'time_h': event.timeH,
      'dose_mg': event.doseMG,
      'ester': event.ester.code,
      'extras': jsonEncode(event.extras),
      'updated_at': event.updatedAt ?? DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> deleteDose(String mode, String id) async {
    await _db.delete(
      'doses',
      where: 'id = ? AND mode = ?',
      whereArgs: [id, mode],
    );
    await _addTombstone('dose', id, mode);
  }

  // --- labs --------------------------------------------------------------

  Future<List<LabResult>> loadLabs(String mode) async {
    final rows = await _db.query(
      'labs',
      where: 'mode = ?',
      whereArgs: [mode],
      orderBy: 'time_h ASC',
    );
    final out = <LabResult>[];
    for (final row in rows) {
      final unit = LabUnit.tryParse(row['unit'] as String?);
      if (unit == null) continue;
      out.add(
        LabResult(
          id: row['id'] as String,
          timeH: (row['time_h'] as num).toDouble(),
          concValue: (row['conc_value'] as num).toDouble(),
          unit: unit,
          assay: row['assay'] as String?,
          updatedAt: (row['updated_at'] as num?)?.toInt(),
        ),
      );
    }
    return out;
  }

  Future<void> upsertLab(String mode, LabResult lab) async {
    await _db.insert('labs', {
      'id': lab.id,
      'mode': mode,
      'time_h': lab.timeH,
      'conc_value': lab.concValue,
      'unit': lab.unit.code,
      'assay': lab.assay,
      'updated_at': lab.updatedAt ?? DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> deleteLab(String mode, String id) async {
    await _db.delete(
      'labs',
      where: 'id = ? AND mode = ?',
      whereArgs: [id, mode],
    );
    await _addTombstone('lab', id, mode);
  }

  // --- plan --------------------------------------------------------------

  Future<List<PlanItem>> loadPlan(String mode) async {
    final rows = await _db.query(
      'plan_items',
      where: 'mode = ?',
      whereArgs: [mode],
      orderBy: 'sort ASC',
    );
    final out = <PlanItem>[];
    for (final row in rows) {
      final route = DoseRoute.tryParse(row['route'] as String?);
      final ester = Ester.tryParse(row['ester'] as String?);
      if (route == null || ester == null) continue;
      final extras = <String, double>{};
      try {
        final decoded = jsonDecode((row['extras'] as String?) ?? '{}');
        if (decoded is Map) {
          for (final e in decoded.entries) {
            final v = e.value;
            if (v is num) extras[e.key.toString()] = v.toDouble();
          }
        }
      } catch (_) {}
      out.add(
        PlanItem(
          id: row['id'] as String,
          route: route,
          ester: ester,
          doseMG: (row['dose_mg'] as num).toDouble(),
          extras: extras,
          everyDays: (row['every_days'] as num).toDouble(),
          timesPerDay: (row['times_per_day'] as num).toInt(),
        ),
      );
    }
    return out;
  }

  Future<void> replacePlan(String mode, List<PlanItem> items) async {
    await _db.transaction((txn) async {
      await txn.delete('plan_items', where: 'mode = ?', whereArgs: [mode]);
      for (var i = 0; i < items.length; i++) {
        final item = items[i];
        await txn.insert('plan_items', {
          'id': item.id,
          'mode': mode,
          'route': item.route.code,
          'ester': item.ester.code,
          'dose_mg': item.doseMG,
          'extras': jsonEncode(item.extras),
          'every_days': item.everyDays,
          'times_per_day': item.timesPerDay,
          'sort': i,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
    });
  }

  // --- supplies ----------------------------------------------------------

  Future<List<Supply>> loadSupplies(String mode) async {
    final rows = await _db.query(
      'supplies',
      where: 'mode = ?',
      whereArgs: [mode],
    );
    final out = <Supply>[];
    for (final row in rows) {
      final route = DoseRoute.tryParse(row['route'] as String?);
      final ester = Ester.tryParse(row['ester'] as String?);
      if (route == null || ester == null) continue;
      Pack? pack;
      try {
        final decoded = jsonDecode(row['pack'] as String);
        if (decoded is Map)
          pack = Pack.fromJson(decoded.cast<String, dynamic>());
      } catch (_) {}
      if (pack == null) continue;
      out.add(
        Supply(
          id: row['id'] as String,
          route: route,
          ester: ester,
          pack: pack,
          count: (row['count'] as num).toDouble(),
          startedAt: (row['started_at'] as num).toInt(),
        ),
      );
    }
    return out;
  }

  Future<void> upsertSupply(String mode, Supply supply) async {
    await _db.insert('supplies', {
      'id': supply.id,
      'mode': mode,
      'route': supply.route.code,
      'ester': supply.ester.code,
      'pack': jsonEncode(supply.pack.toJson()),
      'count': supply.count,
      'started_at': supply.startedAt,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> deleteSupply(String mode, String id) async {
    await _db.delete(
      'supplies',
      where: 'id = ? AND mode = ?',
      whereArgs: [id, mode],
    );
  }

  // --- quick doses -------------------------------------------------------

  Future<List<QuickDose>> loadQuickDoses(String mode) async {
    final rows = await _db.query(
      'quick_doses',
      where: 'mode = ?',
      whereArgs: [mode],
      orderBy: 'created_at ASC',
    );
    final out = <QuickDose>[];
    for (final row in rows) {
      final route = DoseRoute.tryParse(row['route'] as String?);
      final ester = Ester.tryParse(row['ester'] as String?);
      if (route == null || ester == null) continue;
      out.add(
        QuickDose(
          id: row['id'] as String,
          route: route,
          ester: ester,
          value: (row['value'] as num).toDouble(),
          createdAt: (row['created_at'] as num).toInt(),
        ),
      );
    }
    return out;
  }

  Future<void> replaceQuickDoses(String mode, List<QuickDose> items) async {
    await _db.transaction((txn) async {
      await txn.delete('quick_doses', where: 'mode = ?', whereArgs: [mode]);
      for (final item in items) {
        await txn.insert('quick_doses', {
          'id': item.id,
          'mode': mode,
          'route': item.route.code,
          'ester': item.ester.code,
          'value': item.value,
          'created_at': item.createdAt,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
    });
  }

  // --- templates ---------------------------------------------------------

  Future<List<DoseTemplate>> loadTemplates(String mode) async {
    final rows = await _db.query(
      'templates',
      where: 'mode = ?',
      whereArgs: [mode],
      orderBy: 'created_at ASC',
    );
    final out = <DoseTemplate>[];
    for (final row in rows) {
      final route = DoseRoute.tryParse(row['route'] as String?);
      final ester = Ester.tryParse(row['ester'] as String?);
      if (route == null || ester == null) continue;
      final extras = <String, double>{};
      try {
        final decoded = jsonDecode((row['extras'] as String?) ?? '{}');
        if (decoded is Map) {
          for (final e in decoded.entries) {
            final v = e.value;
            if (v is num) extras[e.key.toString()] = v.toDouble();
          }
        }
      } catch (_) {}
      out.add(
        DoseTemplate(
          id: row['id'] as String,
          name: row['name'] as String,
          route: route,
          ester: ester,
          doseMG: (row['dose_mg'] as num).toDouble(),
          extras: extras,
          createdAt: (row['created_at'] as num).toInt(),
          updatedAt: (row['updated_at'] as num?)?.toInt(),
        ),
      );
    }
    return out;
  }

  Future<void> upsertTemplate(String mode, DoseTemplate t) async {
    await _db.insert('templates', {
      'id': t.id,
      'mode': mode,
      'name': t.name,
      'route': t.route.code,
      'ester': t.ester.code,
      'dose_mg': t.doseMG,
      'extras': jsonEncode(t.extras),
      'created_at': t.createdAt,
      'updated_at': t.updatedAt ?? DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> deleteTemplate(String mode, String id) async {
    await _db.delete(
      'templates',
      where: 'id = ? AND mode = ?',
      whereArgs: [id, mode],
    );
  }

  // --- tombstones --------------------------------------------------------

  Future<void> _addTombstone(String kind, String id, String mode) async {
    await _db.insert('tombstones', {
      'kind': kind,
      'id': id,
      'mode': mode,
      'deleted_at': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> clearAll() async {
    await _db.transaction((txn) async {
      for (final table in [
        'doses',
        'labs',
        'plan_items',
        'supplies',
        'quick_doses',
        'templates',
        'tombstones',
      ]) {
        await txn.delete(table);
      }
    });
  }

  /// Bulk write used by import: everything is validated before this runs.
  Future<void> applyImport({
    required String mode,
    List<DoseEvent>? doses,
    List<LabResult>? labs,
    List<PlanItem>? plan,
    List<Supply>? supplies,
    List<QuickDose>? quickDoses,
    List<DoseTemplate>? templates,
    bool replace = false,
  }) async {
    await _db.transaction((txn) async {
      Future<void> put(
        String table,
        List<Map<String, Object?>> rows,
        List<String> ids,
      ) async {
        for (final row in rows) {
          await txn.insert(
            table,
            row,
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
        if (replace) {
          if (ids.isEmpty) {
            await txn.delete(table, where: 'mode = ?', whereArgs: [mode]);
          } else {
            final placeholders = List.filled(ids.length, '?').join(',');
            await txn.delete(
              table,
              where: 'mode = ? AND id NOT IN ($placeholders)',
              whereArgs: [mode, ...ids],
            );
          }
        }
      }

      if (doses != null) {
        await put(
          'doses',
          doses
              .map(
                (e) => <String, Object?>{
                  'id': e.id,
                  'mode': mode,
                  'route': e.route.code,
                  'time_h': e.timeH,
                  'dose_mg': e.doseMG,
                  'ester': e.ester.code,
                  'extras': jsonEncode(e.extras),
                  'updated_at':
                      e.updatedAt ?? DateTime.now().millisecondsSinceEpoch,
                },
              )
              .toList(),
          doses.map((e) => e.id).toList(),
        );
      }
      if (labs != null) {
        await put(
          'labs',
          labs
              .map(
                (l) => <String, Object?>{
                  'id': l.id,
                  'mode': mode,
                  'time_h': l.timeH,
                  'conc_value': l.concValue,
                  'unit': l.unit.code,
                  'assay': l.assay,
                  'updated_at':
                      l.updatedAt ?? DateTime.now().millisecondsSinceEpoch,
                },
              )
              .toList(),
          labs.map((l) => l.id).toList(),
        );
      }
      if (plan != null) {
        await txn.delete('plan_items', where: 'mode = ?', whereArgs: [mode]);
        for (var i = 0; i < plan.length; i++) {
          final item = plan[i];
          await txn.insert('plan_items', {
            'id': item.id,
            'mode': mode,
            'route': item.route.code,
            'ester': item.ester.code,
            'dose_mg': item.doseMG,
            'extras': jsonEncode(item.extras),
            'every_days': item.everyDays,
            'times_per_day': item.timesPerDay,
            'sort': i,
          }, conflictAlgorithm: ConflictAlgorithm.replace);
        }
      }
      if (supplies != null) {
        await put(
          'supplies',
          supplies
              .map(
                (s) => <String, Object?>{
                  'id': s.id,
                  'mode': mode,
                  'route': s.route.code,
                  'ester': s.ester.code,
                  'pack': jsonEncode(s.pack.toJson()),
                  'count': s.count,
                  'started_at': s.startedAt,
                },
              )
              .toList(),
          supplies.map((s) => s.id).toList(),
        );
      }
      if (quickDoses != null) {
        await txn.delete('quick_doses', where: 'mode = ?', whereArgs: [mode]);
        for (final q in quickDoses) {
          await txn.insert('quick_doses', {
            'id': q.id,
            'mode': mode,
            'route': q.route.code,
            'ester': q.ester.code,
            'value': q.value,
            'created_at': q.createdAt,
          }, conflictAlgorithm: ConflictAlgorithm.replace);
        }
      }
      if (templates != null) {
        await put(
          'templates',
          templates
              .map(
                (t) => <String, Object?>{
                  'id': t.id,
                  'mode': mode,
                  'name': t.name,
                  'route': t.route.code,
                  'ester': t.ester.code,
                  'dose_mg': t.doseMG,
                  'extras': jsonEncode(t.extras),
                  'created_at': t.createdAt,
                  'updated_at':
                      t.updatedAt ?? DateTime.now().millisecondsSinceEpoch,
                },
              )
              .toList(),
          templates.map((t) => t.id).toList(),
        );
      }
    });
  }
}
