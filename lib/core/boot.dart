import 'package:flutter/services.dart';

/// The only thing the app needs from the Android host that Flutter cannot do on
/// its own: the "start on boot" flag and the OEM autostart screen.
///
/// The channel is optional. On desktop, in tests, or if the host is missing,
/// every call quietly reports "not supported" and the app keeps working with
/// notifications scheduled by the alarm manager alone.
abstract final class BootHost {
  static const MethodChannel _channel = MethodChannel('jp.misaka.hrt/boot');

  static bool? _supported;

  /// True when the Android host answered at least once.
  static Future<bool> get supported async {
    final cached = _supported;
    if (cached != null) return cached;
    try {
      final value = await _channel.invokeMethod<bool>('isSupported') ?? false;
      _supported = value;
      return value;
    } on MissingPluginException {
      _supported = false;
      return false;
    } on PlatformException {
      _supported = false;
      return false;
    }
  }

  /// Persist the flag where the boot receiver can read it.
  static Future<bool> setEnabled(bool value) async {
    if (!await supported) return false;
    try {
      return await _channel.invokeMethod<bool>('setEnabled', {
            'enabled': value,
          }) ??
          false;
    } on PlatformException {
      return false;
    }
  }

  static Future<bool> isEnabled() async {
    if (!await supported) return false;
    try {
      return await _channel.invokeMethod<bool>('isEnabled') ?? false;
    } on PlatformException {
      return false;
    }
  }

  /// Opens this app's autostart page. Manufacturer ROMs hide it in different
  /// places, so the host tries the known ones and falls back to app settings.
  static Future<bool> openAutostartSettings() async {
    if (!await supported) return false;
    try {
      return await _channel.invokeMethod<bool>('openAutostartSettings') ??
          false;
    } on PlatformException {
      return false;
    }
  }
}
