import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cache/app_state.dart';
import 'package:cache/browse/web/local_files.dart';
import 'package:cache/downloads/download_row.dart';
import 'package:cache/models/hf_hub.dart';
import 'package:cache/models/model_downloads.dart';
import 'package:cache/models/server_models.dart';
import 'package:cache/platform/memory.dart';
import 'package:flutter_test/flutter_test.dart';

/// A stand-in for the server's model routes (server/src/models.rs): it keeps what it was asked and answers as the server does.
class _FakeServer {
  final calls = <String>[];
  final bodies = <String, Map<String, dynamic>>{};
  final jobs = <String, Map<String, Object?>>{};
  final files = <String, int>{'chat-a.gguf': 100};
  bool searchReady = false;
  int? failWith;

  Future<({int status, String body})> call(String method, String path, String? body) async {
    calls.add('$method $path');
    Object? ok(Object? r) => jsonEncode({'ok': true, 'result': r});
    ({int status, String body}) good(Object? r) => (status: 200, body: ok(r) as String);
    if (failWith != null) return (status: failWith!, body: jsonEncode({'error': {'code': 'x', 'message': 'The server said no.'}}));
    if (method == 'GET' && path == '/api/models/downloads') return good({'downloads': jobs.values.toList()});
    if (method == 'GET' && path == '/api/models/embedder') return good({'state': searchReady ? 'ready' : 'missing'});
    if (method == 'GET' && path.startsWith('/api/llm/models')) {
      return good({'models': [for (final e in files.entries) {'id': e.key, 'size': e.value, 'loaded': false}]});
    }
    if (method == 'GET' && path == '/api/system/memory') return good({'total': 16 << 30, 'avail': 8 << 30, 'threshold': 0, 'low': false});
    if (method == 'POST' && path == '/api/models/downloads') {
      final b = jsonDecode(body!) as Map<String, dynamic>;
      bodies[b['name'] as String] = b;
      jobs[b['name'] as String] = {'name': b['name'], 'state': 'queued', 'done': 0, 'total': b['size']};
      return good({'downloads': jobs.values.toList()});
    }
    if (method == 'POST' && path.endsWith('/pause')) {
      final n = Uri.decodeComponent(path.split('/')[4]);
      jobs[n]!['state'] = 'paused';
      return good({});
    }
    if (method == 'DELETE' && path.startsWith('/api/models/downloads/')) {
      jobs.remove(Uri.decodeComponent(path.split('/').last));
      return good({});
    }
    if (method == 'DELETE' && path.startsWith('/api/models/files/')) {
      files.remove(Uri.decodeComponent(path.split('/').last));
      return good({'deleted': true});
    }
    return (status: 404, body: '{}');
  }
}

class _Task implements UploadTask {
  _Task(this.result);
  final Future<Map<String, dynamic>> result;
  @override
  Future<Map<String, dynamic>> get done => result;
  @override
  void cancel() {}
}

class _Uploader implements RawUploader {
  String? url;
  @override
  UploadTask post(LocalFile file, String url, UploadProgress onProgress) {
    this.url = url;
    onProgress(5, 10);
    return _Task(Future.value({'name': file.name}));
  }
}

class _File implements LocalFile {
  @override
  String get name => 'my model.gguf';
  @override
  int get size => 10;
  @override
  Future<Uint8List> readAll() async => Uint8List(0);
}

const _hf = HfFile(repo: 'acme/tiny-GGUF', path: 'dir/tiny-Q4.gguf', size: 1000, sha256: 'ab', revision: 'abc');
final _direct = HfFile(repo: '', path: 'e2b.gguf', size: 2000, url: Uri.parse('https://data.cached.info/models/e2b.gguf'));
const _search = HfFile(repo: 'x/bge', path: 'bge-m3-Q8_0.gguf', size: 600);

void main() {
  late Directory dir;
  late _FakeServer fake;
  late ServerModels server;
  late AppState app;
  late ModelDownloads d;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('server-models');
    fake = _FakeServer();
    server = ServerModels(http: fake.call);
    app = AppState(settingsDirOverride: dir, server: server);
    d = ModelDownloads(app: app, server: server, searchModel: _search);
  });

  tearDown(() {
    d.dispose();
    dir.deleteSync(recursive: true);
  });

  test('a Hugging Face file is asked for by repository, revision and path; a published one by address', () async {
    await server.add(_hf, search: true);
    expect(fake.bodies['tiny-Q4.gguf'], {
      'name': 'tiny-Q4.gguf', 'size': 1000, 'sha256': 'ab', 'search': true, 'repo': 'acme/tiny-GGUF', 'revision': 'abc', 'path': 'dir/tiny-Q4.gguf',
    });
    await server.add(_direct);
    expect(fake.bodies['e2b.gguf'], {'name': 'e2b.gguf', 'size': 2000, 'url': 'https://data.cached.info/models/e2b.gguf'});
  });

  test('the server\'s words come back as the reason, and an unreachable server says so', () async {
    fake.failWith = 403;
    await expectLater(server.add(_hf), throwsA(isA<ServerModelsException>().having((e) => e.message, 'message', 'The server said no.')));
    final down = ServerModels(http: (m, p, b) async => throw const SocketException('refused'));
    await expectLater(down.downloads(), throwsA(isA<ServerModelsException>()));
    expect(await down.memory(), isNull);
  });

  test('the memory is the server\'s, with the phone\'s reading', () async {
    final m = await server.memory();
    expect((m!.total, m.avail, m.room), (16 << 30, 8 << 30, 8 << 30));
    expect(memoryFromServerBody('nope'), isNull);
    expect(memoryFromServerBody('{"ok":true,"result":{"total":0,"avail":1}}'), isNull);
  });

  test('an upload goes to the server by name, with its progress', () async {
    final up = _Uploader();
    var seen = 0;
    await ServerModels(http: fake.call, uploader: () => up).upload(_File(), 'my model.gguf', (s, t) => seen = s);
    expect(up.url, '/api/models/upload?name=my%20model.gguf');
    expect(seen, 5);
  });

  test('a download starts on the server, shows its progress, finishes into the model list and says "use it"', () async {
    await d.start(_hf);
    expect(fake.bodies['tiny-Q4.gguf']!['search'], isTrue, reason: 'the first chat model brings the search model');
    expect(d.stateOf(_hf).phase, DlPhase.waiting);
    fake.jobs['tiny-Q4.gguf'] = {'name': 'tiny-Q4.gguf', 'state': 'running', 'done': 400, 'total': 1000};
    await d.refreshRemote();
    expect(d.stateOf(_hf).phase, DlPhase.running);
    expect((d.stateOf(_hf).done, d.stateOf(_hf).total), (400, 1000));
    expect(d.current?.fileName, 'tiny-Q4.gguf');
    fake.jobs['tiny-Q4.gguf'] = {'name': 'tiny-Q4.gguf', 'state': 'verifying', 'done': 1000, 'total': 1000};
    await d.refreshRemote();
    expect(d.stateOf(_hf).phase, DlPhase.verifying);
    fake.jobs['tiny-Q4.gguf'] = {'name': 'tiny-Q4.gguf', 'state': 'done', 'done': 1000, 'total': 1000};
    fake.files['tiny-Q4.gguf'] = 1000;
    await d.refreshRemote();
    expect(d.current, isNull);
    expect(app.models.map((m) => m.fileName), contains('tiny-Q4.gguf'));
    expect(d.finished?.fileName, 'tiny-Q4.gguf');
    expect(d.stateOf(_hf).phase, DlPhase.done);
  });

  test('a second download waits for the first by name; pause and resume continue the same file', () async {
    await d.start(_hf);
    await d.start(_direct);
    fake.jobs['tiny-Q4.gguf']!.addAll({'state': 'running', 'done': 10});
    await d.refreshRemote();
    final waiting = d.stateOf(_direct);
    expect(waiting.phase, DlPhase.waiting);
    expect(waiting.waitingFor, 'tiny-Q4');
    d.pause(_hf);
    expect(d.stateOf(_hf).phase, DlPhase.pausing);
    await Future<void>.delayed(Duration.zero);
    await d.refreshRemote();
    expect(d.stateOf(_hf).phase, DlPhase.paused);
    expect(d.partBytes(_hf), 10);
    expect(fake.calls, contains('POST /api/models/downloads/tiny-Q4.gguf/pause'));
    await d.resume(_hf);
    expect(d.stateOf(_hf).phase, DlPhase.waiting, reason: 'the server queued it again');
  });

  test('a failed download keeps its reason and Hugging Face accounts are named', () async {
    await d.start(_hf);
    fake.jobs['tiny-Q4.gguf'] = {
      'name': 'tiny-Q4.gguf', 'state': 'failed', 'done': 5, 'total': 1000,
      'error': 'This model needs a Hugging Face account to download. Get it in a browser, then use "Choose a file".',
    };
    await d.refreshRemote();
    final s = d.stateOf(_hf);
    expect(s.phase, DlPhase.failed);
    expect(s.reasonText, 'this model needs a Hugging Face account');
    expect(d.error, contains('Hugging Face account'));
  });

  test('a failure is told by the download that failed: not over a later download, not after a reload, and it goes when that download is removed', () async {
    await d.start(_hf);
    fake.jobs['tiny-Q4.gguf'] = {'name': 'tiny-Q4.gguf', 'state': 'failed', 'done': 5, 'total': 1000, 'error': 'The connection failed: reset'};
    await d.refreshRemote();
    expect(d.error, 'The connection failed: reset');
    // a second download starts: the server still lists the first as failed
    await d.start(_direct);
    expect(d.error, isNull);
    await d.refreshRemote();
    await d.refreshRemote();
    expect(d.error, isNull, reason: 'the first download\'s failure is not told over the second');
    expect(d.stateOf(_hf).phase, DlPhase.failed, reason: 'its own row still says it stopped');
    expect(d.stateOf(_direct).phase, DlPhase.waiting);
    // the page is loaded again
    final again = ModelDownloads(app: app, server: server, searchModel: _search);
    addTearDown(again.dispose);
    await again.refreshRemote();
    expect(again.error, isNull, reason: 'an old failure is not told again');
    // tried again and failed again: told again, and removed with the download
    await d.resume(_hf);
    expect(d.error, isNull);
    fake.jobs['tiny-Q4.gguf'] = {'name': 'tiny-Q4.gguf', 'state': 'failed', 'done': 5, 'total': 1000, 'error': 'The download site answered 503.'};
    await d.refreshRemote();
    expect(d.error, 'The download site answered 503.');
    await d.remove(_hf);
    expect(d.error, isNull);
    expect(d.stateOf(_hf).phase, DlPhase.idle);
  });

  test('a server that cannot be asked shows on the row of what was downloading, and clears when it answers', () async {
    await d.start(_hf);
    fake.jobs['tiny-Q4.gguf'] = {'name': 'tiny-Q4.gguf', 'state': 'running', 'done': 400, 'total': 1000};
    await d.refreshRemote();
    expect(d.serverProblem, isNull);
    fake.failWith = 401;
    await d.refreshRemote();
    expect(d.serverProblem, 'Sign in again.');
    final out = d.stateOf(_hf);
    expect((out.phase, out.waitLine, out.done), (DlPhase.waiting, 'Sign in again.', 400));
    fake.failWith = 500;
    await d.refreshRemote();
    expect(d.stateOf(_hf).waitLine, 'The server could not be reached.');
    fake.failWith = null;
    await d.refreshRemote();
    expect(d.serverProblem, isNull);
    expect(d.stateOf(_hf).phase, DlPhase.running);
  });

  test('a refused request ends in a failed row, not a thrown error', () async {
    fake.failWith = 403;
    await d.start(_hf);
    expect(d.stateOf(_hf).phase, DlPhase.failed);
    expect(d.error, 'The server said no.');
  });

  test('Remove asks the server to stop and discard', () async {
    await d.start(_hf);
    await d.remove(_hf);
    expect(fake.jobs, isEmpty);
    expect(d.stateOf(_hf).phase, DlPhase.idle);
  });

  test('a tab opened while the server downloads shows it, and the search model\'s own download is its row', () async {
    fake.jobs['bge-m3-Q8_0.gguf'] = {'name': 'bge-m3-Q8_0.gguf', 'state': 'running', 'done': 100, 'total': 600};
    await d.refreshRemote();
    expect(d.stateOf(_search).phase, DlPhase.running);
    expect(d.searchModelQueued, isTrue);
    d.pause(_search);
    expect(d.stateOf(_search).phase, DlPhase.running, reason: 'the embedder\'s download cannot be paused');
    fake.jobs.clear();
    fake.searchReady = true;
    await d.refreshRemote();
    expect(d.hasSearchModel, isTrue);
    expect(d.stateOf(_search).phase, DlPhase.done);
    expect(d.searchModelQueued, isFalse);
  });

  test('the search model is started through the embedder\'s own route', () async {
    await d.start(_search);
    expect(fake.calls, contains('POST /api/models/embedder/download'));
    expect(fake.bodies, isEmpty);
  });

  test('the model list, delete and the kept loaded model come from the server', () async {
    await app.refreshModels();
    expect(app.models.map((m) => m.fileName), ['chat-a.gguf']);
    expect(await app.deleteModel(app.models.first), isTrue);
    expect(fake.files, isEmpty);
    expect(app.models, isEmpty);
    fake.files['b.gguf'] = 1;
    await app.refreshModels();
    fake.failWith = 409;
    expect(await app.deleteModel(app.models.first), isFalse);
    expect(app.loadError, contains('The server said no.'));
  });
}
