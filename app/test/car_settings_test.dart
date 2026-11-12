import 'dart:io';

import 'package:cache/app_state.dart';
import 'package:cache/car/car_support.dart';
import 'package:cache/car/route_pushes.dart';
import 'package:cache/screens/settings/appearance_page.dart';
import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    carScreenSupported.value = false;
    messenger.setMockMethodCallHandler(kBuildChannel, null);
  });

  group('the car screen gate (cache/build)', () {
    test('true only when the Android build says it has Android Auto', () async {
      messenger.setMockMethodCallHandler(kBuildChannel, (call) async => {'androidAuto': true});
      expect(await readCarScreenSupport(android: true), isTrue);
      messenger.setMockMethodCallHandler(kBuildChannel, (call) async => {'androidAuto': false});
      expect(await readCarScreenSupport(android: true), isFalse);
      messenger.setMockMethodCallHandler(kBuildChannel, (call) async => throw PlatformException(code: 'x'));
      expect(await readCarScreenSupport(android: true), isFalse);
    });

    test('false off Android without asking', () async {
      var asked = false;
      messenger.setMockMethodCallHandler(kBuildChannel, (call) async {
        asked = true;
        return {'androidAuto': true};
      });
      expect(await readCarScreenSupport(android: false), isFalse);
      expect(asked, isFalse);
    });
  });

  // Bug: a navigation request's "geo:" address reached Flutter as a route to push, and the app threw on the unknown route.
  group('an address pushed by the platform as a route', () {
    Future<void> pushRoute(WidgetTester t, String location) => t.binding.defaultBinaryMessenger.handlePlatformMessage(
        'flutter/navigation', const JSONMethodCodec().encodeMethodCall(MethodCall('pushRouteInformation', {'location': location, 'state': null})), (_) {});

    testWidgets('is taken and nothing opens or throws', (t) async {
      final guard = IgnoreRoutePushes();
      WidgetsBinding.instance.addObserver(guard);
      addTearDown(() => WidgetsBinding.instance.removeObserver(guard));
      await t.pumpWidget(const MaterialApp(home: Text('home')));
      await pushRoute(t, 'geo:0,0?q=Made+Up+Clinic');
      await pushRoute(t, 'geo:42.5,-113.5');
      await t.pump();
      expect(t.takeException(), isNull);
      expect(find.text('home'), findsOneWidget);
    });
  });

  group('Settings > Appearance > Car', () {
    late Directory dir;
    late AppState app;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('carsettings');
      app = AppState(settingsDirOverride: dir, modelsDirOverride: dir);
    });

    tearDown(() {
      app.dispose();
      dir.deleteSync(recursive: true);
    });

    Future<void> show(WidgetTester t) async {
      t.view.physicalSize = const Size(390, 1400);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(theme: buildTheme(CacheThemeId.light), home: AppearancePage(app: app)));
    }

    testWidgets('hidden when the build has no car screen', (t) async {
      await show(t);
      expect(find.text('CAR'), findsNothing);
      expect(find.byKey(const ValueKey('car-climb-ahead')), findsNothing);
    });

    testWidgets('shown with the two switches when it has one, and they change the settings', (t) async {
      carScreenSupported.value = true;
      await show(t);
      expect(find.text('CAR'), findsOneWidget); // the group label draws in capitals, as every group label does
      expect(find.text('Climb ahead on the car screen'), findsOneWidget);
      expect(find.text('Route mini map on the car screen'), findsOneWidget);
      expect(t.widget<Switch>(find.descendant(of: find.byKey(const ValueKey('car-climb-ahead')), matching: find.byType(Switch))).value, isTrue);
      await t.tap(find.byKey(const ValueKey('car-climb-ahead')));
      await t.pump();
      expect(app.carClimbAhead, isFalse);
      expect(app.carRouteMiniMap, isTrue);
      await t.tap(find.byKey(const ValueKey('car-route-mini-map')));
      await t.pump();
      expect(app.carRouteMiniMap, isFalse);
      // The gate switching on or off after the page is up shows or hides the group.
      carScreenSupported.value = false;
      await t.pump();
      expect(find.text('CAR'), findsNothing);
    });
  });
}
