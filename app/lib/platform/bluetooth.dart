import 'package:flutter/services.dart';

class BluetoothStatus {
  const BluetoothStatus({this.supported = false, this.enabled = false, this.permissions = const [], this.handle, this.active = false, this.error});

  factory BluetoothStatus.fromMap(Map<Object?, Object?> m) => BluetoothStatus(
    supported: m['supported'] == true,
    enabled: m['enabled'] == true,
    permissions: [for (final p in (m['missing_permissions'] as List? ?? const [])) '$p'],
    handle: (m['handle'] as num?)?.toInt(),
    active: m['active'] == true,
  );

  final bool supported;
  final bool enabled;
  final List<String> permissions;
  final int? handle;
  final bool active;
  final Object? error;

  BluetoothStatus failed(Object error) => BluetoothStatus(supported: supported, enabled: enabled, permissions: permissions, error: error);
  BluetoothStatus withActive(bool value) => BluetoothStatus(supported: supported, enabled: enabled, permissions: permissions, handle: handle, active: value, error: error);
}

/// The mobile permission/adapter channel. Hosts without a registered backend report unsupported.
class BluetoothPlatform {
  BluetoothPlatform({MethodChannel? channel}) : _channel = channel ?? const MethodChannel('co.cache/bluetooth');
  final MethodChannel _channel;

  Future<BluetoothStatus> _invoke(String method, [Map<String, Object?>? args]) async {
    try {
      return BluetoothStatus.fromMap(await _channel.invokeMapMethod<Object?, Object?>(method, args) ?? const {});
    } on MissingPluginException {
      return const BluetoothStatus();
    }
  }

  Future<BluetoothStatus> status() => _invoke('status');
  Future<BluetoothStatus> requestPermissions() => _invoke('request_permissions');
  Future<BluetoothStatus> start(int handle) => _invoke('start', {'handle': handle});
  Future<void> stop([int? handle]) async { await _invoke('stop', {'handle': ?handle}); }
}
