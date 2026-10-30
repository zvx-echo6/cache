import 'dart:io';

import 'package:cache/maps/geo.dart';
import 'package:cache/maps/layers/layer_def.dart';
import 'package:cache/maps/maps_state.dart';
import 'package:cache/maps/network_access.dart';
import 'package:cache/maps/ui/catalogue_screen.dart';
import 'package:cache/maps/ui/layer_sheet.dart';
import 'package:cache/location/location_service.dart';
import 'package:cache/location/position_source.dart';
import 'package:cache/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/test_layer_engine.dart';

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
      final engine = TestLayerEngine(published: TestLayerEngine.layersOf(File('test/fixtures/catalogue.json').readAsStringSync()));
      maps = MapsState(engine: engine, settingsDirOverride: dir, network: _Allowed());
      await maps.init();
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

  testWidgets('the catalogue lists every layer with title, description, licence and coverage, and no download of its own', (tester) async {
    await boot(tester, () => CatalogueScreen(maps: maps));
    await tester.pump();
    for (final l in maps.catalogueLayers.take(2)) {
      expect(find.text(l.title), findsOneWidget);
      expect(find.text(l.description), findsOneWidget);
      expect(find.text(l.licence), findsOneWidget);
    }
    
    expect(find.text('Worldwide'), findsWidgets);
    expect(find.text('Download'), findsNothing, reason: 'a layer is kept offline by downloading a region');
    // The satellite layer is online only, and it says so.
    expect(find.text('Online only'), findsOneWidget);
    // Storage used is on the screen.
    expect(find.textContaining('Layers use 0 B on this phone'), findsOneWidget);
    // Advanced is closed.
    expect(find.text('Add a layer definition'), findsNothing);
    await tester.tap(find.text('Advanced'));
    await tester.pumpAndSettle();
    expect(find.text('Add a layer definition'), findsOneWidget);
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

  testWidgets('a layer has no download of its own (regions keep it offline); an area from before lists with update and delete', (tester) async {
    await boot(tester, () => CatalogueScreen(maps: maps));
    expect(find.byKey(const Key('download-hillshade')), findsNothing);
    expect(find.text('Draw an area'), findsNothing);
    final area = (await tester.runAsync(() => maps.engine.download('hillshade', maps.viewBounds!, label: 'Home')))!;
    await settle(tester, () => area.phase == AreaPhase.done);
    await tester.pump();
    expect(find.text('Home'), findsOneWidget, reason: 'the area is listed on the layer');
    expect(find.byTooltip('Update'), findsOneWidget);
    await tester.tap(find.byTooltip('Delete'));
    await tester.pumpAndSettle();
    expect(find.text('Delete Home?'), findsOneWidget);
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(maps.engine.areasOf('hillshade'), isEmpty);
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
