import 'package:flutter/services.dart';

/// Whether the app may use the network. On recent Android versions this is a permission the user can switch
/// off, and an app updated from a build that never asked for it does not have it (the map's tile server on the
/// phone cannot even open its port without it). Other platforms always have it.
abstract class NetworkAccess {
  /// Shows the system prompt when there is one; the answer is whether access is allowed afterwards.
  Future<bool> request();
}

class PlatformNetworkAccess implements NetworkAccess {
  static const MethodChannel _channel = MethodChannel('co.cache/network_access');

  @override
  Future<bool> request() async {
    try {
      return await _channel.invokeMethod<bool>('request') ?? true;
    } on MissingPluginException {
      // No native side on this platform (iOS, tests): nothing to ask.
      return true;
    }
  }
}
