import 'package:cache/chat/system_prompt.dart';
import 'package:cache/search/core_config.dart';
import 'package:flutter_test/flutter_test.dart';
import 'dart:io';

import 'support/parity_fixtures.dart';

void main() {
  test(
    'compact prompt keeps grounding, citations, context and response guidance',
    () {
      final p = buildSystemPrompt(
        now: DateTime(2026, 10, 26, 9, 5),
        locationKnown: true,
      );
      expect(p, contains('answer only from their results'));
      expect(p, contains('Search offline first'));
      expect(p, contains('current information is needed'));
      expect(p, contains('web search is unavailable'));
      expect(p, contains('Cite every sourced fact'));
      expect(p, contains("not in the user's sources"));
      expect(p, contains('data expired or was not downloaded'));
      expect(p, contains('small talk or feelings'));
      expect(p, contains('complete, practical answers'));
      expect(p, contains("don't ask the person where they are"));
      expect(
        p,
        contains('Read a source only when its snippet is insufficient'),
      );
      expect(p, contains('answer directly without describing tool plans'));
      expect(
        p,
        matches(
          RegExp(
            r'Current local date: Monday, 2026-10-26 \(UTC[+-]\d\d:\d\d\)\.',
          ),
        ),
      );
    },
  );

  test('date changes after the reusable instructions; the text is the same whether the location is known or not', () {
    const locationLine =
        "Tools use the phone's location when you leave the place out; ask where the person is only if a tool says the location is unknown.";
    final first = buildSystemPrompt(
      now: DateTime(2026, 10, 26, 9, 5),
      locationKnown: true,
    );
    final next = buildSystemPrompt(
      now: DateTime(2026, 10, 27, 10, 6),
      locationKnown: false,
    );
    final prefix = first.substring(0, first.indexOf('Current local date'));
    expect(next.startsWith(prefix), isTrue);
    expect(prefix.length, greaterThan(first.length * .75));
    expect(next, contains('Tuesday, 2026-10-27 (UTC'));
    expect(next, isNot(contains('10:06')));
    expect(next, isNot(contains('Monday, 2026-10-26')));
    expect(first, contains(locationLine));
    expect(next, contains(locationLine));
    final day = DateTime(2026, 10, 27, 10, 6);
    for (final voice in [false, true]) {
      expect(
        buildSystemPrompt(now: day, locationKnown: true, voice: voice),
        buildSystemPrompt(now: day, locationKnown: false, voice: voice),
      );
    }
  });

  test('the same day gives the same bytes at any time of day, so the prompt start is reused all day', () {
    for (final loc in [true, false]) {
      for (final voice in [false, true]) {
        final morning = buildSystemPrompt(now: DateTime(2026, 10, 29, 6, 1), locationKnown: loc, voice: voice);
        final evening = buildSystemPrompt(now: DateTime(2026, 10, 29, 23, 59), locationKnown: loc, voice: voice);
        expect(evening, morning);
      }
    }
  });

  test('the time line', () {
    expect(buildTimeLine(DateTime(2026, 10, 29, 9, 5)), 'Local time: 09:05');
    expect(buildTimeLine(DateTime(2026, 10, 29, 14, 30)), parityText('time-line-1430.txt'));
    expect(withTimeLine('Local time: 09:05', 'Q?'), 'Local time: 09:05\n\nQ?');
  });

  test('frozen with the harness port (harness-askperf prompt_app.py system_date)', () {
    String atFixtureOffset(String s) => s.replaceAll(RegExp(r'UTC[+-]\d\d:\d\d'), 'UTC-06:00');
    final now = DateTime(2026, 10, 29, 14, 30);
    expect(atFixtureOffset(buildSystemPrompt(now: now, locationKnown: true)), parityText('system-date-loc-text.txt'));
    expect(atFixtureOffset(buildSystemPrompt(now: now, locationKnown: false, voice: true)), parityText('system-date-noloc-voice.txt'));
  });

  test(
    'all context and voice variants are shorter than the training baseline',
    () {
      final now = DateTime(2026, 10, 29, 14, 30);
      for (final loc in [true, false]) {
        for (final voice in [false, true]) {
          final baseline = parityText(
            'system-${loc ? 'loc' : 'noloc'}-${voice ? 'voice' : 'text'}.txt',
          );
          final compact = buildSystemPrompt(
            now: now,
            locationKnown: loc,
            voice: voice,
          );
          expect(compact.length, lessThan(baseline.length));
          expect(compact, contains('2026-10-29 (UTC'));
          expect(compact, isNot(contains('14:30')));
          expect(compact.contains(kVoiceLine), voice);
        }
      }
    },
  );

  test('the voice line is the last line, only in voice mode', () {
    final now = DateTime(2026, 10, 29, 14, 30);
    final text = buildSystemPrompt(now: now, locationKnown: true);
    final voice = buildSystemPrompt(now: now, locationKnown: true, voice: true);
    expect(text, isNot(contains(kVoiceLine)));
    expect(voice, '$text\n$kVoiceLine');
    expect(
      kVoiceLine,
      'The user is talking to you by voice and will hear your answer read aloud: keep it short, two to four plain spoken sentences, '
      'with no tables, lists, headings or links. Keep the citation numbers; they are not read aloud.',
    );
  });

  test('isoWithOffset has the local offset', () {
    expect(
      isoWithOffset(DateTime(2026, 10, 26, 9, 5, 7)),
      matches(RegExp(r'^2026-10-26T09:05:07[+-]\d\d:\d\d$')),
    );
  });

  test(
    'core config points at the region downloads, never a hand-placed packs folder',
    () {
      final dir = Directory.systemTemp.createTempSync('cfg');
      try {
        final files = Directory('${dir.path}/files')..createSync();
        final support = Directory('${dir.path}/support')..createSync();
        // Nothing installed: routing is still configured, on the region engine's folder (an empty tiles).
        expect(
          ((buildCoreExtras(filesDir: files, supportDir: support)['routing']
                  as Map)['valhalla']
              as Map)['tiles'],
          '',
        );
        Directory(
          '${files.path}/packs/idaho/valhalla',
        ).createSync(recursive: true);
        File('${files.path}/packs/idaho/places.sqlite').writeAsStringSync('');
        File(
          '${files.path}/packs/idaho/valhalla/tiles.tar',
        ).writeAsStringSync('');
        final c = buildCoreExtras(filesDir: files, supportDir: support);
        expect(
          (c['places'] as Map)['packs'],
          isEmpty,
          reason: 'hand-placed packs are not read: places come from regions',
        );
        expect(
          ((c['routing'] as Map)['valhalla'] as Map)['shim'],
          'libvalhalla_shim.so',
        );
        expect((c['routing'] as Map)['offroad'], {
          'dir': '${support.path}/regions/offroad',
        });
        expect((c['live'] as Map)['sources_dir'], '${files.path}/live-defs');
      } finally {
        dir.deleteSync(recursive: true);
      }
    },
  );
}
