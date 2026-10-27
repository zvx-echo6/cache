import 'dart:async';
import 'dart:io';

import 'package:cache/location/location_service.dart';
import 'package:cache/location/position_source.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_test/flutter_test.dart';

class _Source implements PositionSource {
  final List<StreamController<Fix>> streams = [];
  @override
  Future<LocationPermissionState> permission() async => LocationPermissionState.granted;
  @override
  Future<LocationPermissionState> requestPermission() async => LocationPermissionState.granted;
  @override
  Future<bool> serviceEnabled() async => true;
  @override
  Future<Fix> current() async => Fix(lat: 42.5, lon: -113.8, accuracyM: 5, time: DateTime(2026, 10, 26));
  @override
  Stream<Fix> stream() {
    final c = StreamController<Fix>();
    streams.add(c);
    return c.stream;
  }

  @override
  Future<void> openAppSettings() async {}
  @override
  Future<void> openLocationSettings() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late _Source source;
  late LocationService location;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('lochold');
    source = _Source();
    location = LocationService(source: source, settingsDirOverride: dir);
    await location.init();
  });
  tearDown(() {
    location.dispose();
    dir.deleteSync(recursive: true);
  });

  test('while navigation holds the position stream the map lets its own go, and takes it again afterwards', () async {
    expect(source.streams, hasLength(1));
    expect(source.streams.first.hasListener, isTrue);
    location.holdStream(true);
    expect(source.streams.first.hasListener, isFalse, reason: 'the plugin shares one stream, so this one must not be running when guidance asks for its own');
    // Coming back to the app while guidance runs does not start it again.
    location.didChangeAppLifecycleState(AppLifecycleState.paused);
    location.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await Future<void>.delayed(Duration.zero); // Silent permission/service recheck.
    expect(source.streams, hasLength(1));
    location.holdStream(false);
    expect(source.streams, hasLength(2));
    expect(source.streams.last.hasListener, isTrue);
    // Holding twice or releasing twice is harmless.
    location.holdStream(false);
    expect(source.streams, hasLength(2));
  });
}
