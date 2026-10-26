import 'dart:io';
import 'dart:typed_data';

import 'package:cache/browse/zim_download.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

/// A stand-in for download.kiwix.org: /zim/f.zim redirects to a mirror (/mirror/f.zim), which serves the bytes
/// (with or without Range support); the checksum files sit next to /zim/f.zim.
class FakeKiwix {
  FakeKiwix(this.bytes, {this.ranges = true, this.sha256Ok = true, this.md5Only = false, this.corrupt = false});

  final Uint8List bytes;
  final bool ranges;
  final bool sha256Ok;
  final bool md5Only;
  final bool corrupt;
  late HttpServer server;
  final List<String?> rangeHeaders = [];
  int bodyRequests = 0;

  Uri get url => Uri.parse('http://127.0.0.1:${server.port}/zim/f.zim');

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      final res = req.response;
      final path = req.uri.path;
      if (path == '/zim/f.zim') {
        res.statusCode = 302;
        res.headers.set('location', '/mirror/f.zim');
      } else if (path == '/zim/f.zim.sha256') {
        if (md5Only || !sha256Ok) {
          res.statusCode = 404;
        } else {
          res.write('${sha256.convert(bytes)}  f.zim\n');
        }
      } else if (path == '/zim/f.zim.md5') {
        res.write('${md5.convert(bytes)}  f.zim\n');
      } else if (path == '/mirror/f.zim') {
        final served = corrupt ? (Uint8List.fromList(bytes)..[bytes.length ~/ 2] ^= 0xff) : bytes;
        if (req.method == 'HEAD') {
          res.headers.contentLength = bytes.length;
          if (ranges) res.headers.set('accept-ranges', 'bytes');
        } else {
          bodyRequests++;
          final range = req.headers.value('range');
          rangeHeaders.add(range);
          if (ranges && range != null) {
            final from = int.parse(RegExp(r'bytes=(\d+)-').firstMatch(range)!.group(1)!);
            res.statusCode = 206;
            res.headers.set('content-range', 'bytes $from-${bytes.length - 1}/${bytes.length}');
            res.headers.contentLength = bytes.length - from;
            res.add(served.sublist(from));
          } else {
            res.headers.contentLength = bytes.length;
            res.add(served);
          }
        }
      } else {
        res.statusCode = 404;
      }
      await res.close();
    });
  }

  Future<void> stop() => server.close(force: true);
}

Uint8List data(int n) => Uint8List.fromList(List.generate(n, (i) => (i * 31 + 7) & 0xff));

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('zimdl'));
  tearDown(() => tmp.deleteSync(recursive: true));

  Future<DownloadResult> run(FakeKiwix k, File part, {ZimDownloader? d, CancelToken? cancel, void Function(int, int)? onProgress}) {
    return (d ?? ZimDownloader(freeSpace: (_) => 1 << 40)).download(
      url: k.url,
      part: part,
      sha256Url: Uri.parse('${k.url}.sha256'),
      md5Url: Uri.parse('${k.url}.md5'),
      cancel: cancel,
      onProgress: onProgress,
    );
  }

  test('follows the redirect to the mirror, downloads, and verifies against the published sha256', () async {
    final k = FakeKiwix(data(300000));
    await k.start();
    addTearDown(k.stop);
    final part = File('${tmp.path}/f.zim.part');
    var last = 0;
    final r = await run(k, part, onProgress: (d, t) => last = d);
    expect(r.verified, isTrue);
    expect(r.checksumKind, 'sha256');
    expect(part.readAsBytesSync(), k.bytes);
    expect(last, 300000);
    expect(k.rangeHeaders, [null]);
  });

  test('uses the md5 when no sha256 is published', () async {
    final k = FakeKiwix(data(50000), md5Only: true);
    await k.start();
    addTearDown(k.stop);
    final r = await run(k, File('${tmp.path}/f.part'));
    expect(r.verified, isTrue);
    expect(r.checksumKind, 'md5');
  });

  test('resumes a partly downloaded file with a Range request', () async {
    final k = FakeKiwix(data(200000));
    await k.start();
    addTearDown(k.stop);
    final part = File('${tmp.path}/f.part')..writeAsBytesSync(k.bytes.sublist(0, 120000));
    final r = await run(k, part);
    expect(r.verified, isTrue);
    expect(k.rangeHeaders, ['bytes=120000-']);
    expect(part.readAsBytesSync(), k.bytes);
  });

  test('starts over when the server does not support ranges', () async {
    final k = FakeKiwix(data(100000), ranges: false);
    await k.start();
    addTearDown(k.stop);
    final part = File('${tmp.path}/f.part')..writeAsBytesSync(List.filled(40000, 1));
    final r = await run(k, part);
    expect(r.verified, isTrue);
    expect(part.readAsBytesSync(), k.bytes);
    expect(k.rangeHeaders, [null]);
  });

  test('a file that does not match its checksum is thrown away', () async {
    final k = FakeKiwix(data(100000), corrupt: true);
    await k.start();
    addTearDown(k.stop);
    final part = File('${tmp.path}/f.part');
    await expectLater(run(k, part), throwsA(isA<DownloadException>().having((e) => e.code, 'code', 'checksum')));
    expect(part.existsSync(), isFalse);
  });

  test('checks free space first and downloads nothing when there is not enough', () async {
    final k = FakeKiwix(data(100000));
    await k.start();
    addTearDown(k.stop);
    final part = File('${tmp.path}/f.part');
    final d = ZimDownloader(freeSpace: (_) => 1000);
    await expectLater(run(k, part, d: d), throwsA(isA<NoSpaceException>().having((e) => e.needed, 'needed', greaterThan(100000))));
    expect(k.bodyRequests, 0);
    expect(part.existsSync(), isFalse);
  });

  test('only the rest of a partly downloaded file counts for the space check', () async {
    final k = FakeKiwix(data(100000));
    await k.start();
    addTearDown(k.stop);
    final part = File('${tmp.path}/f.part')..writeAsBytesSync(k.bytes.sublist(0, 90000));
    // Room for the margin and the missing 10 kB, not for the whole file.
    final d = ZimDownloader(freeSpace: (_) => downloadMargin(100000) + 20000);
    final r = await run(k, part, d: d);
    expect(r.verified, isTrue);
  });

  test('cancel stops the download and keeps the partial file for later', () async {
    final k = FakeKiwix(data(4 << 20));
    await k.start();
    addTearDown(k.stop);
    final part = File('${tmp.path}/f.part');
    final token = CancelToken();
    final f = run(k, part, cancel: token, onProgress: (d, t) {
      if (d > 0) token.cancel();
    });
    await expectLater(f, throwsA(isA<DownloadException>().having((e) => e.code, 'code', 'cancelled')));
  });

  test('a missing file is reported in words', () async {
    final k = FakeKiwix(data(10));
    await k.start();
    addTearDown(k.stop);
    final d = ZimDownloader(freeSpace: (_) => 1 << 40);
    await expectLater(
      d.download(url: Uri.parse('http://127.0.0.1:${k.server.port}/zim/nothing.zim'), part: File('${tmp.path}/n.part')),
      throwsA(isA<DownloadException>().having((e) => e.message, 'message', contains('no longer'))),
    );
  });

  test('hashFile agrees with the crypto package', () async {
    final f = File('${tmp.path}/h')..writeAsBytesSync(data(70000));
    expect(await hashFile(f.path), sha256.convert(f.readAsBytesSync()).toString());
    expect(await hashFile(f.path, kind: 'md5'), md5.convert(f.readAsBytesSync()).toString());
  });
}
