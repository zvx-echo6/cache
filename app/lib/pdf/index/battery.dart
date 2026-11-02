import 'dart:io';

import 'package:flutter/services.dart';

/// The battery as the indexer sees it: how full, and whether the device is plugged in.
class BatteryReading {
  const BatteryReading({required this.percent, required this.charging});

  final int percent;
  final bool charging;

  /// Under 20% and not plugged in: a long run pauses by itself ("Paused: battery low").
  bool get low => !charging && percent < 20;
}

/// Reads the battery; null when the device cannot say (no battery, or no way to ask).
typedef BatteryReader = Future<BatteryReading?> Function();

const MethodChannel _channel = MethodChannel('co.cache/battery');

/// Android (BatteryManager) and iOS (UIDevice) answer through the app's own channel; Linux reads /sys/class/power_supply; other
/// desktops say nothing (a desktop is usually plugged in).
Future<BatteryReading?> readBattery() async {
  try {
    if (Platform.isAndroid || Platform.isIOS) {
      final m = await _channel.invokeMapMethod<String, Object?>('read');
      final level = (m?['percent'] as num?)?.toInt();
      if (m == null || level == null || level < 0) return null;
      return BatteryReading(percent: level, charging: m['charging'] == true);
    }
    if (Platform.isLinux) return _linux();
  } on MissingPluginException {
    return null;
  } on PlatformException {
    return null;
  } catch (_) {
    return null;
  }
  return null;
}

BatteryReading? _linux() {
  final root = Directory('/sys/class/power_supply');
  if (!root.existsSync()) return null;
  for (final d in root.listSync().whereType<Directory>()) {
    final cap = File('${d.path}/capacity');
    final type = File('${d.path}/type');
    if (!cap.existsSync() || !type.existsSync() || type.readAsStringSync().trim() != 'Battery') continue;
    final pct = int.tryParse(cap.readAsStringSync().trim());
    if (pct == null) continue;
    final status = File('${d.path}/status').existsSync() ? File('${d.path}/status').readAsStringSync().trim() : '';
    return BatteryReading(percent: pct, charging: status == 'Charging' || status == 'Full' || status == 'Not charging');
  }
  return null;
}
