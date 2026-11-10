import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';

import '../bin/offroad_packs.dart';

void main() {
  const path = 'na-1/US-ID/offroad.sqlite';
  late Directory tmp;
  late HttpServer server;
  late OffroadPacks packs;
  late List<String> hits;
  late Completer<void> stall;
  var stalling = false;
  var redirecting = false;

  final body = List<int>.generate(4000, (i) => i % 251);

  Future<void> until(bool Function() ok) async {
    for (var i = 0; i < 200 && !ok(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
  }

  Map<String, dynamic> status() => (packs.status([path])[path] as Map).cast<String, dynamic>();

  Map<String, dynamic> pack() => {'path': path, 'url': 'http://127.0.0.1:${server.port}/pack', 'bytes': body.length};

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('offroad_packs_test');
    hits = [];
    stall = Completer<void>();
    stalling = false;
    redirecting = false;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      hits.add(req.uri.path);
      final res = req.response;
      if (req.uri.path == '/target') {
        res.add(body);
      } else if (redirecting) {
        res.statusCode = HttpStatus.found;
        res.headers.set(HttpHeaders.locationHeader, 'http://127.0.0.1:${server.port}/target');
      } else if (stalling) {
        res.contentLength = body.length;
        res.add(body.sublist(0, 1000));
        await res.flush();
        await stall.future;
      } else {
        final range = req.headers.value(HttpHeaders.rangeHeader);
        final from = range == null ? 0 : int.parse(RegExp(r'bytes=(\d+)-').firstMatch(range)!.group(1)!);
        if (from > 0) res.statusCode = HttpStatus.partialContent;
        res.contentLength = body.length - from;
        res.add(body.sublist(from));
      }
      try {
        await res.close();
      } on Object {
        // The client went away.
      }
    });
    packs = OffroadPacks(Directory('${tmp.path}/offroad'),
        allowed: (u) => u.host == '127.0.0.1', idleTimeout: const Duration(milliseconds: 200));
  });

  tearDown(() async {
    if (!stall.isCompleted) stall.complete();
    await server.close(force: true);
    tmp.deleteSync(recursive: true);
  });

  test('a redirect fails the job and the target is never requested', () async {
    redirecting = true;
    packs.fetch(pack());
    await until(() => status()['running'] == false);
    expect(status()['running'], isFalse);
    expect(status()['error'], isNotNull);
    expect(hits, ['/pack']);
    expect(File('${tmp.path}/offroad/$path').existsSync(), isFalse);
  });

  test('a download that goes idle fails, keeps the part, and a retry finishes it', () async {
    stalling = true;
    packs.fetch(pack());
    await until(() => status()['running'] == false);
    expect(status()['running'], isFalse);
    expect(status()['error'], isNotNull);
    final part = File('${tmp.path}/offroad/na-1/US-ID/.offroad.sqlite.part');
    expect(part.existsSync(), isTrue);
    expect(part.lengthSync(), 1000);

    stalling = false;
    packs.fetch(pack());
    final dest = File('${tmp.path}/offroad/$path');
    await until(() => dest.existsSync());
    expect(dest.readAsBytesSync(), body);
    expect(part.existsSync(), isFalse);
  });
}
