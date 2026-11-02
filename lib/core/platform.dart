import 'dart:io';

/// Where the app is running, in the terms the UI and the storage layer care
/// about.
///
/// Flutter already exposes [Platform], but the questions asked here are always
/// the same few ("is this a phone?", "is the system notification scheduler
/// available?", "should the desktop shell be used?"), and asking them in one
/// place keeps the `dart:io` imports out of the widgets.
enum HostOS { android, ios, windows, macOS, linux, unknown }

abstract final class Host {
  static final HostOS os = _detect();

  static HostOS _detect() {
    if (Platform.isAndroid) return HostOS.android;
    if (Platform.isIOS) return HostOS.ios;
    if (Platform.isWindows) return HostOS.windows;
    if (Platform.isMacOS) return HostOS.macOS;
    if (Platform.isLinux) return HostOS.linux;
    return HostOS.unknown;
  }

  /// Phones and tablets: one column, bottom navigation.
  static bool get isMobile => os == HostOS.android || os == HostOS.ios;

  /// Windowed platforms: side navigation, mouse and keyboard.
  static bool get isDesktop =>
      os == HostOS.windows || os == HostOS.macOS || os == HostOS.linux;

  /// The notification plugin can only schedule on Android and iOS. On desktop
  /// it can still post, but nothing survives the process exiting, so reminders
  /// are computed in-app there.
  static bool get hasScheduledNotifications => isMobile;

  /// Android is the only host with a boot receiver; iOS and Windows start the
  /// app themselves.
  static bool get hasBootReceiver => os == HostOS.android;

  /// Path separator used by the platform, for messages only.
  static String get name => switch (os) {
    HostOS.android => 'Android',
    HostOS.ios => 'iOS',
    HostOS.windows => 'Windows',
    HostOS.macOS => 'macOS',
    HostOS.linux => 'Linux',
    HostOS.unknown => 'unknown',
  };
}
