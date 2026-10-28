import 'dart:convert';
import 'dart:io';

import 'package:cache/app_state.dart';
import 'package:cache/models/hf_hub.dart';
import 'package:cache/models/model_downloads.dart';
import 'package:cache/settings/app_settings.dart';
import 'package:cache/settings/data_policy.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

class _Probe implements ConnectionProbe {
  _Probe(this.kind);
  ConnectionKind kind;
  @override
  Future<ConnectionKind> current() async => kind;
  @override
  Stream<ConnectionKind> get changes => const Stream.empty();
}

/// A small stand-in for Hugging Face: search, a file listing, and downloads with HEAD, Range and a 401 for a gated file.
class _FakeHub {
  late HttpServer server;
  final body = List<int>.generate(300000, (i) => (i * 31) % 251);
  int gets = 0;
  final ranges = <String?>[];

  String get sha => sha256.convert(body).toString();

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      final r = req.response;
      final p = req.uri.path;
      if (p == '/api/models') {
        r.headers.contentType = ContentType.json;
        r.write(jsonEncode([
          {'id': 'acme/tiny-GGUF', 'downloads': 1234567, 'likes': 3},
          {'id': 'acme/locked-GGUF', 'downloads': 10, 'gated': 'auto'},
          {'id': 'acme/secret', 'private': true},
        ]));
      } else if (p == '/api/models/acme/tiny-GGUF/tree/main') {
        r.headers.contentType = ContentType.json;
        r.write(jsonEncode([
          {'type': 'file', 'path': 'README.md', 'size': 10},
          {'type': 'file', 'path': 'tiny-Q8_0.gguf', 'size': 999999, 'lfs': {'oid': 'b' * 64, 'size': 999999}},
          {'type': 'file', 'path': 'tiny-Q4_K_M.gguf', 'size': body.length, 'lfs': {'oid': sha, 'size': body.length}},
          {'type': 'file', 'path': 'big-00001-of-00002.gguf', 'size': 5},
          {'type': 'file', 'path': 'mmproj-tiny.gguf', 'size': 5},
          {'type': 'directory', 'path': 'sub'},
        ]));
      } else if (p == '/acme/tiny-GGUF/resolve/main/tiny-Q4_K_M.gguf') {
        r.headers.set('accept-ranges', 'bytes');
        final range = req.headers.value(HttpHeaders.rangeHeader);
        if (req.method == 'HEAD') {
          r.contentLength = body.length;
        } else {
          gets++;
          ranges.add(range);
          var from = 0;
          if (range != null) {
            from = int.parse(RegExp(r'bytes=(\d+)-').firstMatch(range)!.group(1)!);
            r.statusCode = 206;
            r.headers.set('content-range', 'bytes $from-${body.length - 1}/${body.length}');
          }
          r.contentLength = body.length - from;
          r.add(body.sublist(from));
        }
      } else if (p.startsWith('/acme/locked-GGUF/resolve/')) {
        r.statusCode = 401;
      } else {
        r.statusCode = 404;
      }
      await r.close();
    });
  }

  Uri get base => Uri.parse('http://127.0.0.1:${server.port}');
}

void main() {
  late _FakeHub fake;
  late Directory dir;
  late AppState app;
  late _Probe probe;
  late AppSettings settings;

  setUp(() async {
    fake = _FakeHub();
    await fake.start();
    dir = Directory.systemTemp.createTempSync('model-downloads');
    app = AppState(settingsDirOverride: dir, modelsDirOverride: Directory('${dir.path}/models'));
    app.modelsDir = Directory('${dir.path}/models')..createSync();
    settings = AppSettings(settingsDirOverride: dir);
    await settings.init();
    probe = _Probe(ConnectionKind.wifi);
  });
  tearDown(() async {
    await fake.server.close(force: true);
    dir.deleteSync(recursive: true);
  });

  ModelDownloads downloads() =>
      ModelDownloads(app: app, policy: DataPolicy(settings: settings, probe: probe), hub: HfHub(base: fake.base));

  test('search lists GGUF repositories, leaving out private ones, and marks gated ones', () async {
    final r = await HfHub(base: fake.base).search('tiny');
    expect(r.map((m) => m.id), ['acme/tiny-GGUF', 'acme/locked-GGUF']);
    expect(r.first.downloads, 1234567);
    expect(r[1].gated, isTrue);
    expect(r.first.owner, 'acme');
  });

  test('the file list keeps single-file models, smallest first, with their SHA-256', () async {
    final f = await HfHub(base: fake.base).ggufFiles('acme/tiny-GGUF');
    expect(f.map((x) => x.path), ['tiny-Q4_K_M.gguf', 'tiny-Q8_0.gguf'], reason: 'no README, split parts, projectors or folders');
    expect(f.first.sha256, fake.sha);
    expect(f.first.size, fake.body.length);
  });

  test('a download is checked against the SHA-256 and lands in the models folder', () async {
    final d = downloads();
    final f = (await d.hub.ggufFiles('acme/tiny-GGUF')).first;
    await d.start(f);
    expect(d.error, isNull);
    expect(d.finished?.fileName, 'tiny-Q4_K_M.gguf');
    expect(app.models.map((m) => m.fileName), ['tiny-Q4_K_M.gguf']);
    expect(File('${app.modelsDir!.path}/tiny-Q4_K_M.gguf.part').existsSync(), isFalse);
    expect(d.isInstalled(f), isTrue);
  });

  test('a stopped download continues from where it stopped', () async {
    final d = downloads();
    final f = (await d.hub.ggufFiles('acme/tiny-GGUF')).first;
    File('${app.modelsDir!.path}/tiny-Q4_K_M.gguf.part').writeAsBytesSync(fake.body.sublist(0, 120000));
    expect(d.partBytes(f), 120000);
    await d.start(f);
    expect(d.error, isNull);
    expect(fake.ranges.last, 'bytes=120000-');
    expect(sha256.convert(File('${app.modelsDir!.path}/tiny-Q4_K_M.gguf').readAsBytesSync()).toString(), fake.sha);
  });

  test('a file that does not match its checksum is thrown away', () async {
    final d = downloads();
    final f = (await d.hub.ggufFiles('acme/tiny-GGUF')).first;
    final wrong = HfFile(repo: f.repo, path: f.path, size: f.size, sha256: 'c' * 64);
    await d.start(wrong);
    expect(d.error, contains('checksum'));
    expect(app.models, isEmpty);
    expect(d.partBytes(f), 0);
  });

  test('on mobile data with downloads switched off it stops and asks; "Download anyway" goes ahead', () async {
    probe.kind = ConnectionKind.mobile;
    final d = downloads();
    final f = (await d.hub.ggufFiles('acme/tiny-GGUF')).first;
    await d.start(f);
    expect(d.blocked, isNotNull);
    expect(fake.gets, 0);
    await d.start(f, anyway: true);
    expect(d.blocked, isNull);
    expect(d.finished, isNotNull);
  });

  test('a repository that needs an account says so', () async {
    final d = downloads();
    await d.start(const HfFile(repo: 'acme/locked-GGUF', path: 'x.gguf', size: 10));
    expect(d.error, contains('Hugging Face account'));
  });

  test('fit: a model takes its file size plus working room out of the phone memory', () {
    const gb = 1 << 30;
    expect(ModelFit.of(3 * gb + gb ~/ 2, 8 * gb), ModelFit.fits);
    expect(ModelFit.of(5 * gb, 8 * gb), ModelFit.tight);
    expect(ModelFit.of(7 * gb, 8 * gb), ModelFit.tooBig);
    expect(ModelFit.of(gb, null), ModelFit.unknown);
  });
}
