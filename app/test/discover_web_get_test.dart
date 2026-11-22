import 'dart:io';

import 'package:cache/browse/browse_state.dart';
import 'package:cache/browse/web/device_library.dart';
import 'package:cache/discover/discover_device.dart';
import 'package:cache/discover/recipe.dart';
import 'package:cache/layout/layout_state.dart';
import 'package:cache/settings/app_settings.dart';
import 'package:cache/weather/weather_state.dart';
import 'package:flutter_test/flutter_test.dart';

import 'browse/fakes.dart';
import 'browse/web_fakes.dart';

// Objects the library items never touch.
class _Settings extends Fake implements AppSettings {}

class _Weather extends Fake implements WeatherState {}

class _Layout extends Fake implements LayoutState {}

void main() {
  late Directory tmp;
  late FakeDeviceApi api;
  late DeviceLibrary lib;
  late BrowseState browse;
  late AppDiscoverDevice dev;
  const item = RecipeItem(kind: ItemKind.library, name: 'wikivoyage_en_europe', flavour: 'maxi', approxBytes: 260 << 20);

  Future<String> recorded(Uri u) async {
    if (u.path.endsWith('/categories')) return fixture('kiwix_categories.xml');
    if (u.path.endsWith('/languages')) return fixture('kiwix_languages.xml');
    return fixture('kiwix_entries_wikivoyage.xml');
  }

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('discover-web-get');
    api = FakeDeviceApi();
    lib = DeviceLibrary(api: api, fs: MemoryAppFs(), uploader: FakeUploader(), leaveWarning: (_) {});
    browse = BrowseState(
      sources: FakeSources(Directory('${tmp.path}/zims')..createSync()),
      catalog: catalogWith(recorded),
      settingsDirOverride: Directory('${tmp.path}/s')..createSync(),
      phoneLanguage: 'en',
      device: lib,
    );
    dev = AppDiscoverDevice(browse: browse, settings: _Settings(), weather: _Weather(), layout: _Layout());
  });
  tearDown(() {
    browse.dispose();
    lib.dispose();
    tmp.deleteSync(recursive: true);
  });

  test('in a browser, a library the server is downloading is not "Get": it is under way (Adding...), and Get again starts nothing', () async {
    expect(await dev.isPresent(item), isFalse);
    await dev.getOwn(item);
    expect(api.downloads, hasLength(1));
    // The server's job is running (as the Library pane shows it): the card is past Get.
    api.jobList = [for (final j in api.jobList) job(j.id, 'running', url: j.url, name: j.name, bytes: 10 << 20, total: 260 << 20)];
    await lib.refresh();
    expect(await dev.isPresent(item), isTrue, reason: 'the card must leave Get while the server downloads');
    expect(dev.progressOf(item).active, isTrue, reason: 'and say it is being added, not Added');
    // Pressing Get again does not start a second download.
    await dev.getOwn(item);
    expect(api.downloads, hasLength(1));
  });
}
