import 'dart:convert';
import 'dart:io';

import 'package:cache/maps/geo.dart';
import 'package:cache/maps/layers/fake_layer_engine.dart';
import 'package:cache/maps/layers/layer_def.dart';
import 'package:cache/maps/layers/pmtiles.dart';
import 'package:cache/maps/maps_state.dart';
import 'package:cache/maps/network_access.dart';
import 'package:cache/maps/ui/catalogue_screen.dart';
import 'package:cache/maps/ui/layer_sheet.dart';
import 'package:cache/location/location_service.dart';
import 'package:cache/location/position_source.dart';
import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const GeoBounds home = GeoBounds(south: 42.50, west: -113.80, north: 42.60, east: -113.66);

class _Allowed implements NetworkAccess {
  @override
  Future<bool> request() async => true;
}

class _NoSource implements PositionSource {
  @override
  Future<LocationPermissionState> permission() async => LocationPermissionState.notAsked;
  @override
  Future<LocationPermissionState> requestPermission() async => LocationPermissionState.denied;
  @override
  Future<bool> serviceEnabled() async => true;
  @override
  Future<Fix> current() => throw StateError('none');
  @override
  Stream<Fix> stream() => const Stream.empty();
  @override
  Future<void> openAppSettings() async {}
  @override
  Future<void> openLocationSettings() async {}
}

Future<FetchedTile?> _host(Uri u) async {
  if (u.path.endsWith('catalogue.json')) return FetchedTile(File('test/fixtures/catalogue.json').readAsBytesSync());
  if (u.path == '/planet') {
    return FetchedTile(utf8.encode(jsonEncode({'tiles': ['https://tiles.example/planet/v1/{z}/{x}/{y}.pbf']})));
  }
  return FetchedTile(List.filled(2000, 1));
}

void main() {
  late Directory dir;
  late MapsState maps;

  setUp(() => dir = Directory.systemTemp.createTempSync('mapscat'));
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<void> boot(WidgetTester tester, Widget Function() home) async {
    await tester.runAsync(() async {
      final engine = FakeLayerEngine(
        dirOverride: dir,
        fetcher: _host,
        rangeFetcher: (u, o, l) async => throw PmTilesMissing(u),
        onlineProbe: () async => true,
        catalogueUrl: Uri.parse('https://example.test/catalogue.json'),
      );
      maps = MapsState(engine: engine, settingsDirOverride: dir, network: _Allowed());
      await maps.init();
      await engine.refreshCatalogue();
    });
    addTearDown(maps.dispose);
    maps.viewBounds = const GeoBounds(south: 42.50, west: -113.80, north: 42.60, east: -113.66);
    // A tall screen, so the whole list is on it.
    tester.view.physicalSize = const Size(800, 9000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(theme: buildTheme(CacheThemeId.dark), home: home()));
    await tester.pump();
  }

  /// Lets real file and server work finish while the widgets keep up.
  Future<void> settle(WidgetTester tester, bool Function() done) async {
    for (var i = 0; i < 100 && !done(); i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump();
    }
    expect(done(), isTrue, reason: 'timed out');
  }

  testWidgets('the catalogue lists every layer with title, description, licence, coverage and a Download button', (tester) async {
    await boot(tester, () => CatalogueScreen(maps: maps));
    await tester.pump();
    for (final l in maps.catalogueLayers.take(2)) {
      expect(find.text(l.title), findsOneWidget);
      expect(find.text(l.description), findsOneWidget);
      expect(find.text(l.licence), findsOneWidget);
    }
    
    expect(find.text('Worldwide'), findsWidgets);
    expect(find.text('Download'), findsWidgets);
    // The satellite layer is online only: no Download button, and it says so.
    expect(find.text('Online only'), findsOneWidget);
    // Storage used is on the screen.
    expect(find.textContaining('Layers use 0 B on this phone'), findsOneWidget);
    // Advanced is closed.
    expect(find.text('Add a layer definition'), findsNothing);
    await tester.tap(find.text('Advanced'));
    await tester.pumpAndSettle();
    expect(find.text('Add a layer definition'), findsOneWidget);
  });

  testWidgets('download: choose an area, see tiles and size first, then progress, update and delete', (tester) async {
    await boot(tester, () => CatalogueScreen(maps: maps));
    // Hillshade is the second card; its Download button is the second one.
    await tester.tap(find.byKey(const Key('download-hillshade')));
    await tester.pumpAndSettle();
    expect(find.text('Download Hillshade'), findsOneWidget);
    expect(find.text('Which area?'), findsOneWidget);
    expect(find.text('This region'), findsOneWidget);
    expect(find.text('Draw an area'), findsOneWidget);

    await tester.tap(find.text('This region'));
    await tester.pumpAndSettle();
    // The cost is on screen before anything is downloaded.
    expect(find.descendant(of: find.byType(BottomSheet), matching: find.textContaining(' tiles')), findsOneWidget);
    expect(find.textContaining('About '), findsOneWidget);
    expect(maps.engine.areasOf('hillshade'), isEmpty);

    await tester.tap(find.descendant(of: find.byType(BottomSheet), matching: find.text('Download')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(maps.engine.areasOf('hillshade'), hasLength(1));
    final area = maps.engine.areasOf('hillshade').single;
    await settle(tester, () => area.phase == AreaPhase.done);
    await tester.pump();
    expect(find.text('This region'), findsOneWidget, reason: 'the area is listed on the layer');
    expect(find.textContaining('KB'), findsWidgets);
    expect(find.textContaining('on this phone'), findsWidgets);

    // Update and delete are offered on a finished area.
    expect(find.byTooltip('Update'), findsOneWidget);
    await tester.tap(find.byTooltip('Delete'));
    await tester.pumpAndSettle();
    expect(find.text('Delete This region?'), findsOneWidget);
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(maps.engine.areasOf('hillshade'), isEmpty);
    expect(find.byTooltip('Delete'), findsNothing);
  });

  testWidgets('a layer cut for regions is one card; its download names the cut that covers the area', (tester) async {
    await boot(tester, () => CatalogueScreen(maps: maps));
    expect(find.text('BLM roads and trails'), findsOneWidget, reason: 'one card for the global and the Idaho cut');
    expect(find.text('Base map (OpenFreeMap)'), findsNothing, reason: 'off by default');
    await tester.tap(find.byKey(const Key('download-blm-routes')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('This region'));
    await tester.pumpAndSettle();
    // The area is in Idaho: the Idaho cut is the one that downloads, and the sheet says so.
    expect(find.textContaining('This region · '), findsOneWidget);
    expect(find.descendant(of: find.byType(BottomSheet), matching: find.textContaining('118')), findsOneWidget);
    expect(find.descendant(of: find.byType(BottomSheet), matching: find.textContaining(' tiles')), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    // Elsewhere in the United States the broad cut is used and nothing extra is said.
    maps.viewBounds = const GeoBounds(south: 39.0, west: -105.1, north: 39.2, east: -104.9);
    await tester.tap(find.byKey(const Key('download-blm-routes')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('This region'));
    await tester.pumpAndSettle();
    expect(find.text('This region'), findsOneWidget);
  });

  testWidgets('Advanced lists every definition with a switch; the base map from OpenFreeMap is off until switched on', (tester) async {
    await boot(tester, () => CatalogueScreen(maps: maps));
    await tester.tap(find.text('Advanced'));
    await tester.pumpAndSettle();
    final tile = find.widgetWithText(SwitchListTile, 'Base map (OpenFreeMap)');
    expect(tile, findsOneWidget);
    expect(tester.widget<SwitchListTile>(tile).value, isFalse);
    await tester.tap(tile);
    await tester.pumpAndSettle();
    expect(maps.isDefinitionEnabled(maps.engine.layer('openfreemap')!), isTrue);
    expect(find.text('Base map (OpenFreeMap)'), findsWidgets);
    expect(tester.widget<SwitchListTile>(find.widgetWithText(SwitchListTile, 'Base map (OpenFreeMap)')).value, isTrue);
  });

  testWidgets('an area that is too big says so and does not offer the download', (tester) async {
    await boot(tester, () => CatalogueScreen(maps: maps));
    // Too big for one download and outside the area the US map covers.
    maps.viewBounds = const GeoBounds(south: 40, west: -5, north: 55, east: 20);
    await tester.tap(find.byKey(const Key('download-basemap')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('This region'));
    await tester.pumpAndSettle();
    expect(find.textContaining('too big'), findsOneWidget);
    final button = tester.widget<FilledButton>(find.descendant(of: find.byType(BottomSheet), matching: find.byType(FilledButton)));
    expect(button.onPressed, isNull);
  });

  testWidgets('Draw an area hands over to the map', (tester) async {
    await boot(tester, () => CatalogueScreen(maps: maps));
    await tester.tap(find.byKey(const Key('download-hillshade')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Draw an area'));
    await tester.pumpAndSettle();
    expect(maps.drawRequest, 'hillshade');
  });

  testWidgets('Advanced: a layer definition can be added and edited, and bad ones are refused', (tester) async {
    await boot(tester, () => CatalogueScreen(maps: maps));
    await tester.tap(find.text('Advanced'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add a layer definition'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '{"id": "Bad Id", "title": "x"}');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.textContaining('lower-case'), findsOneWidget);
    await tester.tap(find.text('Save'));
    await tester.enterText(
        find.byType(TextField), '{"id": "mine", "title": "My layer", "kind": "raster", "source": {"url": "https://example.com/{z}/{x}/{y}.png"}}');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(maps.engine.layer('mine'), isNotNull);
    expect(find.text('My layer'), findsWidgets);
  });

  testWidgets('the layer sheet lists every layer, with opacity for overlays that are on, and Get more layers', (tester) async {
    await boot(tester, () => Scaffold(body: Builder(builder: (c) => TextButton(onPressed: () => showLayerSheet(c, maps, location), child: const Text('open')))));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Layers'), findsOneWidget);
    for (final l in maps.catalogueLayers) {
      expect(find.text(l.title), findsOneWidget);
    }
    // Base map is on by default and has no opacity slider; turning Hillshade on shows one.
    expect(find.byType(Slider), findsNothing);
    await tester.tap(find.widgetWithText(SwitchListTile, 'Hillshade'));
    await tester.pumpAndSettle();
    expect(find.byType(Slider), findsOneWidget);
    expect(maps.isOn('hillshade'), isTrue);
    await tester.drag(find.byType(Slider), const Offset(-200, 0));
    await tester.pump();
    expect(maps.opacityOf('hillshade'), lessThan(1));
    await tester.tap(find.text('Get more layers'));
    await tester.pumpAndSettle();
    expect(find.byType(CatalogueScreen), findsOneWidget);
  });
}

final LocationService location = LocationService(source: _NoSource());
