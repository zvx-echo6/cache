import 'package:cache/platform/system_ui.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final native = <MethodCall>[];
  final platform = <MethodCall>[];
  setUp(() {
    native.clear();
    platform.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(systemUiChannel, (call) async {
          native.add(call);
          return null;
        });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          platform.add(call);
          return null;
        });
  });
  tearDown(() async {
    await setSystemBarTheme(hideStatusBar: false);
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(systemUiChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });
  test(
    'Android uses its native bar policy; fullscreen restores the selected theme',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      await setSystemBarTheme(hideStatusBar: false);
      await setSystemBars(hideStatusBar: true);
      await setSystemBars();
      await setSystemBarTheme(hideStatusBar: true);
      await setSystemBars();
      expect(native.map((c) => c.method), everyElement('apply'));
      expect(native.map((c) => (c.arguments as Map)['hideStatusBar']), [
        false,
        true,
        false,
        true,
        true,
      ]);
      expect(
        platform,
        isEmpty,
        reason: 'Flutter edge-to-edge must not turn Android navigation back on',
      );
    },
  );
  test('iOS retains normal and fullscreen status-bar modes', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    await setSystemBarTheme(hideStatusBar: false);
    await setSystemBars(hideStatusBar: true);
    await setSystemBars();
    expect(native, isEmpty);
    expect(platform.map((c) => c.arguments), [
      'SystemUiMode.edgeToEdge',
      'SystemUiMode.immersiveSticky',
      'SystemUiMode.edgeToEdge',
    ]);
  });
}
