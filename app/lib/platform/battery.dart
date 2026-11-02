import 'dart:io';

import 'package:flutter/services.dart';

/// How warm the device says it is (Android's PowerManager thermal status, iOS's ProcessInfo thermal state): background index
/// work eases off as it warms and pauses when severe (search/index_throttle.dart). iOS's fair is [light], serious [severe].
enum Thermal {
  unknown,
  nominal,
  light,
  moderate,
  severe,
  critical;

  static Thermal parse(Object? v) => Thermal.values.where((t) => t.name == v).firstOrNull ?? Thermal.unknown;

  /// Moderate or warmer.
  bool get hot => index >= Thermal.moderate.index;
}

/// The battery: how full, and whether the device is plugged in. Automatic work that takes long (building search indexes) waits
/// for charging or enough battery, and pauses when it runs low.
class BatteryReading {
  const BatteryReading({required this.percent, required this.charging, this.thermal = Thermal.unknown, this.headroom});

  /// 0 to 100.
  final int percent;

  /// Plugged in (charging or full).
  final bool charging;

  /// How warm the device is (unknown where it cannot say).
  final Thermal thermal;

  /// Android 11 and later: the thermal headroom over the next seconds, 0 (cool) to 1.0 (where the phone throttles hard), and
  /// above; null where the device does not give one.
  final double? headroom;

  /// Under 20% and not plugged in: long work pauses by itself.
  bool get low => !charging && percent < 20;
}

/// Reads the battery; null when the device cannot say (no battery, or no way to ask).
typedef BatteryReader = Future<BatteryReading?> Function();

/// The app's own channel (MainActivity.kt on Android: the sticky ACTION_BATTERY_CHANGED broadcast, no permission; AppDelegate.swift
/// on iOS: UIDevice battery monitoring). Method "read" answers {"percent": 0..100 or -1, "charging": bool, "thermal": "nominal" |
/// "light" | "moderate" | "severe" | "critical" | "unknown", "headroom": 0.0.. (Android 11 and later) or absent}. iOS calls
/// "changed" on the channel when the thermal state changes.
const MethodChannel kBatteryChannel = MethodChannel('co.cache/battery');

/// The battery now: Android and iOS through [kBatteryChannel], Linux from /sys/class/power_supply; other desktops say nothing (a
/// desktop is usually plugged in). [mobile] and [linuxRoot] are test hooks.
Future<BatteryReading?> readBattery({bool? mobile, String linuxRoot = '/sys/class/power_supply'}) async {
  try {
    if (mobile ?? (Platform.isAndroid || Platform.isIOS)) {
      final m = await kBatteryChannel.invokeMapMethod<String, Object?>('read');
      final level = (m?['percent'] as num?)?.toInt();
      if (m == null || level == null || level < 0) return null;
      final headroom = (m['headroom'] as num?)?.toDouble();
      return BatteryReading(
        percent: level.clamp(0, 100),
        charging: m['charging'] == true,
        thermal: Thermal.parse(m['thermal']),
        headroom: headroom == null || headroom.isNaN || headroom < 0 ? null : headroom,
      );
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
