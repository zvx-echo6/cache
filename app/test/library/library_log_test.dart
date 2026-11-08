import 'dart:io';

import 'package:cache/library/cds.dart';
import 'package:cache/library/library_log.dart';
import 'package:cache/theme.dart';
import 'package:flutter_test/flutter_test.dart';

List<LogEvent> _events(String text) => parseLog(text);

void main() {
  group('the library log resolves as LIBRARY-LOG.md says', () {
    test('the phone and the server each took 210-002 while apart: the first keeps it, the other shows .1; the next is 3', () {
      final r = resolveLog(_events('''
{"v":1,"at":100,"dev":"phone","ev":"place","doc":"p","div":"210","by":"auto"}
{"v":1,"at":101,"dev":"phone","ev":"assign","doc":"p","div":"210","seq":2}
{"v":1,"at":200,"dev":"server","ev":"place","doc":"s","div":"210","by":"auto"}
{"v":1,"at":201,"dev":"server","ev":"assign","doc":"s","div":"210","seq":2}
'''));
      expect(r['p']!.call!.text, 'CDS 210-002');
      expect(r['s']!.call!.text, 'CDS 210-002.1');
      expect(r.nextSeq('210'), 3);
    });

    test('a move retires the old number (never reused), and a later claim keeps its suffix', () {
      final r = resolveLog(_events('''
{"v":1,"at":100,"dev":"phone","ev":"place","doc":"p","div":"210","by":"auto"}
{"v":1,"at":101,"dev":"phone","ev":"assign","doc":"p","div":"210","seq":2}
{"v":1,"at":200,"dev":"server","ev":"place","doc":"s","div":"210","by":"auto"}
{"v":1,"at":201,"dev":"server","ev":"assign","doc":"s","div":"210","seq":2}
{"v":1,"at":300,"dev":"phone","ev":"place","doc":"p","div":"320","by":"user"}
{"v":1,"at":300,"dev":"phone","ev":"retire","doc":"p","div":"210","seq":2}
{"v":1,"at":300,"dev":"phone","ev":"assign","doc":"p","div":"320","seq":1}
'''));
      expect(r['p']!.shelf, '320');
      expect(r['p']!.by, LogBy.user);
      expect(r['p']!.call!.text, 'CDS 320-001');
      expect(r['s']!.call!.text, 'CDS 210-002.1', reason: 'ranks are fixed');
      expect(r.retired['210'], {2});
      expect(r.nextSeq('210'), 3, reason: 'a retired number is never used again');
    });

    test('Unsorted: unsort and retire leave no number; a title, remove and restore take the latest', () {
      final r = resolveLog(_events('''
{"v":1,"at":1,"dev":"a","ev":"place","doc":"b","div":"350","by":"auto"}
{"v":1,"at":1,"dev":"a","ev":"assign","doc":"b","div":"350","seq":1}
{"v":1,"at":5,"dev":"a","ev":"unsort","doc":"b","by":"user"}
{"v":1,"at":5,"dev":"a","ev":"retire","doc":"b","div":"350","seq":1}
{"v":1,"at":6,"dev":"a","ev":"title","doc":"b","title":"Bees in winter"}
{"v":1,"at":7,"dev":"a","ev":"remove","doc":"b"}
{"v":1,"at":8,"dev":"b","ev":"restore","doc":"b"}
'''));
      expect(r['b']!.shelved, isTrue);
      expect(r['b']!.shelf, isNull);
      expect(r['b']!.call, isNull);
      expect(r['b']!.title, 'Bees in winter');
      expect(r['b']!.removed, isFalse);
      expect(r.nextSeq('350'), 2);
    });

    test('order is (at, dev, position), whatever order the files come in; unknown events and torn lines are skipped', () {
      final r = resolveLog(_events('''
{"v":1,"at":10,"dev":"z","ev":"place","doc":"b","div":"210","by":"user"}
{"v":1,"at":10,"dev":"a","ev":"place","doc":"b","div":"220","by":"auto"}
{"v":2,"at":11,"dev":"a","ev":"place","doc":"b","div":"230","by":"auto"}
{"v":1,"at":12,"dev":"a","ev":"folder","folder_id":"books","label":"Books","mode":"keep"}
{"v":1,"at":13,"dev":"a","ev":"pla
'''));
      expect(r['b']!.shelf, '210', reason: 'same time: dev "z" sorts after "a"');
    });

    test('the writer appends whole lines, closes a torn last line, never goes back in time and refuses another device', () {
      final dir = Directory.systemTemp.createTempSync('liblog');
      addTearDown(() => dir.deleteSync(recursive: true));
      final w = LogWriter(dir, 'phone-1');
      w.file.parent.createSync(recursive: true);
      w.file.writeAsStringSync('{"v":1,"at":500,"dev":"phone-1","ev":"remove","doc":"x"}\n{"v":1,"at":6');
      final out = w.append([const LogEvent(at: 100, dev: 'phone-1', ev: LogEv.place, doc: 'b', div: '210', by: LogBy.user)]);
      expect(out.single.at, 500, reason: 'a clock set back is held at the last time written');
      final lines = w.file.readAsStringSync().split('\n');
      expect(lines.last, '');
      expect(lines[2], '{"v":1,"at":500,"dev":"phone-1","ev":"place","doc":"b","div":"210","by":"user"}');
      expect(readLogs(dir).map((e) => e.ev), [LogEv.remove, LogEv.place]);
      expect(() => w.append([const LogEvent(at: 1, dev: 'other', ev: LogEv.remove, doc: 'b')]), throwsStateError);
      expect(() => LogWriter(dir, '.hidden'), throwsArgumentError);
    });
  });

  group('the Cache Decimal System', () {
    test('ten classes, nine divisions each; 060 is kept free and never shown', () {
      expect(kCdsClasses, hasLength(10));
      for (final c in kCdsClasses) {
        expect(c.divisions, hasLength(9), reason: c.name);
      }
      expect(cdsDivision('060'), isNull);
      expect(kCdsClasses.first.assigned, hasLength(8));
      expect(cdsShelfLabel('210'), 'CDS 210 · First aid and emergency care');
      expect(cdsShelfLabel('200'), 'CDS 200 · Medicine and Health');
      expect(cdsCallText('210', 1), 'CDS 210-001');
      expect(cdsCallText('210', 1000), 'CDS 210-1000');
      expect(cdsCallText('210', 2, 1), 'CDS 210-002.1');
    });

    test('Go to a number takes a class, a division or a call number', () {
      expect(parseCdsAddress('500')!.division, isNull);
      expect(parseCdsAddress('500')!.classNumber, '500');
      expect(parseCdsAddress(' 530 ')!.division, '530');
      expect(parseCdsAddress('530-002')!.call, '530-002');
      expect(parseCdsAddress('CDS 210-002.1')!.call, '210-002.1');
      expect(parseCdsAddress('cds 530-2')!.call, '530-002');
      expect(parseCdsAddress('531'), isNull);
      expect(parseCdsAddress('060'), isNull);
      expect(parseCdsAddress('Bees'), isNull);
    });

    test('every class colour reads as text (4.5:1) on the cards and the page of every theme', () {
      for (final id in CacheThemeId.values) {
        final k = cacheTokens[id]!;
        for (final c in kCdsClasses) {
          final colour = cdsClassColor(k, c.number, dark: !id.isLight, tactical: k.monoDark != null);
          expect(contrastRatio(colour, k.surface), greaterThanOrEqualTo(4.5), reason: '${id.name} ${c.number} on surface');
          expect(contrastRatio(colour, k.background), greaterThanOrEqualTo(4.5), reason: '${id.name} ${c.number} on background');
        }
      }
    });
  });
}
