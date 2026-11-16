// Voice search from the car, the phone's side: the one-time card on Home and the row in Settings, with the permission channel
// faked (no iOS here). The words of the card and the row are the owner's; every place is made up.

import 'package:cache/car/car_voice_access.dart';
import 'package:cache/car/car_voice_card.dart';
import 'package:cache/layout/layout_state.dart';
import 'package:cache/screens/home_screen.dart';
import 'package:cache/screens/settings_screen.dart';
import 'package:cache/settings/app_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/settings_rig.dart';

const _channel = MethodChannel('co.cache/car');

/// iOS's answers, by hand: what the status calls say now, and what asking does.
class _FakeIos {
  String microphone = 'undetermined';
  String speech = 'undetermined';

  /// What asking brings (when a permission is still undetermined).
  String answer = 'granted';
  final List<String> calls = [];

  Future<Object?> handle(MethodCall call) async {
    calls.add(call.method);
    switch (call.method) {
      case 'voiceStatus':
        return {'microphone': microphone, 'speech': speech};
      case 'voiceRequest':
        if (microphone == 'undetermined') microphone = answer;
        if (speech == 'undetermined') speech = answer;
        return {'microphone': microphone, 'speech': speech};
    }
    return null;
  }
}

Widget _home(SettingsRig r, LayoutState layout, CarVoiceAccess? v) => HomeScreen(
  layout: layout,
  weather: r.weather,
  onAsk: (_) {},
  onOpenSettings: () {},
  onOpenShortcut: (_) {},
  carVoice: v,
);

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await tester.pump(const Duration(milliseconds: 20));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late _FakeIos ios;

  setUp(() {
    ios = _FakeIos();
    messenger.setMockMethodCallHandler(_channel, ios.handle);
  });
  tearDown(() => messenger.setMockMethodCallHandler(_channel, null));

  Future<CarVoiceAccess> access(SettingsRig r, {bool isIos = true, bool built = true, Future<void> Function()? openSettings}) async {
    final v = CarVoiceAccess(settings: r.settings, ios: isIos, supported: () async => built, openSettings: openSettings);
    r.carVoice = v;
    await v.start();
    addTearDown(v.dispose);
    return v;
  }

  group('the card on Home', () {
    testWidgets('shown after a car was seen and the permissions are missing', (tester) async {
      final r = await SettingsRig.create(tester);
      final layout = LayoutState(settingsDirOverride: r.dir);
      await tester.runAsync(layout.init);
      final v = await access(r);
      v.carConnected();
      await r.show(tester, _home(r, layout, v));
      await _settle(tester);
      expect(find.byType(CarVoiceCard), findsOneWidget);
      expect(find.text('Search by voice from the car?'), findsOneWidget);
    });

    testWidgets('not shown before a car was seen', (tester) async {
      final r = await SettingsRig.create(tester);
      final layout = LayoutState(settingsDirOverride: r.dir);
      await tester.runAsync(layout.init);
      final v = await access(r);
      await r.show(tester, _home(r, layout, v));
      await _settle(tester);
      expect(find.byType(CarVoiceCard), findsNothing);
    });

    testWidgets('not shown once the permissions are both granted', (tester) async {
      final r = await SettingsRig.create(tester);
      final layout = LayoutState(settingsDirOverride: r.dir);
      await tester.runAsync(layout.init);
      ios
        ..microphone = 'granted'
        ..speech = 'granted';
      final v = await access(r);
      v.carConnected();
      await r.show(tester, _home(r, layout, v));
      await _settle(tester);
      expect(find.byType(CarVoiceCard), findsNothing);
    });

    testWidgets('not shown once dismissed: Not now hides it for good', (tester) async {
      final r = await SettingsRig.create(tester);
      final layout = LayoutState(settingsDirOverride: r.dir);
      await tester.runAsync(layout.init);
      final v = await access(r);
      v.carConnected();
      await r.show(tester, _home(r, layout, v));
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey('car-voice-not-now')));
      await _settle(tester);
      expect(find.byType(CarVoiceCard), findsNothing);
      expect(r.settings.carVoiceCardDone, isTrue);
      expect(ios.calls.contains('voiceRequest'), isFalse, reason: 'Not now asks iOS for nothing');
      // Drawn again, or the car connecting again: still not shown.
      v.carConnected();
      await r.show(tester, _home(r, layout, v));
      await _settle(tester);
      expect(find.byType(CarVoiceCard), findsNothing);
    });

    testWidgets('not shown on Android', (tester) async {
      final r = await SettingsRig.create(tester);
      final layout = LayoutState(settingsDirOverride: r.dir);
      await tester.runAsync(layout.init);
      final v = await access(r, isIos: false);
      v.carConnected();
      await r.show(tester, _home(r, layout, v));
      await _settle(tester);
      expect(find.byType(CarVoiceCard), findsNothing);
      expect(ios.calls, isEmpty, reason: 'iOS is not asked on Android');
    });

    testWidgets('Allow asks iOS, and the card is gone', (tester) async {
      final r = await SettingsRig.create(tester);
      final layout = LayoutState(settingsDirOverride: r.dir);
      await tester.runAsync(layout.init);
      final v = await access(r);
      v.carConnected();
      await r.show(tester, _home(r, layout, v));
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey('car-voice-allow')));
      await _settle(tester);
      expect(ios.calls.where((c) => c == 'voiceRequest'), hasLength(1));
      expect(v.granted, isTrue);
      expect(find.byType(CarVoiceCard), findsNothing);
      expect(r.settings.carVoiceCardDone, isTrue);
    });
  });

  group('the row in Settings', () {
    Finder row() => find.byKey(const ValueKey('settings-car-voice'));

    testWidgets('present on iOS', (tester) async {
      final r = await SettingsRig.create(tester);
      await access(r);
      await r.show(tester, SettingsScreen(deps: r.deps));
      await _settle(tester);
      expect(row(), findsOneWidget);
      expect(find.text('Search by voice from the car'), findsOneWidget);
    });

    testWidgets('absent on Android', (tester) async {
      final r = await SettingsRig.create(tester);
      await access(r, isIos: false);
      await r.show(tester, SettingsScreen(deps: r.deps));
      await _settle(tester);
      expect(row(), findsNothing);
    });

    testWidgets('absent in a build with no car screen', (tester) async {
      final r = await SettingsRig.create(tester);
      await access(r, built: false);
      await r.show(tester, SettingsScreen(deps: r.deps));
      await _settle(tester);
      expect(row(), findsNothing);
    });

    testWidgets('the tap asks iOS, and the row then says On', (tester) async {
      final r = await SettingsRig.create(tester);
      await access(r);
      await r.show(tester, SettingsScreen(deps: r.deps));
      await _settle(tester);
      expect(find.descendant(of: row(), matching: find.text('Off')), findsOneWidget);
      await tester.tap(row());
      await _settle(tester);
      expect(ios.calls.where((c) => c == 'voiceRequest'), hasLength(1));
      expect(find.descendant(of: row(), matching: find.text('On')), findsOneWidget);
    });

    testWidgets('granted already: the row says On at once', (tester) async {
      final r = await SettingsRig.create(tester);
      ios
        ..microphone = 'granted'
        ..speech = 'granted';
      await access(r);
      await r.show(tester, SettingsScreen(deps: r.deps));
      await _settle(tester);
      expect(find.descendant(of: row(), matching: find.text('On')), findsOneWidget);
    });

    testWidgets('refused before: the row says so and the tap opens iOS Settings, not the prompt', (tester) async {
      final r = await SettingsRig.create(tester);
      ios
        ..microphone = 'denied'
        ..speech = 'granted';
      var opened = 0;
      await access(r, openSettings: () async => opened++);
      await r.show(tester, SettingsScreen(deps: r.deps));
      await _settle(tester);
      expect(find.descendant(of: row(), matching: find.text("Blocked in the device's settings")), findsOneWidget);
      await tester.tap(row());
      await _settle(tester);
      expect(opened, 1);
      expect(ios.calls.contains('voiceRequest'), isFalse);
    });
  });

  test('a build with no car side answers nothing: no error, still not granted', () async {
    messenger.setMockMethodCallHandler(_channel, null);
    final v = CarVoiceAccess(settings: AppSettings(), ios: true, supported: () async => true);
    await v.start();
    await v.request();
    expect(v.granted, isFalse);
    v.dispose();
  });
}
