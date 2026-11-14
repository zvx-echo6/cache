// The full map credits (the sheet the credit line on the map opens) carry the ESA WorldCover credit only while the
// Protomaps-layout base map is drawn: its landcover layer is Daylight's landcover, made from ESA WorldCover 2020.
import 'package:cache/maps/layers/layer_def.dart';
import 'package:cache/maps/maps_state.dart';
import 'package:cache/maps/style/style_generator.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/layer_fixtures.dart';

LayerDef _def(String id) => LayerDef.fromJson(Map<String, dynamic>.from(testCatalogue.firstWhere((j) => j['id'] == id)));

void main() {
  const worldCover =
      '© ESA WorldCover project 2020 / Contains modified Copernicus Sentinel data (2020) processed by ESA WorldCover consortium. CC BY 4.0.';
  const daylight = 'Data from the Daylight Map Distribution';

  test('the full credits include the WorldCover line with the Protomaps base map', () {
    final base = _def('basemap');
    expect(base.layout, 'protomaps-v4');
    final notes = mapCreditNotes([StyleLayerUse(base)]);
    expect(notes, contains(worldCover));
    expect(notes, contains(daylight));
  });

  test('the full credits leave the WorldCover line out with another base map layout', () {
    final base = _def('openfreemap');
    expect(base.layout, 'openmaptiles');
    final notes = mapCreditNotes([StyleLayerUse(base)]);
    expect(notes, isNot(contains(worldCover)));
    expect(notes, isNot(contains(daylight)));
  });
}
