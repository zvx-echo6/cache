import 'dart:convert';
import 'dart:io';

import 'package:cache/maps/layers/starter_defs.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// A bundle that holds the given files.
class _Bundle extends CachingAssetBundle {
  _Bundle(this.files);
  final Map<String, String> files;
  @override
  Future<ByteData> load(String key) async {
    if (key == 'AssetManifest.bin') return const StandardMessageCodec().encodeMessage(<String, Object>{for (final k in files.keys) k: <Object>[]})!;
    final text = files[key];
    if (text == null) throw StateError('no $key');
    return ByteData.sublistView(utf8.encode(text));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the live data source definitions in the app are written to the core\'s folder, rewritten when they change, and others are left alone', () async {
    final dir = Directory.systemTemp.createTempSync('livesrc');
    addTearDown(() => dir.deleteSync(recursive: true));
    File('${dir.path}/mine.json').writeAsStringSync('{"mine":1}');
    File('${dir.path}/alerts.json').writeAsStringSync('{"old":true}');
    final bundle = _Bundle({
      '${kLiveSourcesAssetDir}alerts.json': '{"none_label":"No active alerts"}',
      '${kLiveSourcesAssetDir}weather.json': '{"id":"weather"}',
      '${kStarterLayersAssetDir}contours.json': '{"id":"contours"}',
    });
    await installLiveSources(dir, bundle: bundle);
    expect(File('${dir.path}/alerts.json').readAsStringSync(), '{"none_label":"No active alerts"}');
    expect(File('${dir.path}/weather.json').readAsStringSync(), '{"id":"weather"}');
    expect(File('${dir.path}/mine.json').readAsStringSync(), '{"mine":1}');
    expect(File('${dir.path}/contours.json').existsSync(), isFalse, reason: 'layer definitions are not live sources');
  });

  test('the live source definitions the app ships are the ones in the core\'s folder, byte for byte', () {
    // The plugin's pubspec bundles packages/cache_search/sources; the files are read straight from there, so a definition the
    // core reads strictly (alerts.json has a field older cores refuse) can only be the core's own.
    final src = Directory('../packages/cache_search/sources');
    expect(src.existsSync(), isTrue);
    final names = [for (final f in src.listSync().whereType<File>()) f.uri.pathSegments.last]..sort();
    expect(names, containsAll(['alerts.json', 'weather.json']));
    expect(File('../packages/cache_search/pubspec.yaml').readAsStringSync(), contains('- sources/'));
  });
}
