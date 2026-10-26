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

  test('the built-in live source definitions are read from the app bundle, files in the sources folder only', () async {
    final bundle = _Bundle({
      '${kLiveSourcesAssetDir}alerts.json': '{"none_label":"No active alerts"}',
      '${kLiveSourcesAssetDir}weather.json': '{"id":"weather"}',
      '${kLiveSourcesAssetDir}nested/other.json': '{"id":"other"}',
      '${kStarterLayersAssetDir}contours.json': '{"id":"contours"}',
    });
    final texts = await readLiveSourceAssets(bundle: bundle);
    expect(texts, ['{"none_label":"No active alerts"}', '{"id":"weather"}']);
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
