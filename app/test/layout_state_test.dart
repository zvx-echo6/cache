import 'dart:io';

import 'package:cache/layout/layout_state.dart';
import 'package:cache/layout/modules.dart';
import 'package:cache_search/cache_search.dart' show MapPlace;
import 'package:flutter_test/flutter_test.dart';

const hospital = MapPlace(
  id: 'place:osm:n4',
  type: 'place',
  name: 'Cassia Regional Hospital',
  kind: 'Hospital',
  address: '1501 Hiland Ave, Burley, ID',
  lat: 42.5,
  lon: -113.5,
  matched: 'name',
);

void main() {
  late Directory dir;
  late LayoutState layout;

  Future<LayoutState> open() async {
    final l = LayoutState(settingsDirOverride: dir);
    await l.init();
    return l;
  }

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('layout-state');
    layout = await open();
  });
  tearDown(() {
    layout.dispose();
    dir.deleteSync(recursive: true);
  });

  test('the default bar is Ask, Maps, Library and the default Home is Ask box, Weather, Alerts, Shortcuts', () {
    expect(layout.pinned, [ModuleId.ask, ModuleId.maps, ModuleId.library]);
    expect(layout.visibleBlocks, [HomeBlock.ask, HomeBlock.weather, HomeBlock.alerts, HomeBlock.shortcuts]);
    expect(layout.shortcuts, isEmpty);
  });

  test('the bar holds at most 3 pinned modules; a 4th is refused until one is replaced', () {
    expect(layout.barFull, isTrue);
    expect(layout.pin(ModuleId.videos), isFalse);
    expect(layout.pinned, [ModuleId.ask, ModuleId.maps, ModuleId.library]);
    layout.replace(ModuleId.library, ModuleId.videos);
    expect(layout.pinned, [ModuleId.ask, ModuleId.maps, ModuleId.videos]);
    // a module already on the bar cannot be put there twice
    layout.replace(ModuleId.ask, ModuleId.maps);
    expect(layout.pinned, [ModuleId.ask, ModuleId.maps, ModuleId.videos]);
  });

  test('unpin frees a slot and pin fills it again', () {
    layout.unpin(ModuleId.maps);
    expect(layout.pinned, [ModuleId.ask, ModuleId.library]);
    expect(layout.pin(ModuleId.settings), isTrue);
    expect(layout.pinned, [ModuleId.ask, ModuleId.library, ModuleId.settings]);
    expect(layout.pin(ModuleId.settings), isFalse, reason: 'already pinned');
  });

  test('the bar, the Home blocks and the shortcuts survive a restart', () async {
    layout.replace(ModuleId.library, ModuleId.videos);
    layout.setBlockOn(HomeBlock.weather, false);
    layout.moveBlock(3, 0); // Shortcuts to the top
    layout.addShortcut(Shortcut.module(ModuleId.videos));
    layout.addShortcut(Shortcut.place(hospital));
    layout.addShortcut(Shortcut.page(address: 'zim:0f4c0b5e-1111-4222-8333-444455556666/A/Burn', title: 'Burn', library: 'Medical'));
    layout.addShortcut(Shortcut.chat(id: 7, title: 'Treating burns'));
    layout.addShortcut(Shortcut.notebook(id: 'nb-1', name: 'Generator test', log: true));

    final again = await open();
    expect(again.pinned, [ModuleId.ask, ModuleId.maps, ModuleId.videos]);
    expect(again.blockOrder, [HomeBlock.shortcuts, HomeBlock.ask, HomeBlock.weather, HomeBlock.alerts]);
    expect(again.isOn(HomeBlock.weather), isFalse);
    expect(again.visibleBlocks, [HomeBlock.shortcuts, HomeBlock.ask, HomeBlock.alerts]);
    expect([for (final s in again.shortcuts) s.kind], ShortcutKind.values);
    final p = again.shortcuts[1].place!;
    expect((p.id, p.name, p.lat, p.lon, p.kind, p.address), (hospital.id, hospital.name, 42.5, -113.5, 'Hospital', hospital.address));
    expect(again.shortcuts[2].address, 'zim:0f4c0b5e-1111-4222-8333-444455556666/A/Burn');
    expect(again.shortcuts[3].chatId, 7);
    expect((again.shortcuts[4].notebookId, again.shortcuts[4].title, again.shortcuts[4].data['log']), ('nb-1', 'Log: Generator test', true));
    again.dispose();
  });

  test('Reset to default puts the blocks back and keeps the shortcuts', () async {
    layout.setBlockOn(HomeBlock.alerts, false);
    layout.moveBlock(0, 2);
    layout.addShortcut(Shortcut.module(ModuleId.videos));
    layout.resetBlocks();
    expect(layout.blockOrder, LayoutState.defaultBlocks);
    expect(layout.visibleBlocks, LayoutState.defaultBlocks);
    expect(layout.shortcuts, hasLength(1));
    final again = await open();
    expect(again.blockOrder, LayoutState.defaultBlocks);
    expect(again.shortcuts, hasLength(1));
    again.dispose();
  });

  test('a shortcut is added once, and can be moved and removed', () {
    expect(layout.addShortcut(Shortcut.module(ModuleId.videos)), isTrue);
    expect(layout.addShortcut(Shortcut.module(ModuleId.videos)), isFalse);
    layout.addShortcut(Shortcut.module(ModuleId.settings));
    layout.nudgeShortcut(layout.shortcuts[1], -1);
    expect([for (final s in layout.shortcuts) s.title], ['Settings', 'Videos']);
    layout.removeShortcut(layout.shortcuts.first);
    expect([for (final s in layout.shortcuts) s.title], ['Videos']);
  });

  test('a damaged file leaves the defaults', () async {
    File('${dir.path}/layout.json').writeAsStringSync('{not json');
    final again = await open();
    expect(again.pinned, LayoutState.defaultPinned);
    expect(again.visibleBlocks, LayoutState.defaultBlocks);
    again.dispose();
  });

  test('a saved file with too many or unknown pins is cut down to 3 known ones', () async {
    File('${dir.path}/layout.json').writeAsStringSync(
        '{"pinned":["videos","nope","ask","maps","library","videos"],"blocks":["shortcuts"],"off":[],"shortcuts":[]}');
    final again = await open();
    expect(again.pinned, [ModuleId.videos, ModuleId.ask, ModuleId.maps]);
    expect(again.blockOrder.first, HomeBlock.shortcuts);
    expect(again.blockOrder.toSet(), HomeBlock.values.toSet());
    again.dispose();
  });
}
