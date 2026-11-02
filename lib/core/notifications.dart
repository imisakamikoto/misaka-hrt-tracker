import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import 'platform.dart';

/// Local reminders. Nothing leaves the device: the schedule is computed from
/// the model on the phone and handed to the platform's notification service.
///
/// Android and iOS keep the schedule in the OS, so a reminder still fires with
/// the app closed. Windows can post a toast but has no scheduler behind this
/// plugin, so reminders there are only meaningful while the window is open —
/// [Host.hasScheduledNotifications] says which behaviour applies.
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

    final settings = InitializationSettings(
      android: const AndroidInitializationSettings('@mipmap/ic_launcher'),
      // Permission is asked explicitly later, from the settings switch, so the
      // first launch is not interrupted by a system prompt.
      iOS: const DarwinInitializationSettings(
        requestAlertPermission: false,
        requestBadgePermission: false,
        requestSoundPermission: false,
      ),
      macOS: const DarwinInitializationSettings(
        requestAlertPermission: false,
        requestBadgePermission: false,
        requestSoundPermission: false,
      ),
      windows: Host.os == HostOS.windows
          ? const WindowsInitializationSettings(
              appName: 'Misaka hrt记录器',
              appUserModelId: 'jp.misaka.hrt',
              guid: 'ef5f2c1a-3b4d-4f6a-9c2e-71b8d40a5f13',
            )
          : null,
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
    switch (Host.os) {
      case HostOS.android:
        final granted = await _android?.requestNotificationsPermission();
        return granted ?? false;
      case HostOS.ios:
      case HostOS.macOS:
        final darwin = _plugin
            .resolvePlatformSpecificImplementation<
              IOSFlutterLocalNotificationsPlugin
            >();
        return await darwin?.requestPermissions(
              alert: true,
              badge: true,
              sound: true,
            ) ??
            false;
      case HostOS.windows:
        // Toasts are allowed by default; Focus Assist is the only gate and it
        // has no API here.
        return true;
      case HostOS.linux:
      case HostOS.unknown:
        return false;
    }
  }

  Future<bool> hasPermission() async {
    await init();
    switch (Host.os) {
      case HostOS.android:
        return await _android?.areNotificationsEnabled() ?? false;
      case HostOS.ios:
      case HostOS.macOS:
        final darwin = _plugin
            .resolvePlatformSpecificImplementation<
              IOSFlutterLocalNotificationsPlugin
            >();
        final options = await darwin?.checkPermissions();
        return options?.isEnabled ?? false;
      case HostOS.windows:
        return true;
      case HostOS.linux:
      case HostOS.unknown:
        return false;
    }
  }

  NotificationDetails get _details => NotificationDetails(
    android: const AndroidNotificationDetails(
      _channelId,
      _channelName,
      channelDescription: _channelDescription,
      importance: Importance.high,
      priority: Priority.high,
      category: AndroidNotificationCategory.reminder,
    ),
    iOS: const DarwinNotificationDetails(
      presentAlert: true,
      presentBanner: true,
      presentSound: true,
    ),
    macOS: const DarwinNotificationDetails(presentAlert: true, presentSound: true),
    windows: const WindowsNotificationDetails(),
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
      try {
        await _plugin.zonedSchedule(
          id: _levelGuardIdBase + slot,
          scheduledDate: when,
          notificationDetails: _details,
          androidScheduleMode: _mode,
          title: reminder.title,
          body: reminder.body,
          payload: 'level-guard',
        );
      } catch (_) {
        // A host that cannot schedule (a desktop without a toast service)
        // must not stop the remaining reminders from being posted.
      }
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
      try {
        await _plugin.zonedSchedule(
          id: _doseDueIdBase + slot,
          scheduledDate: tz.TZDateTime.from(reminder.at, tz.local),
          notificationDetails: _details,
          androidScheduleMode: _mode,
          title: reminder.title,
          body: reminder.body,
          payload: 'dose-due',
        );
      } catch (_) {
        // See scheduleLevelGuards.
      }
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
