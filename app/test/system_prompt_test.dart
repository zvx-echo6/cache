import 'package:cache/chat/system_prompt.dart';
import 'package:cache/search/core_config.dart';
import 'package:flutter_test/flutter_test.dart';
import 'dart:io';

void main() {
  test('the system prompt is the approved template, built per turn', () {
    final p = buildSystemPrompt(now: DateTime(2026, 10, 26, 9, 5), locationKnown: true);
    final lines = p.split('\n');
    expect(lines, hasLength(6));
    expect(lines[0], 'You are Cache, an offline survival and preparedness assistant running on this phone.');
    expect(lines[1], matches(RegExp(r'^Current local date and time: Monday, 2026-10-26 09:05 \(UTC[+-]\d\d:\d\d\)\.$')));
    expect(lines[2], "The phone's current location is known.");
    expect(buildSystemPrompt(now: DateTime(2026, 10, 25, 23, 59), locationKnown: false).split('\n')[2], "The phone's current location is not known.");
    expect(buildSystemPrompt(now: DateTime(2026, 10, 25, 23, 59), locationKnown: false), contains('Sunday, 2026-10-25 23:59'));
    expect(p.endsWith('give complete, practical answers.'), isTrue);
    expect(lines[4], startsWith('Cite every fact you take from a tool result with its number in square brackets, like [1].'));
  });

  test('isoWithOffset has the local offset', () {
    expect(isoWithOffset(DateTime(2026, 10, 26, 9, 5, 7)), matches(RegExp(r'^2026-10-26T09:05:07[+-]\d\d:\d\d$')));
  });

  test('core config points at the packs that are there', () {
    final dir = Directory.systemTemp.createTempSync('cfg');
    try {
      final files = Directory('${dir.path}/files')..createSync();
      final support = Directory('${dir.path}/support')..createSync();
      expect(buildCoreExtras(filesDir: files, supportDir: support).containsKey('routing'), isFalse);
      Directory('${files.path}/packs/idaho/valhalla').createSync(recursive: true);
      File('${files.path}/packs/idaho/places.sqlite').writeAsStringSync('');
      File('${files.path}/packs/idaho/valhalla/tiles.tar').writeAsStringSync('');
      final c = buildCoreExtras(filesDir: files, supportDir: support);
      expect(((c['places'] as Map)['packs'] as List).single, endsWith('places.sqlite'));
      expect(((c['routing'] as Map)['valhalla'] as Map)['shim'], 'libvalhalla_shim.so');
      expect((c['routing'] as Map).containsKey('offroad'), isFalse);
      expect((c['live'] as Map)['sources_dir'], '${files.path}/live-defs');
    } finally {
      dir.deleteSync(recursive: true);
    }
  });
}
