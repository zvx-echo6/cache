import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:cache/browse/opds.dart';
import 'package:cache/browse/web/build_api.dart';
import 'package:cache/browse/web/build_state.dart';
import 'package:cache/browse/web/device_api.dart';
import 'package:cache/browse/web/device_library.dart';
import 'package:cache/net/fetch.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'build_fakes.dart';
import 'web_fakes.dart';

void main() {
  late FakeDeviceApi api;
  late MemoryAppFs fs;
  late FakeUploader uploader;
  late List<bool> warnings;
  late int changed;

  DeviceLibrary make({MemoryAppFs? files}) => DeviceLibrary(
        api: api,
        fs: files ?? fs,
        uploader: uploader,
        leaveWarning: warnings.add,
        onItemsChanged: () async => changed++,
      );

  setUp(() {
    api = FakeDeviceApi();
    fs = MemoryAppFs();
    uploader = FakeUploader();
    warnings = [];
    changed = 0;
  });

  group('reading the device', () {
    test('a built library that changes (a book removed, a library published) makes the sizes and the app\'s books read again at once', () async {
      api.itemList = [item('proof', kind: 'library', bytes: 66 << 20)];
      final buildApi = FakeBuildApi()..libs = [const BuildLibrary(id: 'proof', title: 'Proof', books: 4, passages: 4, published: true)];
      final b = BuildController(api: buildApi, poll: false, leaveWarning: (_) {});
      final d = DeviceLibrary(api: api, fs: fs, uploader: uploader, leaveWarning: warnings.add, onItemsChanged: () async => changed++, build: b);
      await d.start();
      expect(b.sizeOf!('proof'), 66 << 20);
      final reads = api.jobsReads;
      // nothing changed: nothing is read again
      await b.refresh();
      expect(api.jobsReads, reads);
      // the books go and the device's folder is small again
      api.itemList = [item('proof', kind: 'library', bytes: 3 << 10)];
      buildApi.libs = [const BuildLibrary(id: 'proof', title: 'Proof')];
      await b.refresh();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(api.jobsReads, greaterThan(reads));
      expect(b.sizeOf!('proof'), 3 << 10);
      expect(changed, greaterThan(0));
      d.dispose();
    });

    test('items, transfers and free space are read; the device that cannot be reached is said, not thrown', () async {
      api.itemList = [item('a.zim', bytes: 10), item('guide', kind: 'library', bytes: 5)];
      api.jobList = [job('j1', 'running', bytes: 5, total: 20)];
      final d = make();
      await d.start();
      expect(d.items.map((i) => i.name), ['a.zim', 'guide']);
      expect(d.jobs.single.fraction, 0.25);
      expect(d.space.free, 100 << 30);
      expect(d.stillToDownload, 15);
      expect(d.problem, isNull);
      api.failWith = const DeviceException('unreachable', 'x');
      await d.refresh();
      expect(d.problem, 'This device could not be reached.');
      expect(d.items, isNotEmpty, reason: 'what was known stays on screen');
      d.dispose();
    });

    test('a finished transfer leaves the list when its read ends, whether the app catches up slowly or fails', () async {
      api.jobList = [job('j1', 'running', bytes: 0, total: 418000)];
      final slow = Completer<void>();
      var mode = 'fail';
      final d = DeviceLibrary(
        api: api,
        fs: fs,
        uploader: uploader,
        leaveWarning: warnings.add,
        onItemsChanged: () async {
          if (mode == 'fail') throw StateError('the sources could not be read');
          await slow.future;
        },
      );
      var notified = 0;
      await d.start();
      expect(d.anyActive, isTrue);
      d.addListener(() => notified++);

      // The app's catch-up fails: the card still goes, and the next read is still scheduled.
      api.jobList = [job('j1', 'done', bytes: 418000, total: 418000)];
      api.itemList = [item('a.zim', bytes: 418000)];
      await d.refresh();
      expect(d.anyActive, isFalse);
      expect(d.jobs.single.done, isTrue);
      expect(notified, greaterThan(0));
      expect(d.problem, isNull);

      // The app's catch-up is slow: what was read is on screen before it ends.
      mode = 'slow';
      api.jobList = [job('j2', 'running', bytes: 0, total: 9)];
      await d.refresh();
      api.jobList = [job('j2', 'done', bytes: 9, total: 9)];
      api.itemList = [item('a.zim', bytes: 418000), item('b.zim', bytes: 9)];
      notified = 0;
      final reading = d.refresh();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(d.jobs.single.done, isTrue);
      expect(notified, greaterThan(0), reason: 'shown before the app is done');
      slow.complete();
      await reading;
      d.dispose();
    });

    testWidgets('it is read again every 2 seconds while a transfer is active and every 30 seconds otherwise', (tester) async {
      api.jobList = [job('j1', 'running', bytes: 1, total: 9)];
      final d = make();
      await d.start();
      final base = api.jobsReads;
      await tester.pump(const Duration(seconds: 2));
      await tester.pump(const Duration(seconds: 2));
      expect(api.jobsReads, base + 2, reason: 'a read every 2 s while a transfer runs');
      api.jobList = [job('j1', 'done', bytes: 9, total: 9)];
      await tester.pump(const Duration(seconds: 2));
      final idle = api.jobsReads;
      await tester.pump(const Duration(seconds: 20));
      expect(api.jobsReads, idle, reason: 'nothing active: the next read is 30 s after the last');
      await tester.pump(const Duration(seconds: 10));
      expect(api.jobsReads, idle + 1);
      // Back in focus: a read at once.
      d.onFocus();
      await tester.pump();
      expect(api.jobsReads, idle + 2);
      d.dispose();
    });

    test('a download that ends tells the app to read its sources again', () async {
      final d = make();
      await d.start();
      expect(changed, 0, reason: 'the first read is not a change');
      api.itemList = [item('new.zim')];
      await d.refresh();
      expect(changed, 1);
      await d.refresh();
      expect(changed, 1, reason: 'nothing new the second time');
      d.dispose();
    });
  });

  group('While this tab was closed', () {
    test('the first visit has nothing to say; a later one lists what finished, still runs or stopped, until Dismiss', () async {
      api.jobList = [job('j1', 'running', bytes: 1, total: 9), job('j2', 'running', bytes: 1, total: 9), job('j3', 'running')];
      var d = make();
      await d.start();
      expect(d.whileClosed, isEmpty);
      expect(fs.files.keys, contains('support:$kDeviceSeenFile'), reason: 'the marker is kept through AppFs');
      d.dispose();

      // The tab is closed. Meanwhile j1 finished, j2 goes on, j3 stopped, and j4 started and finished.
      api.jobList = [job('j1', 'done'), job('j2', 'running', bytes: 5, total: 9), job('j3', 'failed', error: 'x'), job('j4', 'done')];
      d = make();
      await d.start();
      expect(d.whileClosed.map((j) => '${j.id}:${j.state}'), ['j1:done', 'j2:running', 'j3:failed', 'j4:done']);
      // A reload before Dismiss says it again.
      final again = make();
      await again.start();
      expect(again.whileClosed.length, 4);
      again.dispose();
      await d.dismissWhileClosed();
      expect(d.whileClosed, isEmpty);
      final third = make();
      await third.start();
      expect(third.whileClosed.map((j) => j.id), ['j2'], reason: 'only what still runs is told again');
      third.dispose();
      d.dispose();
    });
  });

  group('transfers', () {
    test('a catalogue entry is sent with its link, name, origin record and icon; failed ones can be tried again and cancelled', () async {
      final d = make();
      await d.start();
      final e = CatalogEntry(
        id: 'u1',
        title: 'WikiMed',
        summary: 'Medical encyclopedia',
        language: 'eng',
        name: 'wikipedia_en_medicine',
        flavour: 'maxi',
        category: 'wikipedia',
        tags: const [],
        updated: '2026-09-14',
        size: 100,
        articleCount: 5,
        downloadUrl: Uri.parse('https://download.kiwix.org/zim/wikipedia/wikipedia_en_medicine_maxi_2026-09.zim'),
        iconUrl: Uri.parse('https://opds.library.kiwix.org/catalog/v2/illustration/u1/?size=48'),
      );
      final j = await d.downloadZim(e);
      expect(api.downloads.single['url'], e.downloadUrl.toString());
      expect(api.downloads.single['kind'], 'zim');
      expect(api.downloads.single['name'], 'wikipedia_en_medicine_maxi_2026-09.zim');
      expect(api.downloads.single['icon_url'], e.iconUrl.toString());
      expect((api.downloads.single['origin'] as Map)['title'], 'WikiMed');
      expect(d.titleOfJob(j), 'WikiMed');
      expect(d.jobForUrl(e.downloadUrl.toString()), isNotNull);

      api.jobList = [job('f1', 'failed', url: e.downloadUrl.toString(), error: 'The connection failed: reset')];
      await d.refresh();
      await d.retry(d.jobs.single);
      expect(api.cancelled, contains('f1'));
      expect(api.downloads.length, 2);
      expect(api.downloads.last['origin'], isNotNull, reason: 'the same request again');
      await d.cancelJob(d.jobs.last);
      expect(api.cancelled.where((c) => c == 'job2').length, 2, reason: 'a running one is cancelled, then taken off the list');
      d.dispose();
    });

    test('a library link is a library download; the words for a failure never name the machine', () async {
      final d = make();
      await d.start();
      await d.downloadLibrary('https://x.example/pack.cache-library');
      expect(api.downloads.single['kind'], 'library');
      for (final msg in ['Not enough free space on the server: 5 MB needed', 'The server is out of space.', 'The file did not match its published checksum', 'The connection failed: x', 'The download server answered 500.']) {
        final words = deviceJobWords(job('a', 'failed', error: msg));
        expect(words.toLowerCase(), isNot(contains('server')), reason: msg);
        expect(words.toLowerCase(), isNot(contains('job')), reason: msg);
      }
      expect(deviceJobWords(job('a', 'failed', error: 'Not enough free space on the server')), 'Not enough space on this device.');
      d.dispose();
    });
  });

  group('uploads from this computer', () {
    test('the type is checked by the ending; room is checked from the device\'s numbers', () async {
      api.spaceInfo = const DeviceSpaceInfo(free: 30 << 30, total: 500 << 30);
      final d = make();
      await d.start();
      expect(d.whyNot(FakeLocalFile('a.zim', 1)), isNull);
      expect(d.whyNot(FakeLocalFile('A.ZIM', 1)), isNull);
      expect(d.whyNot(FakeLocalFile('x.cache-library', 1)), isNull);
      expect(d.whyNot(FakeLocalFile('x.snapshot', 1)), isNull);
      expect(d.whyNot(FakeLocalFile('x.tar.gz', 1)), isNull);
      expect(d.whyNot(FakeLocalFile('notes-2026.pdf', 1)), 'notes-2026.pdf is not a library file. Choose a .zim file, a .cache-library file or a library snapshot. Nothing was uploaded.');
      // 30 GB free of 500 GB, and the device keeps 20 GB free: 10 GB can be used
      expect(d.shortBy(FakeLocalFile('a.zim', 5 << 30)), 0);
      expect(d.shortBy(FakeLocalFile('a.zim', 15 << 30)), 5 << 30);
      api.spaceInfo = const DeviceSpaceInfo(free: 100 << 30, total: 500 << 30);
      await d.refresh();
      expect(d.shortBy(FakeLocalFile('a.zim', 80 << 30)), 0);
      expect(d.shortBy(FakeLocalFile('a.zim', 90 << 30)), 10 << 30);
      d.dispose();
    });

    test('a ZIM goes up with its progress, the tab is guarded meanwhile, and the app reads its sources when it is in place', () async {
      final d = make();
      await d.start();
      final file = FakeLocalFile('wiki.zim', 1000);
      final sent = d.send(file);
      await Future<void>.delayed(Duration.zero);
      final up = uploader.started.single;
      expect((up.kind, up.name), ('zim', 'wiki.zim'));
      expect(d.upload!.running, isTrue);
      expect(warnings, [true], reason: 'the leave-the-page warning is on while it runs');
      up.progress(400);
      expect(d.upload!.sent, 400);
      expect(d.upload!.fraction, 0.4);
      expect(d.upload!.finishing, isFalse);
      up.progress(1000);
      expect(d.upload!.finishing, isTrue, reason: 'every byte is there: the device is putting it in place');
      api.itemList = [item('wiki.zim', bytes: 1000)];
      up.finish({'name': 'wiki.zim', 'bytes': 1000});
      expect((await sent)?['name'], 'wiki.zim');
      expect(d.upload, isNull);
      expect(warnings, [true, false]);
      expect(changed, greaterThan(0));
      expect(d.wasUploaded('wiki.zim'), isTrue, reason: 'deleting it later says it can only come back by uploading again');
      // one file at a time
      final second = d.send(FakeLocalFile('b.zim', 1));
      expect(await d.send(FakeLocalFile('c.zim', 1)), isNull, reason: 'a second upload is not started while one runs');
      uploader.started.first.cancel();
      uploader.started.last.cancel();
      await second;
      d.dispose();
    });

    test('Cancel stops it and leaves nothing behind; a device that is out of space says so', () async {
      final d = make();
      await d.start();
      var sent = d.send(FakeLocalFile('wiki.zim', 1000));
      await Future<void>.delayed(Duration.zero);
      d.cancelUpload();
      expect(await sent, isNull);
      expect(uploader.started.single.cancelled, isTrue);
      expect(d.upload, isNull);
      expect(warnings.last, isFalse);

      sent = d.send(FakeLocalFile('wiki.zim', 1000));
      await Future<void>.delayed(Duration.zero);
      uploader.started.last.fail(const DeviceException('no_space', 'x', status: 507));
      expect(await sent, isNull);
      expect(d.upload!.error, 'Not enough space on this device. The partly uploaded file was removed.');
      expect(d.upload!.running, isFalse);
      d.dismissUpload();
      expect(d.upload, isNull);

      sent = d.send(FakeLocalFile('wiki.zim', 1000));
      await Future<void>.delayed(Duration.zero);
      uploader.started.last.fail(const DeviceException('interrupted', 'The connection was lost.'));
      await sent;
      expect(d.upload!.error, contains('connection was lost'));
      expect(d.upload!.error!.toLowerCase(), isNot(contains('server')));
      d.dispose();
    });

    test('a library package is only brought to the device; the app adds it', () async {
      final d = make();
      await d.start();
      final sent = d.send(FakeLocalFile('pack.cache-library', 10));
      await Future<void>.delayed(Duration.zero);
      expect(uploader.started.single.kind, 'library');
      uploader.started.single.finish({'name': 'pack.cache-library', 'bytes': 10, 'path': 'incoming/pack.cache-library'});
      expect((await sent)?['path'], 'incoming/pack.cache-library');
      expect(d.wasUploaded('pack.cache-library'), isFalse);
      d.dispose();
    });
  });

  group('the app\'s own catalogue reads go through the device', () {
    test('fetchBytes in a browser: the device\'s answers become the app\'s own failures', () async {
      api.fetchBody = Uint8List.fromList(utf8.encode('<feed/>'));
      final url = Uri.parse('https://opds.library.kiwix.org/catalog/v2/entries');
      expect(utf8.decode(await fetchBytesViaDevice(api, url)), '<feed/>');
      expect(api.fetched, url);
      Future<FetchFailure> fail(DeviceException e) async {
        api.fetchError = e;
        try {
          await fetchBytesViaDevice(api, url);
        } on FetchException catch (x) {
          return x.failure;
        }
        throw TestFailure('a FetchException was expected');
      }

      expect(await fail(const DeviceException('host_not_allowed', 'x', status: 403)), FetchFailure.notAllowed);
      expect(await fail(const DeviceException('unreachable', 'x')), FetchFailure.unreachable);
      expect(await fail(const DeviceException('upstream_status', 'x', status: 502)), FetchFailure.status);
      expect(await fail(const DeviceException('too_large', 'x', status: 413)), FetchFailure.tooLarge);
      api.fetchError = null;
      await expectLater(fetchBytesViaDevice(api, url, maxBytes: 3), throwsA(isA<FetchException>()));
    });

    test('a browser read says what kind it is: the scope and plain http reach the device, and the new refusals are the app\'s own', () async {
      api.fetchBody = Uint8List.fromList(utf8.encode('WEBVTT'));
      final cue = Uri.parse('http://tube.example/lazy-static/video-captions/x.vtt');
      await fetchBytesViaDevice(api, cue, scope: FetchScope.video, plain: true);
      expect((api.fetchedScope, api.fetchedPlain), ('video', true));
      await fetchBytesViaDevice(api, Uri.parse('https://data.cached.info/x.json'));
      expect((api.fetchedScope, api.fetchedPlain), (null, false));
      Future<FetchFailure> fail(String code) async {
        api.fetchError = DeviceException(code, 'x');
        try {
          await fetchBytesViaDevice(api, cue, scope: FetchScope.user);
        } on FetchException catch (x) {
          return x.failure;
        }
        throw TestFailure('a FetchException was expected');
      }

      expect(await fail('scope_off'), FetchFailure.notAllowed);
      expect(await fail('busy'), FetchFailure.unreachable);
      expect(await fail('unsupported_type'), FetchFailure.unreadable);
    });

    test('the HTTP side puts the scope and plain in the query', () async {
      final seen = <Uri>[];
      final a = HttpDeviceApi(client: MockClient((r) async {
        seen.add(r.url);
        return http.Response('x', 200);
      }));
      await a.fetch(Uri.parse('https://huggingface.co/api/models?search=a'), scope: FetchScope.models);
      await a.fetch(Uri.parse('http://tube.example/api/v1/videos'), scope: FetchScope.video, plain: true);
      await a.fetch(Uri.parse('https://data.cached.info/x'));
      expect(seen.map((u) => u.queryParameters), [
        {'url': 'https://huggingface.co/api/models?search=a', 'scope': 'models'},
        {'url': 'http://tube.example/api/v1/videos', 'scope': 'video', 'plain': '1'},
        {'url': 'https://data.cached.info/x'},
      ]);
    });

    test('the Kiwix catalogue in a browser gives its failures in the same words', () async {
      api.fetchBody = Uint8List.fromList(utf8.encode('<feed/>'));
      expect(await fetchCatalogueViaDevice(api, Uri.parse('https://opds.library.kiwix.org/x')), '<feed/>');
      api.fetchError = const DeviceException('unreachable', 'x');
      await expectLater(fetchCatalogueViaDevice(api, Uri.parse('https://opds.library.kiwix.org/x')), throwsA(isA<CatalogException>().having((e) => e.message, 'message', 'Cannot reach the Kiwix library. Check the connection.')));
    });

    test('the HTTP side: the calls, the error shapes and the cookie-less same-origin paths', () async {
      final seen = <String>[];
      final client = MockClient((r) async {
        seen.add('${r.method} ${r.url.path}${r.url.hasQuery ? '?${r.url.query}' : ''}');
        switch ('${r.method} ${r.url.path}') {
          case 'GET /api/library/items':
            return http.Response(jsonEncode({'ok': true, 'result': [{'id': 'zim-1', 'kind': 'zim', 'name': 'a.zim', 'title': 'A', 'bytes': 5, 'path': 'app/docs/zims/a.zim'}]}), 200);
          case 'GET /api/library/jobs':
            return http.Response(jsonEncode({'ok': true, 'result': [{'id': 'j', 'url': 'https://x/a.zim', 'kind': 'zim', 'name': 'a.zim', 'bytes': 1, 'total': 4, 'state': 'running', 'error': null}]}), 200);
          case 'GET /api/library/space':
            return http.Response(jsonEncode({'ok': true, 'result': {'free_bytes': 10, 'total_bytes': null}}), 200);
          case 'POST /api/library/download':
            expect(jsonDecode(r.body), {'url': 'https://x/a.zim', 'kind': 'zim', 'name': 'a.zim'});
            return http.Response(jsonEncode({'ok': true, 'result': {'id': 'j', 'url': 'https://x/a.zim', 'kind': 'zim', 'name': 'a.zim', 'bytes': 0, 'total': 0, 'state': 'queued', 'error': null}}), 200);
          case 'DELETE /api/library/jobs/j':
          case 'POST /api/library/rescan':
            return http.Response(jsonEncode({'ok': true, 'result': {}}), 200);
          case 'GET /api/fetch':
            return r.url.queryParameters['url'] == 'https://opds.library.kiwix.org/a%20b' ? http.Response('feed', 200) : http.Response(jsonEncode({'ok': false, 'error': {'code': 'host_not_allowed', 'message': 'no'}}), 403);
          default:
            return http.Response('', 401);
        }
      });
      final a = HttpDeviceApi(client: client);
      expect((await a.items()).single.bytes, 5);
      expect((await a.jobs()).single.fraction, 0.25);
      final s = await a.space();
      expect((s.free, s.total), (10, null));
      expect((await a.download(url: 'https://x/a.zim', kind: 'zim', name: 'a.zim')).state, 'queued');
      await a.cancelJob('j');
      await a.rescan();
      expect(utf8.decode(await a.fetch(Uri.parse('https://opds.library.kiwix.org/a b'))), 'feed');
      await expectLater(a.fetch(Uri.parse('https://evil.example/')), throwsA(isA<DeviceException>().having((e) => e.code, 'code', 'host_not_allowed')));
      await expectLater(a.removeItem('x'), throwsA(isA<DeviceException>().having((e) => e.code, 'code', 'unauthorized')));
      expect(seen, contains('GET /api/fetch?url=https%3A%2F%2Fopds.library.kiwix.org%2Fa%2520b'));
    });
  });

  test('every file ending the app accepts is a ZIM or a library, and nothing else is', () {
    expect(kindOfFileName('x.zim'), 'zim');
    expect(kindOfFileName('x.cache-library'), 'library');
    expect(kindOfFileName('x.pdf'), isNull);
    expect(kindOfFileName('zim'), isNull);
  });
}
