import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cache/browse/browse_state.dart';
import 'package:cache/browse/opds.dart';
import 'package:cache/browse/zim_download.dart';
import 'package:cache/settings/data_policy.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

void main() {
  late Directory tmp;
  late Directory settings;
  late FakeSources sources;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('browse');
    settings = Directory('${tmp.path}/settings')..createSync();
    final zims = Directory('${tmp.path}/zims')..createSync();
    sources = FakeSources(zims);
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  BrowseState make({KiwixCatalog? catalog, ZimDownloader? downloader, DataPolicy? policy, String phone = 'en'}) => BrowseState(
        sources: sources,
        catalog: catalog ?? catalogWith((u) async => fixture('kiwix_entries_wikivoyage.xml')),
        downloader: downloader,
        policy: policy ?? testPolicy(),
        settingsDirOverride: settings,
        iconFetch: (u) async => Uint8List.fromList([1, 2, 3]),
        phoneLanguage: phone,
      );

  test('the catalogue language starts as the phone\'s, and a saved choice wins', () async {
    final a = make(phone: 'fr');
    await a.init();
    expect(a.language, 'fra');
    await a.setFilter(language: 'deu');
    final b = make(phone: 'fr');
    await b.init();
    expect(b.language, 'deu');
  });

  test('filters go to the catalogue and pages are appended', () async {
    final asked = <Uri>[];
    final b = make(catalog: catalogWith((u) async {
      asked.add(u);
      return fixture('kiwix_entries_wikivoyage.xml');
    }));
    await b.init();
    await b.setFilter(query: 'travel', category: 'wikivoyage');
    expect(asked.last.queryParameters, {'q': 'travel', 'lang': 'eng', 'category': 'wikivoyage', 'count': '30'});
    expect(b.entries.length, 2);
    expect(b.total, 4);
    expect(b.hasMore, isTrue);
    await b.loadMore();
    expect(asked.last.queryParameters['start'], '2');
    expect(b.entries.length, 4);
    await b.setFilter(clearCategory: true, tag: 'medicine');
    expect(asked.last.queryParameters['tag'], 'medicine');
    expect(asked.last.queryParameters.containsKey('category'), isFalse);
  });

  test('an unreachable catalogue is an error in words, not a crash', () async {
    final b = make(catalog: catalogWith((u) async => throw const CatalogException('Cannot reach the Kiwix library. Check the connection.')));
    await b.init();
    await b.loadFirstPage();
    expect(b.catalogError, contains('Cannot reach'));
    expect(b.entries, isEmpty);
    expect(b.loading, isFalse);
  });

  group('updates', () {
    test('a newer dated release of the same name and variant is offered', () async {
      File('${sources.zimsDir!.path}/wikivoyage_en_europe_maxi_2026-03.zim').writeAsBytesSync([0]);
      File('${sources.zimsDir!.path}/wikivoyage_en_europe_nopic_2026-09.zim').writeAsBytesSync([0]);
      File('${sources.zimsDir!.path}/my-own-file.zim').writeAsBytesSync([0]);
      await sources.refresh();
      final asked = <Uri>[];
      final b = make(catalog: catalogWith((u) async {
        asked.add(u);
        return fixture('kiwix_entries_wikivoyage.xml');
      }));
      await b.init();
      await b.checkUpdates();
      // One question per ZIM name, by name; the file without Kiwix naming is not asked about.
      expect(asked.length, 1);
      expect(asked.single.queryParameters['name'], 'wikivoyage_en_europe');
      expect(b.updates.length, 1);
      final z = sources.zims.firstWhere((z) => z.fileName.contains('maxi'));
      expect(b.updates[z.path]!.release, '2026-09');
      expect(b.updates[z.path]!.flavour, 'maxi');
      expect(b.updateError, isNull);
    });

    test('nothing is offered when the installed one is current', () async {
      File('${sources.zimsDir!.path}/wikivoyage_en_europe_maxi_2026-09.zim').writeAsBytesSync([0]);
      await sources.refresh();
      final b = make();
      await b.init();
      await b.checkUpdates();
      expect(b.updates, isEmpty);
    });
  });

  group('download and update', () {
    late HttpServer server;
    final bytes = Uint8List.fromList(List.generate(120000, (i) => i & 0xff));

    CatalogEntry entryFor(int port, {String release = '2026-09'}) => CatalogEntry(
          id: 'e-$release',
          title: 'Wikivoyage - Europe',
          summary: '',
          language: 'eng',
          name: 'wikivoyage_en_europe',
          flavour: 'nopic',
          category: 'wikivoyage',
          tags: const [],
          updated: '$release-14',
          size: bytes.length,
          articleCount: 1,
          downloadUrl: Uri.parse('http://127.0.0.1:$port/zim/wikivoyage_en_europe_nopic_$release.zim'),
          iconUrl: Uri.parse('http://127.0.0.1:$port/icon.png'),
        );

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        final res = req.response;
        if (req.uri.path.endsWith('.sha256')) {
          res.write('${sha256.convert(bytes)}  x.zim\n');
        } else if (req.uri.path.endsWith('.zim')) {
          res.headers.set('accept-ranges', 'bytes');
          res.headers.contentLength = bytes.length;
          if (req.method != 'HEAD') res.add(bytes);
        } else {
          res.statusCode = 404;
        }
        await res.close();
      });
    });
    tearDown(() => server.close(force: true));

    test('is blocked on mobile data by default, and goes on when told to download anyway', () async {
      final b = make(policy: testPolicy(wifi: false), downloader: ZimDownloader(freeSpace: (_) => 1 << 40));
      await b.init();
      final e = entryFor(server.port);
      await b.download(e);
      expect(b.transfers[e.id]!.phase, TransferPhase.blockedByMobileData);
      expect(sources.zims, isEmpty);
      await b.download(e, allowMobile: true);
      expect(b.transfers.containsKey(e.id), isFalse);
      expect(sources.zims.single.fileName, 'wikivoyage_en_europe_nopic_2026-09.zim');
    });

    test('downloads, verifies, adds to the sources and records where it came from', () async {
      final b = make(downloader: ZimDownloader(freeSpace: (_) => 1 << 40));
      await b.init();
      final e = entryFor(server.port);
      await b.download(e);
      expect(b.transfers, isEmpty);
      final z = sources.zims.single;
      expect(File(z.path).readAsBytesSync(), bytes);
      final o = sources.originOf(z)!;
      expect(o.name, 'wikivoyage_en_europe');
      expect(o.title, 'Wikivoyage - Europe');
      expect(o.catalogId, e.id);
      expect(sources.iconOf(z), isNotNull);
      expect(sources.titleOf(z), 'Wikivoyage - Europe'); // not the file name
      expect(b.installedFor(e), isNotNull);
      expect(Directory(sources.partialDir.path).listSync(), isEmpty);
    });

    test('a download a crash stopped comes back as paused with its partial file, and Resume finishes it', () async {
      final e = entryFor(server.port);
      // what the stopped app left: the record of the download and its partial file
      File('${settings.path}/browse.json').writeAsStringSync(jsonEncode({
        'language': 'eng',
        'downloads': {
          e.id: {'entry': e.toJson()},
        },
      }));
      final part = File('${sources.partialDir.path}/${e.fileName}.part')..createSync(recursive: true);
      part.writeAsBytesSync(bytes.sublist(0, 50000));
      final b = make(downloader: ZimDownloader(freeSpace: (_) => 1 << 40));
      await b.init();
      final t = b.transfers[e.id]!;
      expect((t.phase, t.done, t.total), (TransferPhase.paused, 50000, bytes.length));
      expect(b.resumableParts, {part.path}, reason: 'Storage does not offer it as a leftover');
      await b.resume(e);
      expect(b.transfers, isEmpty);
      expect(File(sources.zims.single.path).readAsBytesSync(), bytes);
      // finished: the record is gone, so the next start brings nothing back
      await Future<void>.delayed(const Duration(milliseconds: 100)); // the record is written without waiting
      final again = make(downloader: ZimDownloader(freeSpace: (_) => 1 << 40));
      await again.init();
      expect(again.transfers, isEmpty);
    });

    test('a partial file with no record (an older build crashed) is matched to its catalogue entry and comes back paused', () async {
      final listed = (await make().catalog.entries()).entries;
      final e = listed.first;
      final part = File('${sources.partialDir.path}/${e.fileName}.part')..createSync(recursive: true);
      part.writeAsBytesSync(List.filled(4096, 7));
      // and one the catalogue does not have (an old release): a leftover
      final gone = File('${sources.partialDir.path}/${e.name}_2001-01.zim.part')..writeAsBytesSync([1, 2, 3]);
      final b = make();
      await b.init();
      for (var i = 0; i < 20 && b.transfers[e.id] == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      final t = b.transfers[e.id]!;
      expect((t.phase, t.done, t.total), (TransferPhase.paused, 4096, e.size));
      expect(b.resumableParts, contains(part.path), reason: 'not offered as a leftover');
      expect(b.resumableParts, isNot(contains(gone.path)), reason: 'nothing to carry on: a leftover');
      // now it has a record: the next start brings it back as any other
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(File('${settings.path}/browse.json').readAsStringSync(), contains(e.id));
    });

    test('while the catalogue cannot be reached, a partial file with no record is kept (not a leftover), not adopted', () async {
      final part = File('${sources.partialDir.path}/wikivoyage_en_europe_nopic_2026-09.zim.part')..createSync(recursive: true);
      final b = make(catalog: catalogWith((u) async => throw const CatalogException('No connection')));
      await b.init();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(b.transfers, isEmpty);
      expect(b.resumableParts, contains(part.path));
    });

    test('a record whose partial file is gone is forgotten', () async {
      final e = entryFor(server.port);
      File('${settings.path}/browse.json').writeAsStringSync(jsonEncode({
        'downloads': {
          e.id: {'entry': e.toJson()},
        },
      }));
      final b = make();
      await b.init();
      expect(b.transfers, isEmpty);
      await b.saved; // the record is written without waiting
      final again = make();
      await again.init();
      expect(again.transfers, isEmpty);
      await again.saved;
      expect(File('${settings.path}/browse.json').readAsStringSync(), isNot(contains(e.id)));
    });

    test('a failed download is kept as a failure with the reason and can be tried again', () async {
      final b = make(downloader: ZimDownloader(freeSpace: (_) => 10));
      await b.init();
      final e = entryFor(server.port);
      await b.download(e);
      expect(b.transfers[e.id]!.phase, TransferPhase.failed);
      expect(b.transfers[e.id]!.error, contains('Not enough free space'));
      expect(sources.zims, isEmpty);
    });

    test('an update keeps the old file until the new one is ready, then removes it', () async {
      final old = File('${sources.zimsDir!.path}/wikivoyage_en_europe_nopic_2026-03.zim')..writeAsBytesSync([9, 9, 9]);
      await sources.refresh();
      final oldZim = sources.zims.single;
      final b = make(downloader: ZimDownloader(freeSpace: (_) => 1 << 40));
      await b.init();
      b.updates[oldZim.path] = entryFor(server.port);
      await b.update(oldZim);
      expect(sources.zims.length, 2);
      expect(old.existsSync(), isTrue, reason: 'the old copy stays while the new one is indexed');
      expect(sources.removed, isEmpty);
      expect(b.isBeingReplaced(oldZim), isTrue);

      final fresh = sources.zims.firstWhere((z) => z.fileName.endsWith('2026-09.zim'));
      sources.ready.add(fresh.path);
      sources.poke();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(sources.removed, [oldZim.path]);
      expect(old.existsSync(), isFalse);
      expect(sources.zims.single.fileName, 'wikivoyage_en_europe_nopic_2026-09.zim');
      expect(b.isBeingReplaced(oldZim), isFalse);
    });

    test('if the new file never gets ready the old one is not touched', () async {
      File('${sources.zimsDir!.path}/wikivoyage_en_europe_nopic_2026-03.zim').writeAsBytesSync([9]);
      await sources.refresh();
      final oldZim = sources.zims.single;
      final b = make(downloader: ZimDownloader(freeSpace: (_) => 1 << 40));
      await b.init();
      b.updates[oldZim.path] = entryFor(server.port);
      await b.update(oldZim);
      sources.poke();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(sources.removed, isEmpty);
      expect(sources.zims.length, 2);
    });
  });

  test('a download started again right after a cancel keeps the partial file and finishes it', () async {
    final bytes = Uint8List.fromList(List.generate(200000, (i) => (i * 7) & 0xff));
    final firstSent = Completer<void>();
    final releaseFirst = Completer<void>();
    final releaseSecond = Completer<void>();
    final ranges = <String?>[];
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      final res = req.response;
      try {
        if (!req.uri.path.endsWith('.zim')) {
          res.statusCode = 404;
        } else if (req.method == 'HEAD') {
          res.headers.set('accept-ranges', 'bytes');
          res.headers.contentLength = bytes.length;
        } else {
          final range = req.headers.value(HttpHeaders.rangeHeader);
          ranges.add(range);
          final from = range == null ? 0 : int.parse(RegExp(r'bytes=(\d+)-').firstMatch(range)!.group(1)!);
          res.headers.set('accept-ranges', 'bytes');
          if (from > 0) {
            res.statusCode = 206;
            res.headers.set('content-range', 'bytes $from-${bytes.length - 1}/${bytes.length}');
          }
          res.headers.contentLength = bytes.length - from;
          if (ranges.length == 1) {
            // Half the file, then nothing until the test ends: this download is cancelled while it waits.
            res.add(bytes.sublist(0, 100000));
            await res.flush();
            firstSent.complete();
            await releaseFirst.future;
          } else {
            // The new download is held until the cancel is over, so a cancel that deletes the file late is caught.
            await releaseSecond.future;
            res.add(bytes.sublist(from));
          }
        }
        await res.close();
      } catch (_) {}
    });
    try {
      final b = make(downloader: ZimDownloader(freeSpace: (_) => 1 << 40));
      await b.init();
      final e = CatalogEntry(
        id: 'e-again',
        title: 'Wikivoyage - Europe',
        summary: '',
        language: 'eng',
        name: 'wikivoyage_en_europe',
        flavour: 'nopic',
        category: 'wikivoyage',
        tags: const [],
        updated: '2026-09-14',
        size: bytes.length,
        articleCount: 1,
        downloadUrl: Uri.parse('http://127.0.0.1:${server.port}/zim/wikivoyage_en_europe_nopic_2026-09.zim'),
        iconUrl: null,
      );
      final part = File('${sources.partialDir.path}/${e.fileName}.part');
      final first = b.download(e);
      await firstSent.future;
      for (var i = 0; i < 300 && !(part.existsSync() && part.lengthSync() >= 100000); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(part.lengthSync(), 100000);
      final cancelled = b.cancel(e);
      final second = b.download(e);
      await cancelled;
      await first;
      releaseSecond.complete();
      await second;
      expect(b.transfers, isEmpty);
      expect(ranges, [null, 'bytes=100000-']);
      expect(File(sources.zims.single.path).readAsBytesSync(), bytes);
      expect(sources.partialDir.listSync(), isEmpty);
    } finally {
      if (!releaseFirst.isCompleted) releaseFirst.complete();
      if (!releaseSecond.isCompleted) releaseSecond.complete();
      await server.close(force: true);
    }
  });

  test('with a language chosen, collections tagged with that language and others ("eng,jpn") are not listed', () async {
    final b = make();
    await b.init();
    b.language = 'eng';
    CatalogEntry e(String lang) => CatalogEntry(id: lang, title: lang, summary: '', language: lang, name: 'x', flavour: '', category: 'other', tags: const [], updated: '2026-10-01', size: 1, articleCount: 1, downloadUrl: Uri.parse('https://example.org/x.zim'), iconUrl: null);
    expect(b.inLanguage(e('eng')), isTrue);
    expect(b.inLanguage(e('eng,jpn')), isFalse, reason: 'the Japanese Stack Overflow is tagged eng,jpn');
    expect(b.inLanguage(e('rus')), isFalse);
    expect(b.inLanguage(e('eng,ara,spa,fra,kor,vie,ind,ita,por,zho,rus,tur,mya')), isTrue, reason: 'a multi-language collection (TED) includes it');
    expect(b.inLanguage(e('mul')), isTrue, reason: 'tagged as multi-language');
    expect(b.inLanguage(e('ara,spa,fra')), isFalse, reason: 'many languages, but not this one');
    expect(b.inLanguage(e('')), isTrue, reason: 'no language given: kept');
    b.language = '';
    expect(b.inLanguage(e('eng,jpn')), isTrue, reason: 'All languages lists every collection');
  });
}
