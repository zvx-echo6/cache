import 'dart:async';
import 'dart:io';

import 'package:cache/location/location_service.dart';
import 'package:cache/location/position_source.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeSource implements PositionSource {
  LocationPermissionState state = LocationPermissionState.notAsked;
  LocationPermissionState afterPrompt = LocationPermissionState.granted;
  bool service = true;
  int prompts = 0;
  Fix next = Fix(lat: 42.5, lon: -113.8, accuracyM: 12, time: DateTime(2026, 10, 25, 14, 20, 5));
  final StreamController<Fix> controller = StreamController<Fix>.broadcast();

  @override
  Future<LocationPermissionState> permission() async => state;
  @override
  Future<LocationPermissionState> requestPermission() async {
    prompts++;
    return state = afterPrompt;
  }

  @override
  Future<bool> serviceEnabled() async => service;
  @override
  Future<Fix> current() async => next;
  @override
  Stream<Fix> stream() => controller.stream;
  @override
  Future<void> openAppSettings() async {}
  @override
  Future<void> openLocationSettings() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('loc'));
  tearDown(() => dir.deleteSync(recursive: true));

  Future<LocationService> make(FakeSource s) async {
    final l = LocationService(source: s, settingsDirOverride: dir);
    await l.init();
    addTearDown(l.dispose);
    return l;
  }

  test('init never asks for permission', () async {
    final s = FakeSource();
    final l = await make(s);
    expect(s.prompts, 0);
    expect(l.fix, isNull);
  });

  test('the first need shows the reason; a no there means no system prompt', () async {
    final s = FakeSource();
    final l = await make(s);
    var explained = 0;
    expect(await l.request(explain: () async => ++explained < 0), isFalse);
    expect(explained, 1);
    expect(s.prompts, 0);
  });

  test('a yes asks the system, reads a fix and keeps listening', () async {
    final s = FakeSource();
    final l = await make(s);
    expect(await l.request(explain: () async => true), isTrue);
    expect(s.prompts, 1);
    expect(l.fix!.lat, 42.5);
    expect(l.fix!.accuracyM, 12);
    s.controller.add(Fix(lat: 43, lon: -114, accuracyM: 5, time: DateTime(2026, 10, 25, 14, 21)));
    await Future<void>.delayed(Duration.zero);
    expect(l.fix!.lat, 43);
  });

  test('a granted permission does not ask again', () async {
    final s = FakeSource()..state = LocationPermissionState.granted;
    final l = await make(s);
    var explained = 0;
    await l.request(explain: () async => ++explained > 0);
    expect(explained, 0);
    expect(s.prompts, 0);
    expect(l.fix, isNotNull);
  });

  test('refused and blocked are reported', () async {
    final s = FakeSource()..afterPrompt = LocationPermissionState.denied;
    final l = await make(s);
    expect(await l.request(explain: () async => true), isFalse);
    expect(l.problem, LocationProblem.permissionDenied);
    s.state = LocationPermissionState.deniedForever;
    expect(await l.request(explain: () async => true), isFalse);
    expect(l.problem, LocationProblem.permissionBlocked);
  });

  test('the phone\'s location switch being off is reported', () async {
    final s = FakeSource()
      ..state = LocationPermissionState.granted
      ..service = false;
    final l = await make(s);
    expect(await l.request(explain: () async => true), isFalse);
    expect(l.problem, LocationProblem.serviceOff);
  });

  test('turning it off forgets the fix, stops listening, and is remembered', () async {
    final s = FakeSource();
    final l = await make(s);
    await l.request(explain: () async => true);
    await l.setEnabled(false);
    expect(l.fix, isNull);
    s.controller.add(Fix(lat: 1, lon: 1, accuracyM: 1, time: DateTime.now()));
    await Future<void>.delayed(Duration.zero);
    expect(l.fix, isNull);
    expect(await l.request(explain: () async => true), isFalse);
    expect(l.problem, LocationProblem.off);

    final again = await make(s);
    expect(again.enabled, isFalse);
  });
}
