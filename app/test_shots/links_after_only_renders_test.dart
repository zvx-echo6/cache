// Batch 3 (a tap on the map opens a card), after only: the card each kind of tap opens, from the choice the Maps screen makes
// (map_tap.dart), drawn as the place card. The map itself is a platform view and is not drawn. Made-up names.
// flutter test test_shots/links_after_only_renders_test.dart --update-goldens  (pictures in test_shots/links/)

import 'package:cache/maps/map_tap.dart';
import 'package:cache/nav/ui/place_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test/support/drive_rig.dart';
import 'shot_kit.dart';

Future<void> _card(WidgetTester tester, List<TapFeature> hits, String file) async {
  phone(tester, size: const Size(390, 844));
  final r = DriveRig();
  await tester.runAsync(r.setUp);
  addTearDown(r.tearDown);
  final c = chooseMapTap(hits)!;
  await tester.pumpWidget(shotApp(Align(
    alignment: Alignment.bottomCenter,
    child: Material(child: PlaceCard(nav: r.nav, place: c.place, fmt: r.nav.fmt, onClose: () {})),
  )));
  await tester.pump();
  await snap(tester, 'links', '$file-after-only');
}

void main() {
  setUpAll(() async {
    await loadShotFonts();
  });

  testWidgets('04 a tapped map label', (tester) async {
    await _card(tester, [TapFeature(source: TapSource.basemap, tier: TapTier.label, name: 'Larkspur Flats', kind: '', lat: 42.51, lon: -113.52)], '04-label-card');
  });

  testWidgets('05 a tapped trail', (tester) async {
    await _card(tester, [TapFeature(source: TapSource.overlay, tier: TapTier.line, name: 'Hollow Fern Trail', kind: 'Test trails', lat: 42.6, lon: -113.4)], '05-trail-card');
  });
}
