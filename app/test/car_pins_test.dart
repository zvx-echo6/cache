import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cache/car/car_bridge.dart';
import 'package:cache/car/car_drive.dart';
import 'package:cache/car/car_pins.dart';
import 'package:cache/location/location_service.dart';
import 'package:cache/location/position_source.dart';
import 'package:cache/maps/maps_state.dart';
import 'package:cache/maps/style/style_generator.dart' show kNotebookSource;
import 'package:cache/maps/user_layers.dart';
import 'package:cache/nav/nav_state.dart';
import 'package:cache/nav/units.dart';
import 'package:cache/notebook/map_icons.dart';
import 'package:cache/notebook/notebook_map.dart' show repeaterPinName;
import 'package:cache/notebook/notebook_model.dart';
import 'package:cache/notebook/notebook_state.dart';
import 'package:cache/notebook/pin_image.dart';
import 'package:cache/notebook/place_style.dart' show markerColor;
import 'package:cache/theme.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show IconData;
import 'package:flutter_test/flutter_test.dart';

import 'nav_fakes.dart';
import 'support/notebook_fake.dart';
import 'support/test_layer_engine.dart';

Future<void> settle([int ms = 30]) => Future<void>.delayed(Duration(milliseconds: ms));

/// A made-up picture: says what it was drawn for, so the tests can read it back.
Future<Uint8List> _fakePng(IconData icon, Color tint, PinStyle style, {required double ratio, required bool tactical}) async =>
    Uint8List.fromList(utf8.encode('${icon.codePoint}|${tint.toARGB32()}|${style.name}|$ratio|$tactical'));

/// The repeater lists of the user's map data, standing in for the core: one list, shown or hidden.
class _Repeaters {
  bool shown = true;
  late final UserLayersState state = UserLayersState((call, [arg]) async => switch (call) {
        'list' => {
            'layers': const [],
            'repeater_lists': [
              {'id': 'r1', 'kind': 'repeaters', 'name': 'Example list', 'visible': shown, 'repeaters': 2},
            ],
          },
        'get' => {
            'id': 'r1',
            'repeaters': [
              {'item': 1, 'name': 'TEST1', 'lat': 43.11, 'lon': -115.21, 'frequency': '146.000 MHz'},
              {'item': 2, 'name': 'TEST2', 'lat': null, 'lon': null},
            ],
          },
        _ => const <String, dynamic>{},
      });
}

class _NoSource implements PositionSource {
  @override
  Future<LocationPermissionState> permission() async => LocationPermissionState.granted;
  @override
  Future<LocationPermissionState> requestPermission() async => LocationPermissionState.granted;
  @override
  Future<bool> serviceEnabled() async => true;
  @override
  Future<Fix> current() async => fixAt(43.1, -115.2);
  @override
  Stream<Fix> stream() => const Stream.empty();
  @override
  Future<void> openAppSettings() async {}
  @override
  Future<void> openLocationSettings() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeNotebookBackend backend;
  late NotebookState notebooks;
  late _Repeaters repeaters;
  late ValueNotifier<PinStyle> style;
  late ValueNotifier<bool> connected;
  late List<Map<String, Object?>> sent;
  late CarPins pins;
  late Notebook trails;
  int renders = 0;

  Future<void> send(String method, Object? args) async {
    expect(method, 'pins');
    sent.add((args as Map).cast<String, Object?>());
  }

  List<Map<String, dynamic>> features(Map<String, Object?> m) =>
      [for (final f in (jsonDecode(m['geojson'] as String) as Map)['features'] as List) (f as Map).cast<String, dynamic>()];
  List<List<num>> coords(Map<String, Object?> m) => [for (final f in features(m)) (f['geometry']['coordinates'] as List).cast<num>()];
  // A pin's place as text: a list of lists matches an inner list by identity, not by its numbers.
  List<String> at(Map<String, Object?> m) => [for (final c in coords(m)) '${c[0]},${c[1]}'];
  Map<String, Uint8List> images(Map<String, Object?> m) => (m['images'] as Map).cast<String, Uint8List>();

  Future<NbEntry> place(Notebook n, String title, double lat, double lon, {Map<String, dynamic> props = const {}}) =>
      notebooks.saveEntry(notebookId: n.id, occurredAt: '2026-11-12T12:00:00Z', title: title, place: NbPlace(lat: lat, lon: lon, label: title), props: props);

  setUp(() async {
    backend = FakeNotebookBackend(journal: false);
    notebooks = fakeNotebook(backend);
    await notebooks.start();
    trails = await notebooks.saveNotebook(template: 'places', def: const NotebookDef(name: 'Trailheads', fields: [], icon: 'star', color: 'teal'), map: true);
    repeaters = _Repeaters();
    await repeaters.state.reload();
    style = ValueNotifier(PinStyle.icon);
    connected = ValueNotifier(false);
    sent = [];
    renders = 0;
    pins = CarPins(
      read: ({required bool tactical}) => readMapPins(notebooks, repeaters.state, tactical: tactical),
      pinStyle: () => style.value,
      changes: [notebooks, repeaters.state],
      pinStyleChanges: style,
      render: (icon, tint, s, {required double ratio, required bool tactical}) {
        renders++;
        return _fakePng(icon, tint, s, ratio: ratio, tactical: tactical);
      },
      debounce: Duration.zero,
    );
    pins.bind(connected: connected, send: send);
  });

  tearDown(() {
    pins.dispose();
    connected.dispose();
    style.dispose();
  });

  group('what goes to the car', () {
    test('nothing while no car is connected', () async {
      await place(trails, 'Copper Hollow Trailhead', 43.2, -115.1);
      await settle();
      expect(sent, isEmpty);
    });

    test('on connecting: every pin the phone map draws, with its picture, and nothing of the places but where they are', () async {
      final saved = await notebooks.ensureSavedPlaces();
      await place(saved, 'Quarry Flat', 43.0, -115.3);
      await place(trails, 'Copper Hollow Trailhead', 43.2, -115.1);
      await settle();
      connected.value = true;
      await settle();
      expect(sent, hasLength(1));
      final m = sent.single;
      expect(m['source'], kNotebookSource);
      expect(m['reset'], isTrue);
      expect(m['ratio'], kCarPinImageRatio);
      // The repeater first (the phone draws repeaters under the notebook pins), then the places, newest first as the core gives them.
      expect(coords(m), [
        [-115.21, 43.11],
        [-115.1, 43.2],
        [-115.3, 43.0],
      ]);
      for (final f in features(m)) {
        expect((f['properties'] as Map).keys, ['pin'], reason: 'only the picture name: no title, entry or notebook');
      }
      final names = [for (final f in features(m)) f['properties']['pin'] as String];
      expect(names[0], repeaterPinName(PinStyle.icon), reason: 'the picture the phone style names for repeaters');
      expect(names[1], pinImageId(PinStyle.icon, 'star', markerColor('teal').color), reason: "the notebook's icon and colour");
      expect(images(m).keys.toSet(), names.toSet(), reason: 'each picture once');
      // Drawn by the phone's own painter, at the car's ratio, in the person's pin style.
      expect(utf8.decode(images(m)[names[1]]!), '${mapIcon('star').icon.codePoint}|${markerColor('teal').color.toARGB32()}|icon|3.0|false');
      // Nothing of a place's name is in the message.
      expect(jsonEncode(m['geojson']), isNot(contains('Copper Hollow')));
      expect(jsonEncode(m['geojson']), isNot(contains('Quarry')));
      expect(jsonEncode(m['geojson']), isNot(contains('TEST1')));
    });

    test('a place saved, moved and deleted each sends the pins again; the pictures already sent are not sent twice', () async {
      await place(trails, 'Copper Hollow Trailhead', 43.2, -115.1);
      connected.value = true;
      await settle();
      expect(sent, hasLength(1));
      final rendered = renders;

      final e = await place(trails, 'Juniper Spring', 43.25, -115.15);
      await settle();
      expect(sent, hasLength(2));
      expect(at(sent.last), contains('-115.15,43.25'));
      expect(images(sent.last), isEmpty, reason: 'same icon and colour: the car has the picture');
      expect(sent.last['reset'], isFalse);
      expect(renders, rendered);

      await notebooks.saveEntry(id: e.id, notebookId: trails.id, occurredAt: e.occurredAt, title: e.title, place: const NbPlace(lat: 43.3, lon: -115.4));
      await settle();
      expect(sent, hasLength(3));
      expect(at(sent.last), contains('-115.4,43.3'));
      expect(at(sent.last), isNot(contains('-115.15,43.25')));

      await notebooks.deleteEntry(e.id);
      await settle();
      expect(sent, hasLength(4));
      expect(at(sent.last), isNot(contains('-115.4,43.3')));
    });

    test('a renamed place changes nothing the car draws: nothing is sent', () async {
      final e = await place(trails, 'Copper Hollow Trailhead', 43.2, -115.1);
      connected.value = true;
      await settle();
      await notebooks.saveEntry(id: e.id, notebookId: trails.id, occurredAt: e.occurredAt, title: 'Copper Hollow', place: e.place);
      await settle();
      expect(sent, hasLength(1));
    });

    test('a place given its own icon and colour sends its new picture', () async {
      final e = await place(trails, 'Copper Hollow Trailhead', 43.2, -115.1);
      connected.value = true;
      await settle();
      await notebooks.saveEntry(id: e.id, notebookId: trails.id, occurredAt: e.occurredAt, title: e.title, place: e.place, props: {'icon': 'home', 'color': 'orange'});
      await settle();
      expect(sent, hasLength(2));
      final name = pinImageId(PinStyle.icon, 'home', markerColor('orange').color);
      expect(images(sent.last).keys, [name]);
      expect([for (final f in features(sent.last)) f['properties']['pin']], contains(name));
    });

    test("a notebook's map switch and a repeater list's switch take their pins off the car's map", () async {
      await place(trails, 'Copper Hollow Trailhead', 43.2, -115.1);
      connected.value = true;
      await settle();
      expect(features(sent.last), hasLength(2));

      await notebooks.setOnMap(notebooks.notebook(trails.id)!, false);
      await settle();
      expect(coords(sent.last), [
        [-115.21, 43.11],
      ]);

      repeaters.shown = false;
      await repeaters.state.reload();
      await settle();
      expect(features(sent.last), isEmpty);
    });

    test('a place switched off the map on its own is left out, as on the phone', () async {
      await place(trails, 'Copper Hollow Trailhead', 43.2, -115.1, props: {'on_map': false});
      connected.value = true;
      await settle();
      expect(coords(sent.single), [
        [-115.21, 43.11],
      ]);
    });

    test('another pin style: the car drops its pictures and gets them in the new style', () async {
      await place(trails, 'Copper Hollow Trailhead', 43.2, -115.1);
      connected.value = true;
      await settle();
      style.value = PinStyle.teardrop;
      await settle();
      expect(sent, hasLength(2));
      expect(sent.last['reset'], isTrue);
      final names = {for (final f in features(sent.last)) f['properties']['pin'] as String};
      expect(names, everyElement(startsWith('pin-teardrop-')));
      expect(images(sent.last).keys.toSet(), names);
    });

    test("a Tactical car map gets Tactical pictures (the theme's red), and back", () async {
      await place(trails, 'Copper Hollow Trailhead', 43.2, -115.1);
      connected.value = true;
      await settle();
      pins.setTactical(true);
      await settle();
      expect(sent, hasLength(2));
      expect(sent.last['reset'], isTrue);
      final names = [for (final f in features(sent.last)) f['properties']['pin'] as String];
      expect(names.first, repeaterPinName(PinStyle.icon, tactical: true));
      expect(names, everyElement(startsWith('pin-icon-t-')));
      pins.setTactical(false);
      await settle();
      expect(sent, hasLength(3));
      expect(features(sent.last).first['properties']['pin'], repeaterPinName(PinStyle.icon));
    });

    test('a car that connects again gets every pin and picture again', () async {
      await place(trails, 'Copper Hollow Trailhead', 43.2, -115.1);
      connected.value = true;
      await settle();
      connected.value = false;
      await settle();
      connected.value = true;
      await settle();
      expect(sent, hasLength(2));
      expect(sent.last['reset'], isTrue);
      expect(images(sent.last).keys.toSet(), images(sent.first).keys.toSet());
      expect(sent.last['geojson'], sent.first['geojson']);
    });

    test('a burst of changes is one message', () async {
      final slow = CarPins(
        read: ({required bool tactical}) => readMapPins(notebooks, repeaters.state, tactical: tactical),
        pinStyle: () => style.value,
        changes: [notebooks],
        render: _fakePng,
        debounce: const Duration(milliseconds: 50),
      );
      final got = <Object?>[];
      final on = ValueNotifier(true);
      slow.bind(connected: on, send: (m, a) async => got.add(a));
      await settle(80);
      expect(got, hasLength(1));
      await place(trails, 'Copper Hollow Trailhead', 43.2, -115.1);
      await place(trails, 'Juniper Spring', 43.25, -115.15);
      await place(trails, 'Elk Meadow', 43.27, -115.17);
      await settle(150);
      expect(got, hasLength(2));
      slow.dispose();
      on.dispose();
    });
  });

  group('through the car bridge', () {
    const channel = MethodChannel('co.cache/car');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    late Directory dir;
    late LocationService location;
    late NavState nav;
    late MapsState maps;
    late CarBridge bridge;
    // The phone's chosen theme, as the bridge reads it.
    var chosen = CacheThemeId.tactical;
    late List<MethodCall> toCar;
    late CarPins bridged;

    Future<Object?> fromCar(String method, [Object? args]) async {
      final c = Completer<Object?>();
      await messenger.handlePlatformMessage(channel.name, const StandardMethodCodec().encodeMethodCall(MethodCall(method, args)), (data) {
        c.complete(data == null ? null : const StandardMethodCodec().decodeEnvelope(data));
      });
      return c.future;
    }

    setUp(() async {
      dir = Directory.systemTemp.createTempSync('car-pins');
      chosen = CacheThemeId.tactical;
      location = LocationService(source: _NoSource(), settingsDirOverride: dir);
      await location.init();
      final gps = FakeNavPosition();
      late final CarDriveSource drive;
      nav = NavState(
        backend: FakeBackend(),
        location: location,
        speaker: FakeSpeaker(),
        positionSource: drive = CarDriveSource(gps, route: () => nav.route, tick: const Duration(milliseconds: 10)),
        simulatedDrive: () => drive.simulating,
        fmt: const Fmt(UnitSystem.imperial),
        clock: () => DateTime(2026, 11, 12, 12),
      );
      maps = MapsState(engine: TestLayerEngine(), settingsDirOverride: dir);
      toCar = [];
      messenger.setMockMethodCallHandler(channel, (call) async {
        toCar.add(call);
        return null;
      });
      await place(trails, 'Copper Hollow Trailhead', 43.2, -115.1);
      bridged = CarPins(
        read: ({required bool tactical}) => readMapPins(notebooks, repeaters.state, tactical: tactical),
        pinStyle: () => maps.pinStyle,
        changes: [notebooks, repeaters.state],
        pinStyleChanges: maps,
        render: _fakePng,
        debounce: Duration.zero,
      );
      bridge = CarBridge(
        nav: nav,
        maps: maps,
        drive: drive,
        theme: () => chosen,
        pins: bridged,
        throttle: const Duration(milliseconds: 5),
        glyphs: () async => 'file:///g/{fontstack}/{range}.pbf',
      );
      await bridge.start();
    });

    tearDown(() async {
      bridge.dispose();
      await nav.end();
      nav.dispose();
      maps.dispose();
      location.dispose();
      messenger.setMockMethodCallHandler(channel, null);
      dir.deleteSync(recursive: true);
    });

    Iterable<MethodCall> pinCalls() => toCar.where((c) => c.method == 'pins');

    test('the car connecting gets the pins; positions coming in send none', () async {
      await fromCar('connected', {'on': true});
      await settle();
      expect(pinCalls(), hasLength(1));
      for (var i = 0; i < 5; i++) {
        location.publish(fixAt(43.1 + i * 0.001, -115.2));
        await settle(15);
      }
      expect(toCar.where((c) => c.method == 'trip'), isNotEmpty, reason: 'the positions did reach the car');
      expect(pinCalls(), hasLength(1));
    });

    test("the pictures are Tactical whenever the phone's theme is, by day and by night; the theme changing switches them once", () async {
      await maps.engine.start();
      await fromCar('connected', {'on': true});
      await settle();
      expect(((pinCalls().last.arguments as Map)['images'] as Map).keys, everyElement(isNot(contains('-t-'))));
      // The car's style in the chosen Tactical (the car says day): Tactical pictures, one push.
      await fromCar('style', {'dark': false});
      await settle();
      expect(pinCalls(), hasLength(2));
      expect(((pinCalls().last.arguments as Map)['images'] as Map).keys, everyElement(contains('-t-')));
      // Its night style is the same Tactical: nothing new to send.
      await fromCar('style', {'dark': true});
      await settle();
      expect(pinCalls(), hasLength(2));
      // The phone's theme changes to Dark: the next style turns them back, one push, by night as by day.
      chosen = CacheThemeId.dark;
      await fromCar('style', {'dark': true});
      await settle();
      expect(pinCalls(), hasLength(3));
      expect(((pinCalls().last.arguments as Map)['images'] as Map).keys, everyElement(isNot(contains('-t-'))));
      await fromCar('style', {'dark': false});
      await settle();
      expect(pinCalls(), hasLength(3));
      // And to Tactical again: Tactical, one push.
      chosen = CacheThemeId.tactical;
      await fromCar('style', {'dark': true});
      await settle();
      expect(pinCalls(), hasLength(4));
      expect(((pinCalls().last.arguments as Map)['images'] as Map).keys, everyElement(contains('-t-')));
    });

    test('the pin style changing sends the pins again in it, beside the style reload', () async {
      await fromCar('connected', {'on': true});
      await settle();
      maps.setPinStyle(PinStyle.badge);
      await settle();
      expect(pinCalls(), hasLength(2));
      expect(((pinCalls().last.arguments as Map)['images'] as Map).keys, everyElement(startsWith('pin-badge-')));
    });
  });
}
