import 'package:cache/notebook/map_icons.dart';
import 'package:cache/notebook/notebook_map.dart';
import 'package:cache/notebook/notebook_model.dart';
import 'package:cache/notebook/pin_image.dart';
import 'package:cache/notebook/place_style.dart';
import 'package:cache/notebook/places.dart';
import 'package:cache/screens/notebooks/icon_picker.dart';
import 'package:cache/screens/notebooks/map_spot_picker.dart';
import 'package:cache/screens/notebooks/notebook_screen.dart';
import 'package:cache/screens/notebooks/places_screen.dart';
import 'package:cache/theme.dart';
import 'package:cache/weather/place_alerts.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/notebook_fake.dart';

const PlaceChoices _places = PlaceChoices(here: _here, saved: _saved);
Future<({double lat, double lon})?> _here() async => (lat: 43.47, lon: -112.01);
Future<List<NbPlace>> _saved() async => const [];

void main() {
  testWidgets('the place form\'s map and the full-screen picker draw the place\'s current icon and colour, live', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final nb = fakeNotebook(FakeNotebookBackend());
    late Notebook book;
    await tester.runAsync(() async {
      await nb.start();
      book = await nb.ensureSavedPlaces();
    });
    PinLook? seen;
    final deps = NotebookDeps(
      notebook: nb,
      places: _places,
      icons: MapIconSetup.fixed(pinStyle: PinStyle.teardrop),
      placesDeps: PlaceNotebookDeps(
        watched: (_) => false,
        setWatched: (_, _) {},
        alerts: PlaceAlerts.memory(),
        map: (context, pin, onPick, look) {
          seen = look;
          return const SizedBox(height: 100);
        },
        pickerMap: (context, target, onMoving, onCentre, onTap) => const SizedBox.expand(),
      ),
    );
    await tester.pumpWidget(MaterialApp(theme: buildTheme(CacheThemeId.light), home: PlaceForm(deps: deps, book: book, at: const NbPlace(lat: 43.6, lon: -116.2))));
    await tester.pumpAndSettle();

    // Nothing chosen on the place: the notebook's icon, else the template's, and the default colour.
    expect(seen!.icon.id, mapIconOrTemplate(book.def.icon ?? defaultNotebookIcon(book)).id);
    expect(seen!.tint, markerColor(null).color);

    // Another colour: the map's pin changes with it.
    final blue = kMarkerColors.firstWhere((c) => c.id == 'blue');
    await tester.tap(find.byKey(const ValueKey('swatch-blue')));
    await tester.pumpAndSettle();
    expect(seen!.tint, blue.color);

    // Another icon: the same.
    await tester.tap(find.byKey(const ValueKey('place-icon')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('icon-search')), 'camp');
    await tester.pumpAndSettle();
    await tester.tap(find.byWidgetPredicate((w) => w.key is ValueKey && (w.key as ValueKey).value.toString().endsWith('-camp')).first);
    await tester.pumpAndSettle();
    expect(seen!.icon.id, 'camp');
    expect(seen!.tint, blue.color);

    // The full-screen picker draws the same pin, in the person's Pin style.
    await tester.ensureVisible(find.byKey(const ValueKey('place-choose-on-map')));
    await tester.tap(find.byKey(const ValueKey('place-choose-on-map')));
    await tester.pumpAndSettle();
    final picker = tester.widget<MapSpotPicker>(find.byType(MapSpotPicker));
    expect(picker.icon, mapIcon('camp').icon);
    expect(picker.tint, blue.color);
    expect(picker.pinStyle, PinStyle.teardrop);
  });
}
