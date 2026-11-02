import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'app.dart';
import 'core/engine_ffi.dart';
import 'core/notifications.dart';
import 'data/db.dart';
import 'state/app_state.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final db = await AppDatabase.open();
  final state = AppState(db, HrtEngine.instance);
  try {
    await NotificationService.instance.init();
  } catch (_) {
    // A device without a notification service must still let people log doses.
  }
  await state.init();
  runApp(
    ChangeNotifierProvider<AppState>.value(value: state, child: const HrtApp()),
  );
}
