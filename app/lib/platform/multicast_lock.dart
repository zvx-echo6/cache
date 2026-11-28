import 'package:flutter/services.dart';

/// The Android Wi-Fi multicast lock (MainActivity, "co.cache/multicast"). Android drops multicast packets unless an app holds
/// one, and Reticulum's local discovery listens for them: the lock is taken just before the sharing engine opens and let go when
/// it stops. Only Android has it; elsewhere nothing makes one.
class MulticastLock {
  MulticastLock({MethodChannel? channel}) : _channel = channel ?? const MethodChannel('co.cache/multicast');

  final MethodChannel _channel;

  /// Takes the lock (kept until [release]). False when it could not be taken; sharing goes on without Wi-Fi discovery.
  Future<bool> acquire() async {
    try {
      return await _channel.invokeMethod<bool>('acquire') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// Lets the lock go, if held.
  Future<void> release() async {
    try {
      await _channel.invokeMethod<void>('release');
    } on MissingPluginException {
      // Flutter-only tests and hosts without the native side.
    } on PlatformException {
      // nothing held
    }
  }
}
