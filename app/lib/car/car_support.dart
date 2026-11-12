import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Whether this build has a car screen (Android Auto today; CarPlay will set it too). Settings shows its Car group only when this
/// is true. False until [readCarScreenSupport] has answered, and always false on iOS, web and Linux for now.
final ValueNotifier<bool> carScreenSupported = ValueNotifier<bool>(false);

const MethodChannel kBuildChannel = MethodChannel('cache/build');

/// Asks the Android side whether this build was made with Android Auto (Gradle property cacheAndroidAuto, BuildConfig
/// CACHE_ANDROID_AUTO). Read once at start. False when it is not Android or the channel does not answer. [android] is a test hook.
Future<bool> readCarScreenSupport({MethodChannel channel = kBuildChannel, bool? android}) async {
  if (!(android ?? (!kIsWeb && Platform.isAndroid))) return false;
  try {
    final m = await channel.invokeMethod<Object?>('get');
    return m is Map && m['androidAuto'] == true;
  } catch (_) {
    return false;
  }
}
