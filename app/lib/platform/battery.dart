import 'dart:io';

import 'package:flutter/services.dart';

/// The battery: how full, and whether the device is plugged in. Automatic work that takes long (building search indexes) waits
/// for charging or enough battery, and pauses when it runs low.
class BatteryReading {
  const BatteryReading({required this.percent, required this.charging});

  /// 0 to 100.
  final int percent;

  /// Plugged in (charging or full).
  final bool charging;

  /// Under 20% and not plugged in: long work pauses by itself.
  bool get low => !charging && percent < 20;
}

/// Reads the battery; null when the device cannot say (no battery, or no way to ask).
typedef BatteryReader = Future<BatteryReading?> Function();

/// The app's own channel (MainActivity.kt on Android: the sticky ACTION_BATTERY_CHANGED broadcast, no permission; AppDelegate.swift
/// on iOS: UIDevice battery monitoring). Method "read" answers {"percent": 0..100 or -1, "charging": bool}.
const MethodChannel kBatteryChannel = MethodChannel('co.cache/battery');

/// The battery now: Android and iOS through [kBatteryChannel], Linux from /sys/class/power_supply; other desktops say nothing (a
/// desktop is usually plugged in). [mobile] and [linuxRoot] are test hooks.
Future<BatteryReading?> readBattery({bool? mobile, String linuxRoot = '/sys/class/power_supply'}) async {
  try {
    if (mobile ?? (Platform.isAndroid || Platform.isIOS)) {
      final m = await kBatteryChannel.invokeMapMethod<String, Object?>('read');
      final level = (m?['percent'] as num?)?.toInt();
      if (m == null || level == null || level < 0) return null;
      return BatteryReading(percent: level.clamp(0, 100), charging: m['charging'] == true);
    }
    if (Platform.isLinux) return readLinuxBattery(linuxRoot);
  } on MissingPluginException {
    return null;
  } on PlatformException {
    return null;
  } catch (_) {
    return null;
  }
  return null;
}

/// The first battery under [root] (a power_supply folder whose type is Battery): its capacity, and plugged in when its status is
/// Charging, Full or Not charging. Null when there is none.
BatteryReading? readLinuxBattery(String root) {
  final dir = Directory(root);
  if (!dir.existsSync()) return null;
  for (final d in dir.listSync().whereType<Directory>()) {
    final cap = File('${d.path}/capacity');
    final type = File('${d.path}/type');
    if (!cap.existsSync() || !type.existsSync() || type.readAsStringSync().trim() != 'Battery') continue;
    final pct = int.tryParse(cap.readAsStringSync().trim());
    if (pct == null) continue;
    final status = File('${d.path}/status').existsSync() ? File('${d.path}/status').readAsStringSync().trim() : '';
    return BatteryReading(percent: pct.clamp(0, 100), charging: status == 'Charging' || status == 'Full' || status == 'Not charging');
  }
  return null;
}
