import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

/// Local reminders. Nothing leaves the device: the schedule is computed from
/// the model on the phone and handed to Android's notification manager.
class NotificationService {
  NotificationService._();
  static final NotificationService instance = NotificationService._();

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  bool _ready = false;
  bool get isReady => _ready;

  static const _channelId = 'hrt_level_guard';
  static const _channelName = 'Dose reminders';
  static const _channelDescription =
      'Warns before the modelled level leaves the target range';

  static const _levelGuardIdBase = 4200;
  static const _doseDueIdBase = 4400;

  Future<void> init() async {
    if (_ready) return;
    tzdata.initializeTimeZones();
    try {
      final info = await FlutterTimezone.getLocalTimezone();
      tz.setLocalLocation(tz.getLocation(info.identifier));
    } catch (_) {
      // Keep UTC if the platform cannot name its zone.
    }

    const settings = InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    );
    await _plugin.initialize(settings: settings);
    await _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.createNotificationChannel(
          const AndroidNotificationChannel(
            _channelId,
            _channelName,
            description: _channelDescription,
            importance: Importance.high,
          ),
        );
    _ready = true;
    await refreshScheduleMode();
  }

  Future<bool> requestPermission() async {
    await init();
    final android = _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    final granted = await android?.requestNotificationsPermission();
    return granted ?? false;
  }

  Future<bool> hasPermission() async {
    await init();
    final android = _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    return await android?.areNotificationsEnabled() ?? false;
  }

  NotificationDetails get _details => const NotificationDetails(
    android: AndroidNotificationDetails(
      _channelId,
      _channelName,
      channelDescription: _channelDescription,
      importance: Importance.high,
      priority: Priority.high,
      category: AndroidNotificationCategory.reminder,
    ),
  );

  AndroidFlutterLocalNotificationsPlugin? get _android => _plugin
      .resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin
      >();

  /// Exact alarms need a permission the user grants separately on Android 14+.
  /// Without it reminders still work, just within a window.
  AndroidScheduleMode _mode = AndroidScheduleMode.inexactAllowWhileIdle;

  Future<void> refreshScheduleMode() async {
    await init();
    try {
      final allowed = await _android?.canScheduleExactNotifications() ?? false;
      _mode = allowed
          ? AndroidScheduleMode.exactAllowWhileIdle
          : AndroidScheduleMode.inexactAllowWhileIdle;
    } catch (_) {
      _mode = AndroidScheduleMode.inexactAllowWhileIdle;
    }
  }

  /// Opens the system screen where exact alarms can be allowed.
  Future<bool> requestExactAlarms() async {
    await init();
    final granted = await _android?.requestExactAlarmsPermission() ?? false;
    await refreshScheduleMode();
    return granted;
  }

  /// Replace every scheduled level-guard reminder.
  Future<void> scheduleLevelGuards(List<LevelGuardReminder> reminders) async {
    await init();
    for (var i = 0; i < 12; i++) {
      await _plugin.cancel(id: _levelGuardIdBase + i);
    }
    var slot = 0;
    final now = DateTime.now();
    for (final reminder in reminders) {
      if (slot >= 12) break;
      if (!reminder.at.isAfter(now)) continue;
      final when = tz.TZDateTime.from(reminder.at, tz.local);
      await _plugin.zonedSchedule(
        id: _levelGuardIdBase + slot,
        scheduledDate: when,
        notificationDetails: _details,
        androidScheduleMode: _mode,
        title: reminder.title,
        body: reminder.body,
        payload: 'level-guard',
      );
      slot++;
    }
  }

  /// Replace every scheduled "dose due" reminder.
  Future<void> scheduleDoseDue(List<LevelGuardReminder> reminders) async {
    await init();
    for (var i = 0; i < 12; i++) {
      await _plugin.cancel(id: _doseDueIdBase + i);
    }
    var slot = 0;
    final now = DateTime.now();
    for (final reminder in reminders) {
      if (slot >= 12) break;
      if (!reminder.at.isAfter(now)) continue;
      await _plugin.zonedSchedule(
        id: _doseDueIdBase + slot,
        scheduledDate: tz.TZDateTime.from(reminder.at, tz.local),
        notificationDetails: _details,
        androidScheduleMode: _mode,
        title: reminder.title,
        body: reminder.body,
        payload: 'dose-due',
      );
      slot++;
    }
  }

  Future<void> cancelAll() async {
    await init();
    await _plugin.cancelAll();
  }

  Future<List<PendingNotificationRequest>> pending() async {
    await init();
    return _plugin.pendingNotificationRequests();
  }
}

class LevelGuardReminder {
  LevelGuardReminder({
    required this.at,
    required this.title,
    required this.body,
  });

  final DateTime at;
  final String title;
  final String body;
}
