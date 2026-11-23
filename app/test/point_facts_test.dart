// The place card's quick wins: tap to call and to open, the elevation at the point, and who manages the land there.
// Elevation reads Terrarium tiles (the elevation layer); land reads the public-lands layer's vector tiles (PAD-US, `public_lands`).
// The tiles here are built in the test: a Terrarium PNG, and a vector tile written byte by byte to the specification.

import 'dart:io';
import 'dart:typed_data';

import 'package:cache/location/location_service.dart';
import 'package:cache/location/position_source.dart';
import 'package:cache/nav/elevation/route_sampler.dart';
import 'package:cache/nav/nav_state.dart';
import 'package:cache/nav/point_facts/elevation_at.dart';
import 'package:cache/nav/point_facts/land_at.dart';
import 'package:cache/nav/point_facts/mvt.dart';
import 'package:cache/nav/point_facts/point_facts.dart';
import 'package:cache/nav/ui/place_card.dart';
import 'package:cache/nav/ui/place_card_facts.dart';
import 'package:cache/nav/units.dart';
import 'package:cache/net/web_link.dart';
import 'package:cache/settings/data_policy.dart';
import 'package:cache/theme.dart';
import 'package:cache_search/cache_search.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'nav_fakes.dart';

// ---- a vector tile, written to the specification (protobuf) -------------------------------------------------------------

List<int> _varint(int n) {
  final out = <int>[];
  while (n >= 0x80) {
    out.add((n & 0x7F) | 0x80);
    n >>= 7;
  }
  out.add(n);
  return out;
}

List<int> _field(int field, int wire, List<int> body) => [..._varint(field * 8 + wire), if (wire == 2) ..._varint(body.length), ...body];
List<int> _bytesField(int field, List<int> body) => _field(field, 2, body);
List<int> _varField(int field, int v) => _field(field, 0, _varint(v));
int _zig(int n) => n >= 0 ? n * 2 : (-n) * 2 - 1;

/// A polygon geometry: each ring as corner points in tile units; MoveTo, LineTo and ClosePath with deltas.
List<int> _geometry(List<List<(int, int)>> rings) {
  final g = <int>[];
  var cx = 0, cy = 0;
  for (final ring in rings) {
    g.add((1 & 7) | (1 << 3));
    g..add(_zig(ring.first.$1 - cx))..add(_zig(ring.first.$2 - cy));
    cx = ring.first.$1;
    cy = ring.first.$2;
    g.add(2 | ((ring.length - 1) << 3));
    for (final p in ring.skip(1)) {
      g..add(_zig(p.$1 - cx))..add(_zig(p.$2 - cy));
      cx = p.$1;
      cy = p.$2;
    }
    g.add(7 | (1 << 3));
  }
  return g;
}

typedef _Poly = ({Map<String, Object> props, List<List<(int, int)>> rings});

Uint8List _tile(List<_Poly> polys, {String layer = 'public_lands'}) {
  final keys = <String>[];
  final values = <Object>[];
  final features = <int>[];
  for (final p in polys) {
    final tags = <int>[];
    p.props.forEach((k, v) {
      var ki = keys.indexOf(k);
      if (ki < 0) {
        keys.add(k);
        ki = keys.length - 1;
      }
      var vi = values.indexOf(v);
      if (vi < 0) {
        values.add(v);
        vi = values.length - 1;
      }
      tags..add(ki)..add(vi);
    });
    final geom = _geometry(p.rings);
    features.addAll(_bytesField(2, [
      ..._bytesField(2, [for (final t in tags) ..._varint(t)]),
      ..._varField(3, 3),
      ..._bytesField(4, [for (final g in geom) ..._varint(g)]),
    ]));
  }
  final body = <int>[
    ..._bytesField(1, layer.codeUnits),
    ...features,
    for (final k in keys) ..._bytesField(3, k.codeUnits),
    for (final v in values) ..._bytesField(4, v is String ? _bytesField(1, v.codeUnits) : _varField(5, (v as num).toInt())),
    ..._varField(5, 4096),
    ..._varField(15, 2),
  ];
  // Fix up: the features were already wrapped with their own field header above; the layer holds them as they are.
  return Uint8List.fromList(_bytesField(3, body));
}

List<(int, int)> _square(int x0, int y0, int x1, int y1) => [(x0, y0), (x1, y0), (x1, y1), (x0, y1)];

_Poly _land(String category, String mang, String type, String unit, int acres, List<List<(int, int)>> rings) => (
      props: {'Category': category, 'Mang_Name': mang, 'Mang_Type': type, 'Own_Type': type, 'Unit_Nm': unit, 'GIS_Acres': acres},
      rings: rings,
    );

/// A tile that holds [polys], at z0 (one tile: the whole world), so a point maps to tile units by its longitude and latitude.
/// lon 0, lat 0 is the middle (2048, 2048); each 360/4096 degrees of longitude is one unit to the east.
LandTileFetch _serving(Uint8List bytes) => (z, x, y) async => LandTileData(bytes);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the vector tile reader', () {
    test('reads the attributes and the rings of a polygon, and the point test honors a hole', () {
      final t = _tile([
        _land('Fee', 'BLM', 'FED', 'Test Unit', 500, [_square(100, 100, 900, 900), _square(400, 400, 600, 600)]),
      ]);
      final layers = readMvtPolygons(t);
      expect(layers, hasLength(1));
      expect(layers.single.name, 'public_lands');
      expect(layers.single.extent, 4096);
      final p = layers.single.polygons.single;
      expect(p.properties['Mang_Name'], 'BLM');
      expect(p.properties['Unit_Nm'], 'Test Unit');
      expect(p.properties['GIS_Acres'], 500);
      expect(p.contains(200, 200), isTrue);
      expect(p.contains(500, 500), isFalse, reason: 'inside the hole');
      expect(p.contains(2000, 2000), isFalse);
    });

    test('bytes that are not a tile throw a FormatException', () {
      expect(() => readMvtPolygons(Uint8List.fromList([0x1a, 0xff, 0xff])), throwsFormatException);
    });
  });

  group('the land at a point', () {
    // lon 0, lat 0 at zoom 0 is tile unit (2048, 2048).
    test('names the manager from the layer: a Bureau of Land Management polygon', () async {
      final t = _tile([_land('Fee', 'BLM', 'FED', 'Craters Test', 100, [_square(1900, 1900, 2200, 2200)])]);
      final a = await landAt(0, 0, _serving(t), zoom: 0);
      expect(a!.hit, isNotNull);
      expect(a.text, 'Bureau of Land Management');
      expect(a.unit, 'Craters Test');
    });

    test('other managers: Forest Service, National Park Service, state land board, a city', () async {
      for (final (code, type, words) in [
        ('USFS', 'FED', 'Forest Service'),
        ('NPS', 'FED', 'National Park Service'),
        ('SLB', 'STAT', 'State land board'),
        ('CITY', 'LOC', 'City government'),
      ]) {
        final t = _tile([_land('Fee', code, type, '', 10, [_square(1900, 1900, 2200, 2200)])]);
        expect((await landAt(0, 0, _serving(t), zoom: 0))!.text, words);
      }
    });

    test('a manager code the card does not know falls back to the manager type, and to "not recorded" with neither', () async {
      var t = _tile([_land('Fee', 'ZZZ', 'STAT', '', 10, [_square(1900, 1900, 2200, 2200)])]);
      expect((await landAt(0, 0, _serving(t), zoom: 0))!.text, 'State agency');
      t = _tile([_land('Fee', 'UNK', 'UNK', '', 10, [_square(1900, 1900, 2200, 2200)])]);
      expect((await landAt(0, 0, _serving(t), zoom: 0))!.text, 'Public land, manager not recorded');
    });

    test('ownership (Fee) wins over a designation, an easement and a boundary that cover the same point', () async {
      final big = _square(1000, 1000, 3000, 3000);
      final t = _tile([
        _land('Proclamation', 'USFS', 'FED', 'National Forest', 9000, [big]),
        _land('Easement', 'NGO', 'NGO', '', 50, [_square(1900, 1900, 2200, 2200)]),
        _land('Designation', 'USFS', 'FED', 'Wilderness', 300, [_square(1900, 1900, 2200, 2200)]),
        _land('Fee', 'BLM', 'FED', 'Parcel', 20, [_square(1900, 1900, 2200, 2200)]),
      ]);
      expect((await landAt(0, 0, _serving(t), zoom: 0))!.text, 'Bureau of Land Management');
    });

    test('a proclaimed boundary alone says it may include private land; an easement alone says it may be private', () async {
      var t = _tile([_land('Proclamation', 'USFS', 'FED', 'Forest', 9000, [_square(1000, 1000, 3000, 3000)])]);
      expect((await landAt(0, 0, _serving(t), zoom: 0))!.text, 'Inside the boundary of Forest Service (may include private land)');
      t = _tile([_land('Easement', 'NGO', 'NGO', '', 90, [_square(1000, 1000, 3000, 3000)])]);
      expect((await landAt(0, 0, _serving(t), zoom: 0))!.text, 'Easement held by Nonprofit conservation group (the land may be private)');
    });

    test('no area at the point: "Not public land in our data", which does not say private', () async {
      final t = _tile([_land('Fee', 'BLM', 'FED', 'Elsewhere', 10, [_square(100, 100, 300, 300)])]);
      final a = await landAt(0, 0, _serving(t), zoom: 0);
      expect(a!.hit, isNull);
      expect(a.text, 'Not public land in our data');
      expect(a.text.toLowerCase(), isNot(contains('private')));
      // A point in the hole of an area is not in the area.
      final holed = _tile([_land('Fee', 'BLM', 'FED', '', 10, [_square(1000, 1000, 3000, 3000), _square(1900, 1900, 2200, 2200)])]);
      expect((await landAt(0, 0, _serving(holed), zoom: 0))!.hit, isNull);
    });

    test('a tile the source does not have is "nothing mapped here"; a tile that cannot be had is no answer', () async {
      expect((await landAt(0, 0, (z, x, y) async => const LandTileEmpty(), zoom: 0))!.text, 'Not public land in our data');
      expect(await landAt(0, 0, (z, x, y) async => const LandTileUnavailable(), zoom: 0), isNull);
    });

    test('bytes that are not a tile, or a tile of another layer: no answer, never a guess', () async {
      expect(await landAt(0, 0, (z, x, y) async => LandTileData(Uint8List.fromList([0x1a, 0xff, 0xff])), zoom: 0), isNull);
      expect(await landAt(0, 0, _serving(_tile([_land('Fee', 'BLM', 'FED', '', 1, [_square(1900, 1900, 2200, 2200)])], layer: 'roads')), zoom: 0), isNull);
    });

    test('asks for the tile that holds the point', () async {
      final asked = <(int, int, int)>[];
      await landAt(43.5, -114.5, (z, x, y) async {
        asked.add((z, x, y));
        return const LandTileEmpty();
      }, zoom: 12);
      expect(asked.single, (12, 745, 1497));
    });
  });

  group('the elevation at a point', () {
    // A Terrarium tile: every pixel [h] metres (height = R * 256 + G + B / 256 - 32768).
    Uint8List terrarium(double Function(int x, int y) h) {
      final im = img.Image(width: 512, height: 512, numChannels: 3);
      for (var y = 0; y < 512; y++) {
        for (var x = 0; x < 512; x++) {
          final v = ((h(x, y) + 32768) * 256).round();
          im.setPixelRgb(x, y, (v >> 16) & 255, (v >> 8) & 255, v & 255);
        }
      }
      return Uint8List.fromList(img.encodePng(im));
    }

    test('reads the height of the tile under the point (zoom 0 is one tile: lon 0, lat 0 is its middle)', () async {
      final tiles = _Dem({'0/0/0': terrarium((x, y) => 1500)});
      expect(await elevationAt(0, 0, tiles, zoom: 0), closeTo(1500, 0.01));
    });

    test('is bilinear between pixels: a slope reads the height between two pixel centres', () async {
      // Height grows 2 m per pixel to the east. The point lon 0 is the edge between pixel 255 and 256 (centres 255.5 and 256.5).
      final tiles = _Dem({'0/0/0': terrarium((x, y) => 100.0 + 2 * x)});
      expect(await elevationAt(0, 0, tiles, zoom: 0), closeTo(611, 0.1));
    });

    test('a below-sea-level height reads as it is (Terrarium has negative heights)', () async {
      final tiles = _Dem({'0/0/0': terrarium((x, y) => -86)});
      expect(await elevationAt(0, 0, tiles, zoom: 0), closeTo(-86, 0.01));
    });

    test('no tile for the spot, or a tile that is not an image: none, not a guess', () async {
      expect(await elevationAt(0, 0, _Dem({}), zoom: 0), isNull);
      expect(await elevationAt(0, 0, _Dem({'0/0/0': Uint8List.fromList([1, 2, 3])}), zoom: 0), isNull);
    });
  });

  group('on the place card', () {
    late Directory dir;
    late LocationService location;
    late NavState nav;
    final opened = <String>[];
    final copied = <String>[];
    late _OfflineProbe probe;

    setUp(() async {
      dir = Directory.systemTemp.createTempSync('place-facts');
      location = LocationService(source: _NoSource(), settingsDirOverride: dir);
      await location.init();
      location.publish(fixAt(42.5, -113.8));
      nav = NavState(backend: FakeBackend(), location: location, speaker: FakeSpeaker(), positionSource: FakeNavPosition(), fmt: const Fmt(UnitSystem.imperial));
      opened.clear();
      copied.clear();
      probe = _OfflineProbe(ConnectionKind.wifi);
      WebLinks.probe = probe;
      WebLinks.open = (u) async => opened.add(u);
      WebLinks.copy = (t) async => copied.add(t);
    });
    tearDown(() {
      nav.dispose();
      location.dispose();
      dir.deleteSync(recursive: true);
    });

    MapPlace place({String? phone, String? website}) => MapPlace(id: 'place:t', type: 'place', name: 'Test Cafe', kind: 'Cafe', lat: 42.56, lon: -114.46, matched: 'name', phone: phone, website: website);

    Widget card(MapPlace p, {PointFacts? facts, Fmt fmt = const Fmt(UnitSystem.imperial)}) => MaterialApp(
          theme: buildTheme(CacheThemeId.light),
          home: Scaffold(body: PlaceCard(nav: nav, place: p, fmt: fmt, onClose: () {}, facts: facts)),
        );

    PointFacts facts({double? elevation, LandAnswer? land}) => PointFacts(elevationM: (_, _) async => elevation, land: (_, _) async => land);

    testWidgets('a tap on the phone row opens the dialer with the number, says so, and the text stays', (tester) async {
      await tester.pumpWidget(card(place(phone: '(208) 555-0100')));
      await tester.tap(find.byKey(const ValueKey('place-phone')));
      await tester.pump();
      expect(opened, ['tel:2085550100']);
      expect(find.text('Opening the phone app'), findsOneWidget);
      expect(find.text('(208) 555-0100'), findsOneWidget);
    });

    testWidgets('an international number keeps its plus', (tester) async {
      await tester.pumpWidget(card(place(phone: '+1 208-555-0100')));
      await tester.tap(find.byKey(const ValueKey('place-phone')));
      await tester.pump();
      expect(opened, ['tel:+12085550100']);
    });

    testWidgets('a phone that cannot dial says so and offers Copy number', (tester) async {
      WebLinks.open = (u) async => throw Exception('no dialer');
      await tester.pumpWidget(card(place(phone: '208 555 0100')));
      await tester.tap(find.byKey(const ValueKey('place-phone')));
      await tester.pump();
      await tester.pump();
      expect(find.textContaining("Couldn't open the phone app"), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 800));
      await tester.tap(find.text('Copy number'));
      await tester.pump();
      expect(copied, ['208 555 0100']);
    });

    testWidgets('the copy button and a long press still copy the text', (tester) async {
      await tester.pumpWidget(card(place(phone: '208 555 0100', website: 'example.org')));
      await tester.tap(find.byKey(const ValueKey('copy-Copy number')));
      await tester.pump();
      expect(find.text('Copied'), findsOneWidget);
      await tester.longPress(find.byKey(const ValueKey('place-website')));
      await tester.pump();
      expect(find.text('Copied'), findsOneWidget);
    });

    testWidgets('a tap on the website row opens it in the browser (https added to a bare domain)', (tester) async {
      await tester.pumpWidget(card(place(website: 'example.org/menu')));
      await tester.tap(find.byKey(const ValueKey('place-website')));
      await tester.pump();
      await tester.pump();
      expect(opened, ['https://example.org/menu']);
      expect(find.text('Opening the website'), findsOneWidget);
      expect(find.text('example.org/menu'), findsOneWidget);
    });

    testWidgets('offline, the website says so with Copy link, and the browser is not called', (tester) async {
      probe.kind = ConnectionKind.none;
      await tester.pumpWidget(card(place(website: 'https://example.org')));
      await tester.tap(find.byKey(const ValueKey('place-website')));
      await tester.pump();
      await tester.pump();
      expect(opened, isEmpty);
      expect(find.text("You're offline"), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 800));
      await tester.tap(find.text('Copy link'));
      await tester.pump();
      expect(copied, ['https://example.org']);
    });

    testWidgets('a browser that fails shows a message with Copy link', (tester) async {
      WebLinks.open = (u) async => throw Exception('no browser');
      await tester.pumpWidget(card(place(website: 'https://example.org')));
      await tester.tap(find.byKey(const ValueKey('place-website')));
      await tester.pump();
      await tester.pump();
      expect(find.textContaining("Couldn't open the website"), findsOneWidget);
    });

    testWidgets('an address that is not a web address is not opened', (tester) async {
      await tester.pumpWidget(card(place(website: 'javascript:alert(1)')));
      await tester.tap(find.byKey(const ValueKey('place-website')));
      await tester.pump();
      expect(opened, isEmpty);
      expect(find.text('This web address cannot be opened'), findsOneWidget);
    });

    testWidgets('elevation: feet by the unit setting, metres for metric, and nothing when there is no data', (tester) async {
      await tester.pumpWidget(card(place(), facts: facts(elevation: 1500)));
      await tester.pump();
      expect(find.text('Elevation: 4921 ft'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(card(place(), facts: facts(elevation: 1500), fmt: const Fmt(UnitSystem.metric)));
      await tester.pump();
      expect(find.text('Elevation: 1500 m'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(card(place(), facts: facts()));
      await tester.pump();
      expect(find.byKey(const ValueKey('place-card-elevation')), findsNothing);
      expect(find.textContaining('Elevation'), findsNothing);
    });

    testWidgets('land: the manager, the unit, and the honest words when the layer has no area', (tester) async {
      const bl = LandHit(category: 'Fee', manager: 'BLM', managerType: 'FED', ownerType: 'FED', unit: 'Test Field Office', acres: 10);
      await tester.pumpWidget(card(place(), facts: facts(land: const LandAnswer(bl))));
      await tester.pump();
      expect(find.text('Land: Bureau of Land Management'), findsOneWidget);
      expect(find.text('Test Field Office'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(card(place(), facts: facts(land: const LandAnswer(null))));
      await tester.pump();
      expect(find.text('Land: Not public land in our data'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(card(place(), facts: facts()));
      await tester.pump();
      expect(find.byKey(const ValueKey('place-card-land')), findsNothing);
    });

    testWidgets('a lookup that fails shows nothing and does not break the card', (tester) async {
      final f = PointFacts(elevationM: (_, _) async => throw Exception('x'), land: (_, _) async => throw Exception('y'));
      await tester.pumpWidget(card(place(phone: '2085550100'), facts: f));
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.textContaining('Elevation'), findsNothing);
      expect(find.textContaining('Land:'), findsNothing);
      expect(find.text('2085550100'), findsOneWidget);
    });

    testWidgets('a card with no lookups (an area) leaves both rows out', (tester) async {
      await tester.pumpWidget(card(place()));
      await tester.pump();
      expect(find.byKey(const ValueKey('place-card-elevation')), findsNothing);
      expect(find.byKey(const ValueKey('place-card-land')), findsNothing);
    });
  });

  group('the numbers and addresses', () {
    test('telUri', () {
      expect(telUri('(208) 555-0100'), 'tel:2085550100');
      expect(telUri('+1 (208) 555.0100'), 'tel:+12085550100');
      expect(telUri('call us'), isNull);
    });
    test('webUri', () {
      expect(webUri('example.org')!.toString(), 'https://example.org');
      expect(webUri('http://example.org/a')!.toString(), 'http://example.org/a');
      expect(webUri('mailto:a@b.org'), isNull);
      expect(webUri('example.org:8080/x')!.toString(), 'https://example.org:8080/x');
      expect(webUri(' '), isNull);
    });
  });
}

class _Dem implements DemTiles {
  _Dem(this.tiles);
  final Map<String, Uint8List> tiles;
  @override
  Future<Uint8List?> tile(int z, int x, int y) async => tiles['$z/$x/$y'];
}

class _OfflineProbe implements ConnectionProbe {
  _OfflineProbe(this.kind);
  ConnectionKind kind;
  @override
  Future<ConnectionKind> current() async => kind;
  @override
  Stream<ConnectionKind> get changes => const Stream.empty();
}

class _NoSource implements PositionSource {
  @override
  Future<LocationPermissionState> permission() async => LocationPermissionState.granted;
  @override
  Future<LocationPermissionState> requestPermission() async => LocationPermissionState.granted;
  @override
  Future<bool> serviceEnabled() async => true;
  @override
  Future<Fix> current() async => fixAt(42.5, -113.8);
  @override
  Stream<Fix> stream() => const Stream.empty();
  @override
  Future<void> openAppSettings() async {}
  @override
  Future<void> openLocationSettings() async {}
}
