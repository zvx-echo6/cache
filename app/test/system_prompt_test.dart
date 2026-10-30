import 'package:cache/chat/system_prompt.dart';
import 'package:cache/search/core_config.dart';
import 'package:flutter_test/flutter_test.dart';
import 'dart:io';

import 'support/parity_fixtures.dart';

void main() {
  test('the system prompt is the approved template, built per turn', () {
    final p = buildSystemPrompt(now: DateTime(2026, 10, 26, 9, 5), locationKnown: true);
    final lines = p.split('\n');
    expect(lines, hasLength(6));
    expect(lines[0], 'You are Cache, an offline survival and preparedness assistant running on this phone.');
    expect(lines[1], matches(RegExp(r'^Current local date and time: Monday, 2026-10-26 09:05 \(UTC[+-]\d\d:\d\d\)\.$')));
    expect(lines[2], "The phone's current location is known; the tools use it when you leave the place out, so don't ask the person where they are.");
    expect(buildSystemPrompt(now: DateTime(2026, 10, 25, 23, 59), locationKnown: false).split('\n')[2], "The phone's current location is not known.");
    expect(buildSystemPrompt(now: DateTime(2026, 10, 25, 23, 59), locationKnown: false), contains('Sunday, 2026-10-25 23:59'));
    expect(p.endsWith('give complete, practical answers.'), isTrue);
    expect(lines[4], startsWith('Cite every fact you take from a tool result with its number in square brackets, like [1].'));
  });

  test('the known-location line tells the model not to ask where the person is', () {
    expect(buildSystemPrompt(now: DateTime(2026, 10, 26, 9, 5), locationKnown: true).split('\n')[2],
        "The phone's current location is known; the tools use it when you leave the place out, so don't ask the person where they are.");
  });

  group('parity with the training captures', () {
    // The harness renders 2026-10-29 14:30 at UTC-06:00. The test machine's own offset is put in its place (the only part a
    // DateTime here cannot choose); every other byte is compared as it is.
    final now = DateTime(2026, 10, 29, 14, 30);
    String expected(String file) => parityText(file).replaceFirst('(UTC-06:00)', '(UTC${utcOffset(now)})');
    for (final loc in [true, false]) {
      for (final voice in [false, true]) {
        final file = 'system-${loc ? 'loc' : 'noloc'}-${voice ? 'voice' : 'text'}.txt';
        test(file, () {
          expect(buildSystemPrompt(now: now, locationKnown: loc, voice: voice), expected(file));
        });
      }
    }
  });

  test('the voice line is the last line, only in voice mode', () {
    final now = DateTime(2026, 10, 29, 14, 30);
    final text = buildSystemPrompt(now: now, locationKnown: true);
    final voice = buildSystemPrompt(now: now, locationKnown: true, voice: true);
    expect(text, isNot(contains(kVoiceLine)));
    expect(voice, '$text\n$kVoiceLine');
    expect(kVoiceLine,
        'The user is talking to you by voice and will hear your answer read aloud: keep it short, two to four plain spoken sentences, '
        'with no tables, lists, headings or links. Keep the citation numbers; they are not read aloud.');
  });

  test('isoWithOffset has the local offset', () {
    expect(isoWithOffset(DateTime(2026, 10, 26, 9, 5, 7)), matches(RegExp(r'^2026-10-26T09:05:07[+-]\d\d:\d\d$')));
  });

  test('core config points at the packs that are there', () {
    final dir = Directory.systemTemp.createTempSync('cfg');
    try {
      final files = Directory('${dir.path}/files')..createSync();
      final support = Directory('${dir.path}/support')..createSync();
      // Nothing installed: routing is still configured, on the region engine's folder (an empty tiles).
      expect(((buildCoreExtras(filesDir: files, supportDir: support)['routing'] as Map)['valhalla'] as Map)['tiles'], '');
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
