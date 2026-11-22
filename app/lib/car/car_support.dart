import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../platform.dart' as plat;

/// Whether Settings shows its Car group: the switches for what the Android car draws over the map. Set from
/// [readCarScreenSupport] on Android only (main.dart); false until it has answered, and on iPhone, web and Linux.
final ValueNotifier<bool> carScreenSupported = ValueNotifier<bool>(false);

const MethodChannel kBuildChannel = MethodChannel('cache/build');

/// Asks the native side whether this build was made with a car screen. Read once at start.
///
/// iPhone: CarPlay, the build setting CACHE_CARPLAY (app/ios/Runner/CarPlay); the answer's `carPlay`. A build made without it
/// has no car side on the `co.cache/car` channel, so the app does not make a car bridge there.
/// Android: Android Auto, the answer's `androidAuto`.
///
/// False on anything else, and when the channel does not answer. [android] and [ios] are test hooks.
Future<bool> readCarScreenSupport({MethodChannel channel = kBuildChannel, bool? android, bool? ios}) async {
  final onAndroid = android ?? plat.isAndroid;
  final onIos = ios ?? plat.isIOS;
  if (!onAndroid && !onIos) return false;
  try {
    final m = await channel.invokeMethod<Object?>('get');
    return m is Map && m[onIos ? 'carPlay' : 'androidAuto'] == true;
  } catch (_) {
    return false;
  }
}
