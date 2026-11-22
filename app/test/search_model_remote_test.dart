import 'dart:convert';
import 'dart:io';

import 'package:cache/app_state.dart';
import 'package:cache/models/search_model.dart';
import 'package:cache_llama/cache_llama.dart';
import 'package:flutter_test/flutter_test.dart';

/// A web CacheEmbedder as the browser makes it: it posts to the server's /api/embed through [http] (embedder_web.dart does the same
/// with fetch), here a fake server.
class _Remote extends CacheEmbedder {
  _Remote(String path, this.http) : super(modelPath: path);
  final EmbedHttp http;
  @override
  Future<List<double>> embed(String text) async => (await embedRemote(http, [text])).first;
}

String _status(String state, {int? bytes, String? error}) => jsonEncode({
      'ok': true,
      'result': {'state': state, 'file': 'bge-m3-Q8_0.gguf', 'size': 634553856, 'library_found': true, 'bytes': ?bytes, 'total': ?(bytes == null ? null : 100), 'error': ?error},
    });

/// The server's embedder routes, as far as the browser calls them.
class _Server {
  String state = 'missing';
  int embedCalls = 0;
  final bodies = <String>[];
  int statusPolls = 0;
  int pollsUntilReady = 2;

  Future<({int status, String body})> call(String method, String path, String? body) async {
    switch ('$method $path') {
      case 'GET /api/models/embedder':
        statusPolls++;
        if (state == 'downloading' && statusPolls > pollsUntilReady) state = 'ready';
        return (status: 200, body: _status(state, bytes: state == 'downloading' ? 40 : null));
      case 'POST /api/models/embedder/download':
        if (state == 'missing') state = 'downloading';
        return (status: 200, body: _status(state, bytes: state == 'downloading' ? 0 : null));
      case 'POST /api/embed':
        embedCalls++;
        bodies.add(body!);
        if (state != 'ready') {
          return (status: 503, body: jsonEncode({'ok': false, 'error': {'code': 'model_missing', 'message': 'The search model is downloading'}}));
        }
        final texts = (jsonDecode(body) as Map)['texts'] as List;
        return (
          status: 200,
          body: jsonEncode({'ok': true, 'result': {'vectors': [for (final _ in texts) [0.25, 0.5, 0.75]], 'model': 'bge-m3-Q8_0.gguf', 'dims': 3}}),
        );
    }
    return (status: 404, body: '{}');
  }
}

void main() {
  late Directory dir;
  late _Server server;
  late SearchModel sm;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('search-model-remote');
    server = _Server();
    sm = SearchModel(
      app: AppState(settingsDirOverride: dir),
      modelsDir: () async => throw StateError('a browser has no models folder'),
      remote: true,
      serverHttp: server.call,
      make: (p) => _Remote(p, server.call),
      pollInterval: Duration.zero,
    );
  });
  tearDown(() {
    sm.dispose();
    dir.deleteSync(recursive: true);
  });

  test('before the server has answered, the model counts as missing and a query is not embedded', () async {
    expect(sm.state, SearchModelState.missing);
    expect(sm.has('bge-m3-Q8_0.gguf'), isFalse);
    expect(await sm.embedder('pharmacy'), isNull);
    expect(server.embedCalls, 0, reason: 'no call is made while the server is not known to have the model');
  });

  test('the state follows GET /api/models/embedder', () async {
    server.state = 'ready';
    await sm.refreshServer();
    expect(sm.state, SearchModelState.ready);
    expect(sm.has('bge-m3-Q8_0.gguf'), isTrue);
    expect(sm.has('other.gguf'), isFalse, reason: 'the browser has only the server\'s search model');
    server.state = 'downloading';
    await sm.refreshServer();
    expect(sm.state, SearchModelState.downloading);
    expect(sm.has('bge-m3-Q8_0.gguf'), isFalse);
    server.state = 'error';
    await sm.refreshServer();
    expect(sm.state, SearchModelState.failed);
  });

  test('a ready model embeds the query on the server and the vector carries the file name as its model id', () async {
    server.state = 'ready';
    await sm.refreshServer();
    final v = (await sm.embedder('somewhere to get water'))!;
    expect(v.model, 'bge-m3-Q8_0.gguf');
    expect(v.vector, [0.25, 0.5, 0.75]);
    expect(jsonDecode(server.bodies.single), {'texts': ['somewhere to get water']});
    final q = (await sm.vectorFor('bge-m3-Q8_0.gguf', 'again'))!;
    expect(q.model, 'bge-m3-Q8_0.gguf');
    expect(await sm.vectorFor('other.gguf', 'x'), isNull);
  });

  test('a server that lost its model answers model_missing: no vector, so the core searches by keywords', () async {
    server.state = 'ready';
    await sm.refreshServer();
    server.state = 'missing';
    expect(await sm.embedder('pharmacy'), isNull);
    expect(server.embedCalls, 1);
  });

  test('Get it has the server download the model and follows it until it is ready', () async {
    await sm.refreshServer();
    expect(sm.state, SearchModelState.missing);
    await sm.ensure();
    expect(sm.state, SearchModelState.ready);
    expect(server.statusPolls, greaterThan(1));
  });

  test('a download the server cannot start shows as failed with the reason', () async {
    final bad = SearchModel(
      app: AppState(settingsDirOverride: dir),
      modelsDir: () async => dir,
      remote: true,
      serverHttp: (m, p, b) async => (status: 500, body: '{}'),
    );
    addTearDown(bad.dispose);
    await bad.ensure();
    expect(bad.state, SearchModelState.failed);
    expect(bad.failure, contains('HTTP 500'));
  });

  group('embedRemote', () {
    test('an error answer carries the server\'s code', () async {
      await expectLater(
        embedRemote((m, p, b) async => (status: 503, body: jsonEncode({'ok': false, 'error': {'code': 'embed_unavailable', 'message': 'no'}})), ['x']),
        throwsA(isA<EmbedRemoteException>().having((e) => e.code, 'code', 'embed_unavailable').having((e) => e.modelMissing, 'modelMissing', isFalse)),
      );
    });

    test('an answer that is not the server\'s is bad_reply or http_<status>', () async {
      await expectLater(embedRemote((m, p, b) async => (status: 502, body: '<html>'), ['x']), throwsA(isA<EmbedRemoteException>().having((e) => e.code, 'code', 'http_502')));
      await expectLater(
        embedRemote((m, p, b) async => (status: 200, body: jsonEncode({'ok': true, 'result': {'vectors': []}})), ['x']),
        throwsA(isA<EmbedRemoteException>().having((e) => e.code, 'code', 'bad_reply')),
      );
    });

    test('the status of the download shows its fraction', () {
      final st = ServerEmbedderStatus.parse(_status('downloading', bytes: 25))!;
      expect(st.fraction, 0.25);
      expect(ServerEmbedderStatus.parse('nope'), isNull);
    });
  });
}
