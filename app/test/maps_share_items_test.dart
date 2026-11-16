import 'package:cache/sharing/share_items.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/test_layer_engine.dart';

void main() {
  // Maps sync with one writer per file: what a device shares of a map layer is its own snapshot, store-share/<layer>/<device>.sqlite.
  test('a layer on a linked device is the snapshot it shares; its delete record and an old build\'s live store are not items', () {
    final engine = TestLayerEngine();
    final snap = mapRemoteItem(engine, 'maps', 'store-share/basemap/abc123.sqlite', 10);
    expect(snap, isNotNull);
    expect(snap!.path, 'store-share/basemap');
    expect(snap.share, 'maps');
    expect(mapRemoteItem(engine, 'maps', 'store-share/abc123.deletes.json', 10), isNull, reason: 'travels with the kind');
    expect(mapRemoteItem(engine, 'maps', 'store/basemap.sqlite', 10), isNull, reason: 'an older build\'s live store is no longer shared');
    expect(mapRemoteItem(engine, 'maps', 'catalogue.json', 10), isNull);
    final regions = mapRemoteItem(engine, 'regions', 'regions-share/abc123.json', 10);
    expect(regions!.path, '**');
  });
}
