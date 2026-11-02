import 'dart:convert';
import 'dart:io';

import 'package:cache/browse/web/build_api.dart';
import 'package:cache/browse/web/device_api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// What the device really answers (taken from a running Cache Server), read by the browser's own parsers.
String sample(String name) => File('test/fixtures/device_build/$name.json').readAsStringSync();

void main() {
  final calls = <String>[];
  late HttpBuildApi api;

  http.Client client(Map<String, String> answers, {int status = 200}) => MockClient((req) async {
        calls.add('${req.method} ${req.url.path}${req.body.isEmpty ? '' : ' ${req.body}'}');
        final body = answers[req.url.path];
        if (body == null) return http.Response('{"ok":false,"error":{"code":"not_found","message":"No such thing."}}', 404);
        return http.Response(body, status, headers: {'content-type': 'application/json'});
      });

  setUp(calls.clear);

  test('a library as the device lists it: building is a yes or no, waiting is a count', () async {
    api = HttpBuildApi(client: client({'/api/build/libraries': sample('libraries2')}));
    final libs = await api.libraries();
    expect(libs.single.title, 'Hunting and field guides');
    expect(libs.single.books, 3);
    expect(libs.single.passages, 98);
    expect(libs.single.pages, 109);
    expect(libs.single.published, isTrue);
    expect(libs.single.building, isFalse);
    expect(libs.single.waiting, 0);
    expect(libs.single.createdAt, DateTime.utc(2026, 11, 1, 23, 21, 28));
  });

  test('creating a library sends the title and reads the new library', () async {
    final one = jsonEncode({'ok': true, 'result': (jsonDecode(sample('libraries2'))['result'] as List).first});
    api = HttpBuildApi(client: client({'/api/build/libraries': one}));
    final l = await api.createLibrary('Hunting and field guides');
    expect(l.id, startsWith('hunting-and-field-guides'));
    expect(calls.single, 'POST /api/build/libraries {"title":"Hunting and field guides"}');
  });

  test('a name that is taken comes back as the device wrote it', () async {
    api = HttpBuildApi(client: MockClient((req) async => http.Response('{"ok":false,"error":{"code":"name_taken","message":"You already have a library called \\"X\\". Choose another name, or add to it."}}', 409)));
    await expectLater(
      api.createLibrary('X'),
      throwsA(isA<DeviceException>().having((e) => e.code, 'code', 'name_taken').having((e) => e.message, 'message', 'You already have a library called "X". Choose another name, or add to it.')),
    );
  });

  test('the books of a library', () async {
    api = HttpBuildApi(client: client({'/api/build/libraries/lib/books': sample('books2')}));
    final books = await api.books('lib');
    expect(books, hasLength(3));
    final b = books.first;
    expect(b.title, 'Prepper 101');
    expect(b.pages, 21);
    expect(b.passages, 16);
    expect(b.fileName, 'dup-of-prepper-101.pdf');
    expect(b.fileStem, 'dup-of-prepper-101');
    expect(b.size, 465011);
    expect(b.status, 'ready');
    expect(b.partial, isNull);
  });

  test('the queue while a book is being built: pages can be unknown, the estimate is a range', () async {
    api = HttpBuildApi(client: client({'/api/build/queue': sample('queue1')}));
    final q = await api.queue();
    expect(q.paused, isFalse);
    expect(q.blocked, isNull);
    expect(q.counts.total, 5);
    expect(q.counts.done, 1);
    expect(q.counts.skipped, 1);
    expect(q.etaLow, 14);
    expect(q.etaHigh, 29);
    final skipped = q.items.firstWhere((i) => i.skipped);
    expect(skipped.progress.pages, 0);
    expect(skipped.duplicateOf, 'Prepper 101');
    final building = q.items.firstWhere((i) => i.state == 'building');
    expect(building.progress.pieces, lessThanOrEqualTo(building.progress.piecesTotal!));
    expect(building.progress.ocrPages, 2);
    expect(building.active, isTrue);
    expect(q.items.where((i) => i.waiting).every((i) => i.position != null), isTrue);
  });

  test('the queue when everything ended: a failed book carries its sentence, no estimate', () async {
    api = HttpBuildApi(client: client({'/api/build/queue': sample('queue2')}));
    final q = await api.queue();
    expect(q.etaLow, isNull);
    expect(q.idle, isTrue);
    final failed = q.items.singleWhere((i) => i.state == 'failed');
    expect(failed.error, 'no text found in the PDF');
    expect(failed.needsAttention, isTrue);
    expect(q.counts.failed, 1);
  });

  test('the controls send what they should', () async {
    api = HttpBuildApi(client: client({
      '/api/build/queue/pause': sample('queue2'),
      '/api/build/queue/resume': sample('queue2'),
      '/api/build/queue/stop': sample('queue2'),
      '/api/build/queue/x/retry': sample('queue2'),
      '/api/build/queue/x': sample('queue2'),
    }));
    await api.pause();
    await api.resume();
    await api.stop();
    await api.retry('x');
    await api.dismiss('x');
    expect(calls, ['POST /api/build/queue/pause', 'POST /api/build/queue/resume', 'POST /api/build/queue/stop', 'POST /api/build/queue/x/retry', 'DELETE /api/build/queue/x']);
  });

  test('the drop folder: settings, counts, and each file with where it is', () async {
    api = HttpBuildApi(client: client({'/api/build/drop': sample('drop_done')}));
    final d = await api.drop();
    expect(d.settings.folder, '/var/lib/cache-server/drop');
    expect(d.settings.enabled, isTrue);
    expect(d.settings.libraryTitle, 'Hunting and field guides');
    expect(d.status.state, 'ok');
    expect(d.status.all, 4);
    expect(d.status.complete, 2);
    expect(d.status.failed, 2);
    expect(d.status.error, isNull);
    final bad = d.files.firstWhere((f) => f.state == 'failed');
    expect(bad.canRetry, isTrue);
    expect(bad.reason, 'no text found in the PDF');
    final other = d.files.firstWhere((f) => f.state == 'unsupported');
    expect(other.canRetry, isFalse);
    expect(other.reason, 'Not a file Cache can use');
    expect(d.files.where((f) => f.folder == 'complete'), hasLength(2));
  });

  test('files not taken yet, and the drop folder on and off', () async {
    api = HttpBuildApi(client: client({'/api/build/drop': sample('drop_new')}));
    final d = await api.putDrop(folder: '/srv/in', enabled: true, libraryId: 'lib');
    expect(calls.single, 'PUT /api/build/drop {"folder":"/srv/in","enabled":true,"library_id":"lib"}');
    expect(d.files.every((f) => f.state == 'new' && f.folder == 'ingest'), isTrue);
    expect(d.files.first.position, isNull);
  });

  test('a folder that is missing, and a file being built', () {
    final d = DropState.fromJson(jsonDecode('''{"settings":{"folder":"/mnt/usb/in","enabled":true,"library_id":"l","library_title":"L"},
      "status":{"state":"error","last_check":"2026-11-01T23:00:00Z","found":0,"counts":{"all":1,"queue":1,"complete":0,"failed":0},
                "error":{"code":"missing","message":"The drop folder is missing"},"stale":true},
      "files":[{"name":"a.pdf","folder":"ingest","state":"working","position":1,"size":10,"progress":{"pages":12,"pieces":3,"pieces_total":9,"ocr_pages":0},
                "item_id":"i","reason":null,"can_retry":false}]}''') as Map<String, dynamic>);
    expect(d.status.error!.code, 'missing');
    expect(d.status.stale, isTrue);
    expect(d.files.single.progress!.piecesTotal, 9);
    expect(d.files.single.position, 1);
  });

  test('a reply that is not the device\'s envelope is not taken for one', () async {
    api = HttpBuildApi(client: MockClient((req) async => http.Response('<html>', 200)));
    await expectLater(api.queue(), throwsA(isA<DeviceException>()));
  });

  test('being signed out is its own word', () async {
    api = HttpBuildApi(client: MockClient((req) async => http.Response('', 401)));
    await expectLater(api.queue(), throwsA(isA<DeviceException>().having((e) => e.code, 'code', 'unauthorized')));
  });
}
