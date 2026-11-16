// A browser tab reads a settings file again when the server applied a change from a linked device (reload()): the value changes,
// listeners hear it, and nothing is written (the change came from the files, so a write back would only be an echo).

import 'dart:io';

import 'package:cache/layout/layout_state.dart';
import 'package:cache/layout/modules.dart';
import 'package:cache/sharing/settings_files.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/settings_rig.dart';
import 'support/weather_fakes.dart';

/// Every file under [dir] with its text, to prove nothing was written.
Map<String, String> snapshot(Directory dir) => {
  for (final e in dir.listSync(recursive: true).whereType<File>())
    e.path: e.lengthSync() < 1 << 20 ? e.readAsStringSync() : '',
};

void main() {
  late SettingsFiles files;

  /// Writes [value] for [key] behind the class's back, the way the server's settings sync does.
  Future<void> behind(SettingsRig r, String key, Object? value) async {
    files = SettingsFiles(IoSettingsFileAccess(r.dir));
    await files.write(key, value);
  }

  Future<void> noWrite(Map<String, String> before, Directory dir) async {
    await Future<void>.delayed(const Duration(milliseconds: 800)); // past MapsState's 500 ms save timer
    expect(snapshot(dir), before, reason: 'reload must not write anything');
  }

  testWidgets('AppState.reload reads settings.json again: theme, icons and the chosen model, and writes nothing', (tester) async {
    final r = await SettingsRig.create(tester);
    var heard = 0;
    r.app.addListener(() => heard++);
    await tester.runAsync(() async {
      await r.app.setTheme(r.app.theme); // makes settings.json
      await behind(r, 'appearance.theme', 'tactical');
      await behind(r, 'appearance.module_icons', 'large');
      await behind(r, 'ask.model', 'z.gguf');
      final before = snapshot(r.dir);
      final n = heard;
      await r.app.reload();
      expect(r.app.theme.name, 'tactical');
      expect(r.app.largeModuleIcons, isTrue);
      expect(r.app.chosenModelFile, 'z.gguf');
      expect(heard, greaterThan(n));
      await noWrite(before, r.dir);
    });
    await r.dispose(tester);
  });

  testWidgets('LayoutState.reload reads layout.json again: the bar, the blocks and the shortcuts, and writes nothing', (tester) async {
    final r = await SettingsRig.create(tester);
    final layout = LayoutState(settingsDirOverride: r.dir);
    var heard = 0;
    layout.addListener(() => heard++);
    await tester.runAsync(() async {
      await layout.init();
      layout.applyPinned(['weather']);
      await behind(r, 'home.bar', ['library', 'maps']);
      await behind(r, 'home.blocks', {'order': ['weather', 'ask'], 'off': ['shortcuts']});
      final before = snapshot(r.dir);
      final n = heard;
      await layout.reload();
      expect(layout.pinned, [ModuleId.library, ModuleId.maps]);
      expect(layout.pinnedNames, ['library', 'maps']);
      expect(layout.blocksJson['off'], contains('shortcuts'));
      expect(heard, greaterThan(n));
      await noWrite(before, r.dir);
    });
    layout.dispose();
    await r.dispose(tester);
  });

  testWidgets('AppSettings.reload reads preferences.json again, and writes nothing', (tester) async {
    final r = await SettingsRig.create(tester);
    var heard = 0;
    r.settings.addListener(() => heard++);
    await tester.runAsync(() async {
      r.settings.setWebSearchOn(false);
      await behind(r, 'ask.web_search', true);
      await behind(r, 'alerts.pop_up', 'none');
      await behind(r, 'weather.sources_on', ['river-a']);
      final before = snapshot(r.dir);
      final n = heard;
      await r.settings.reload();
      expect(r.settings.webSearchOn, isTrue);
      expect(r.settings.popUpFor.name, 'none');
      expect(r.settings.liveSourcesOn, {'river-a'});
      expect(heard, greaterThan(n));
      await noWrite(before, r.dir);
    });
    await r.dispose(tester);
  });

  testWidgets('MapsState.reload takes the layers on from maps.json and keeps the camera and the rest in memory, writing nothing', (tester) async {
    final r = await SettingsRig.create(tester);
    var heard = 0;
    r.maps.addListener(() => heard++);
    await tester.runAsync(() async {
      r.maps.setOpacity('landcover', 0.4);
      r.maps.rememberCamera(42.5, -113.8, 9);
      await r.maps.flush();
      await behind(r, 'maps.layers_on', ['hillshade']);
      final before = snapshot(r.dir);
      final n = heard;
      r.maps.reload();
      expect(r.maps.isOn('hillshade'), isTrue);
      expect(r.maps.isOn('contours'), isFalse);
      expect(r.maps.savedCamera?.zoom, 9, reason: 'the camera stays as it is in memory');
      expect(r.maps.opacityOf('landcover'), 0.4);
      expect(heard, greaterThan(n));
      await noWrite(before, r.dir);
    });
    await r.dispose(tester);
  });

  testWidgets('WeatherState.reloadOwn reads the own sources again, and writes nothing', (tester) async {
    final r = await SettingsRig.create(tester);
    var heard = 0;
    r.weather.addListener(() => heard++);
    await tester.runAsync(() async {
      expect(r.weather.ownSources, isEmpty);
      await behind(r, 'weather.own_sources', [
        {'entry': entry('own-a', 'water', 'River A', path: 'defs/own-a.json'), 'definition': miniDefinition('own-a')},
      ]);
      final before = snapshot(r.dir);
      final n = heard;
      await r.weather.reloadOwn();
      expect(r.weather.ownSources.map((c) => c.id), ['own-a']);
      expect(heard, greaterThan(n));
      await noWrite(before, r.dir);
    });
    await r.dispose(tester);
  });
}
