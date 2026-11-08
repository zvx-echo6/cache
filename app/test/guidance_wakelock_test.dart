import 'dart:io';

import 'package:cache/location/location_service.dart';
import 'package:cache/nav/guidance_wakelock.dart';
import 'package:cache/nav/nav_state.dart';
import 'package:cache/nav/units.dart';
import 'package:cache/platform/screen_awake.dart';
import 'package:cache/platform/system_ui.dart';
import 'package:cache_search/cache_search.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'location_service_test.dart' show FakeSource;
import 'nav_fakes.dart';

const _to = MapPlace(id: 'place:osm:n4', type: 'place', name: 'Cassia Regional Hospital', kind: 'Hospital', address: 'Burley, ID', lat: 42.5, lon: -113.5, matched: 'name');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late LocationService location;
  late FakeBackend backend;
  late FakeNavPosition gps;
  late NavState nav;
  late List<bool> calls;
  late GuidanceWakeLock lock;
  final route = fakeRouteJson();

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('wakelock');
    location = LocationService(source: FakeSource(), settingsDirOverride: dir);
    await location.init();
    location.publish(fixAt(42.5, -113.8));
    backend = FakeBackend()
      ..onRoute = ((to, mode, from) async => MapRoute.fromJson(route))
      ..onProgress = ((r, lat, lon) async => MapProgress.fromJson(fakeProgressJson(route, 0.2)));
    gps = FakeNavPosition();
    nav = NavState(backend: backend, location: location, speaker: FakeSpeaker(), positionSource: gps, fmt: const Fmt(UnitSystem.imperial));
    calls = [];
    lock = GuidanceWakeLock(nav, setKeepOn: (on) async => calls.add(on));
  });

  tearDown(() {
    lock.dispose();
    nav.dispose();
    location.dispose();
    dir.deleteSync(recursive: true);
  });

  Future<void> startGuiding() async {
    await nav.openDirections(_to);
    await nav.start();
  }

  testWidgets('the screen is kept on from Start and let go at End', (tester) async {
    expect(lock.held, isFalse);
    await tester.runAsync(() => nav.openDirections(_to));
    expect(lock.held, isFalse, reason: 'previewing a route does not hold the screen');
    expect(calls, isEmpty);
    await tester.runAsync(() => nav.start());
    expect(lock.held, isTrue);
    expect(calls, [true]);
    await tester.runAsync(() => nav.end());
    expect(lock.held, isFalse);
    expect(calls, [true, false]);
  });

  testWidgets('arriving lets the screen go', (tester) async {
    await tester.runAsync(startGuiding);
    expect(calls, [true]);
    backend.onProgress = (r, lat, lon) async => MapProgress.fromJson(fakeProgressJson(route, 1.0, arrived: true));
    await tester.runAsync(() async {
      gps.controller.add(fixAt(42.5, -113.5, heading: 90));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    expect(nav.arrived, isTrue);
    expect(nav.guiding, isTrue);
    expect(lock.held, isFalse);
    expect(calls, [true, false]);
  });

  testWidgets('going to the background lets the screen go, and coming back mid-route takes it again', (tester) async {
    await tester.runAsync(startGuiding);
    expect(calls, [true]);
    // A passing interruption (the notification shade) keeps it.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    expect(lock.held, isTrue);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    expect(lock.held, isFalse);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    expect(calls, [true, false]);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    expect(lock.held, isTrue);
    expect(calls, [true, false, true]);
    // Ended while in the background: nothing is held when the app comes back.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await tester.runAsync(() => nav.end());
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    expect(lock.held, isFalse);
    expect(calls, [true, false, true, false]);
  });

  testWidgets('closing the app while guiding lets the screen go', (tester) async {
    await tester.runAsync(startGuiding);
    lock.dispose();
    expect(calls, [true, false]);
    // A new one for tearDown to dispose; guidance is still on, so it takes the screen again.
    lock = GuidanceWakeLock(nav, setKeepOn: (on) async => calls.add(on));
    expect(calls, [true, false, true]);
  });

  group('the platform side', () {
    late List<MethodCall> sent;
    setUp(() {
      sent = [];
      for (final c in [systemUiChannel, screenAwakeChannel]) {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(c, (call) async {
          sent.add(MethodCall('${c.name} ${call.method}', call.arguments));
          return null;
        });
      }
    });
    tearDown(() {
      debugDefaultTargetPlatformOverride = null;
      for (final c in [systemUiChannel, screenAwakeChannel]) {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(c, null);
      }
    });

    test('Android sets the window flag through the system UI channel', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      await keepScreenOn(true);
      await keepScreenOn(false);
      expect(sent.map((c) => '${c.method} ${c.arguments}'), [
        'co.cache/system_ui keepScreenOn {on: true}',
        'co.cache/system_ui keepScreenOn {on: false}',
      ]);
    });

    test('iOS switches the idle timer through its own channel', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      await keepScreenOn(true);
      await keepScreenOn(false);
      expect(sent.map((c) => '${c.method} ${c.arguments}'), [
        'co.cache/screen_awake keepScreenOn {on: true}',
        'co.cache/screen_awake keepScreenOn {on: false}',
      ]);
    });

    test('other platforms do nothing', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      await keepScreenOn(true);
      expect(sent, isEmpty);
    });
  });
}
