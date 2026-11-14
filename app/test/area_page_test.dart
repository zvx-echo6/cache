import 'package:cache/downloads/download_row.dart';
import 'package:cache/maps/geo.dart';
import 'package:cache/maps/layers/layer_def.dart';
import 'package:cache/maps/ui/area_page.dart';
import 'package:cache/maps/ui/format.dart';
import 'package:cache/screens/settings/maps_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/settings_rig.dart';

/// A made-up area (open sea), so no real place is named.
const GeoBounds _box = GeoBounds(south: 0.10, west: -0.30, north: 0.20, east: -0.15);
const String _name = 'Example Ridge';

void main() {
  // The extents the page asked its small map to show.
  final drawn = <GeoBounds>[];

  setUp(() {
    drawn.clear();
    areaMapForTests = (context, extent) {
      drawn.add(extent);
      return const SizedBox.expand(key: ValueKey('stand-in-map'));
    };
  });
  tearDown(() => areaMapForTests = null);

  /// Settings > Maps with one map area downloaded (no regions: each area is a row of its own), on the rig's tall screen.
  Future<(SettingsRig, DownloadedArea)> boot(WidgetTester tester, {bool finish = true}) async {
    final r = await SettingsRig.create(tester);
    r.engine.clock = () => DateTime(2026, 6, 3, 10);
    r.engine.autoFinish = finish;
    await r.show(tester, MapsPage(deps: r.deps));
    final hill = r.maps.catalogueLayers.firstWhere((l) => l.id == 'hillshade');
    final a = await r.engine.download(hill.id, _box, label: _name);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump();
    return (r, a);
  }

  Future<void> open(WidgetTester tester, DownloadedArea a) async {
    await tester.tap(find.byKey(ValueKey('area-${a.id}')));
    await tester.pumpAndSettle();
  }

  testWidgets('the Settings > Maps row of a downloaded area opens its page', (tester) async {
    final (r, a) = await boot(tester);
    expect(a.phase, AreaPhase.done);
    await open(tester, a);
    expect(find.byType(AreaPage), findsOneWidget);
    expect(find.byType(MapsPage), findsNothing, reason: 'a page of its own, not the layers screen');
    await r.dispose(tester);
  });

  testWidgets('the page shows the extent map, the size, the date and what the area holds', (tester) async {
    final (r, a) = await boot(tester);
    await open(tester, a);
    // The small map, fitted to this area's extent.
    expect(find.byKey(const ValueKey('stand-in-map')), findsOneWidget);
    expect(drawn.last, _box);
    // Its name and size in the top bar.
    expect(find.text(_name), findsOneWidget);
    expect(find.byKey(const ValueKey('area-size')), findsOneWidget);
    expect(tester.widget<Text>(find.byKey(const ValueKey('area-size'))).data, formatBytes(a.bytes));
    // The Map part: ready, its size and the date it was fetched.
    final part = find.byKey(const ValueKey('part-map'));
    expect(part, findsOneWidget);
    expect(find.descendant(of: part, matching: find.textContaining('Ready · ${formatBytes(a.bytes)}')), findsOneWidget);
    expect(find.descendant(of: part, matching: find.textContaining(formatDate(DateTime(2026, 6, 3, 10)))), findsOneWidget);
    // What it holds, read from the layers drawn from its tiles: the hillshade card, and no directions, places or off-road (an area
    // holds one layer's tiles; those come with a region).
    expect(find.text('Map layers in this area'), findsOneWidget);
    expect(find.byKey(const ValueKey('area-layer-hillshade')), findsOneWidget);
    expect(find.text('Directions'), findsNothing);
    expect(find.text('Places'), findsNothing);
    expect(find.text('Off-road'), findsNothing);
    // Show on map, Update and Delete.
    expect(find.byKey(const ValueKey('area-show-on-map')), findsOneWidget);
    expect(find.byKey(const ValueKey('area-update')), findsOneWidget);
    expect(find.text('Delete $_name'), findsOneWidget);
    await r.dispose(tester);
  });

  testWidgets('Show on map and a tap on the small map ask for the Maps tab fitted to the area; a layer row for that layer', (tester) async {
    final (r, a) = await boot(tester);
    await open(tester, a);
    final asks = r.maps.asks;
    await tester.tap(find.byKey(const ValueKey('area-show-on-map')));
    await tester.pump();
    expect(r.maps.asks, asks + 1);
    expect(r.maps.takeAreaAsk(), _box);
    await tester.tap(find.byKey(const ValueKey('area-map-open')));
    await tester.pump();
    expect(r.maps.asks, asks + 2);
    expect(r.maps.takeAreaAsk(), _box);
    await tester.tap(find.byKey(const ValueKey('area-layer-hillshade')));
    await tester.pump();
    expect(r.maps.takeLayerAsk(), 'hillshade');
    await r.dispose(tester);
  });

  testWidgets('Update fetches the area again by the layers screen\'s way, and the page shows it downloading', (tester) async {
    final (r, a) = await boot(tester);
    await open(tester, a);
    r.engine.autoFinish = false;
    await tester.tap(find.byKey(const ValueKey('area-update')));
    await tester.pump();
    expect(a.phase, AreaPhase.running, reason: 'the engine\'s update was called');
    // Downloading: the Map part in the download pattern, and no Update while it runs.
    expect(find.descendant(of: find.byKey(const ValueKey('part-map')), matching: find.byType(DlStatus)), findsOneWidget);
    expect(find.byKey(const ValueKey('area-update')), findsNothing);
    r.engine.finishAll();
    await tester.pump();
    expect(find.byKey(const ValueKey('area-update')), findsOneWidget);
    await r.dispose(tester);
  });

  testWidgets('Delete asks with the layers screen\'s question; Keep keeps it, Delete removes it and closes the page', (tester) async {
    final (r, a) = await boot(tester);
    await open(tester, a);
    await tester.tap(find.byKey(const ValueKey('area-delete')));
    await tester.pumpAndSettle();
    expect(find.text('Delete $_name?'), findsOneWidget);
    expect(find.text('The downloaded tiles are removed from this device.'), findsOneWidget);
    await tester.tap(find.text('Keep'));
    await tester.pumpAndSettle();
    expect(r.engine.allAreas, hasLength(1));
    expect(find.byType(AreaPage), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('area-delete')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(r.engine.allAreas, isEmpty);
    expect(find.byType(AreaPage), findsNothing);
    expect(find.byType(MapsPage), findsOneWidget);
    await r.dispose(tester);
  });

  testWidgets('an area on its way shows where it stands, with Pause', (tester) async {
    final (r, a) = await boot(tester, finish: false);
    expect(a.phase, AreaPhase.running);
    a.doneTiles = (a.totalTiles / 2).ceil();
    a.bytes = a.doneTiles * 1000;
    await open(tester, a);
    final part = find.byKey(const ValueKey('part-map'));
    expect(find.descendant(of: part, matching: find.byType(DlStatus)), findsOneWidget);
    expect(find.byKey(const ValueKey('part-map-pause')), findsOneWidget);
    expect(find.byKey(const ValueKey('area-update')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('part-map-pause')));
    await tester.pump();
    expect(a.phase, AreaPhase.failed);
    expect(a.paused, isTrue);
    await r.dispose(tester);
  });

  testWidgets('an area that failed shows it failed, with its fix', (tester) async {
    final (r, a) = await boot(tester, finish: false);
    a
      ..phase = AreaPhase.failed
      ..error = 'connection lost'
      ..doneTiles = 1
      ..bytes = 1000;
    await open(tester, a);
    final part = find.byKey(const ValueKey('part-map'));
    final status = tester.widget<DlStatus>(find.descendant(of: part, matching: find.byType(DlStatus)));
    expect(status.state.phase, DlPhase.failed);
    expect(find.byKey(const ValueKey('area-update')), findsNothing);
    expect(find.byKey(const ValueKey('part-map-resume')), findsOneWidget);
    expect(find.byIcon(Icons.check_circle), findsNothing, reason: 'no tick on a part that is not there');
    await r.dispose(tester);
  });
}
