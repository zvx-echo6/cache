import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cache/app_state.dart';
import 'package:cache/models/hf_hub.dart';
import 'package:cache/models/model_downloads.dart';
import 'package:cache/models/search_model.dart';
import 'package:cache/screens/model_search_screen.dart';
import 'package:cache/screens/search_model_line.dart';
import 'package:cache/sources/sources_state.dart';
import 'package:cache/theme.dart';
import 'package:cache_llama/cache_llama.dart';
import 'package:cache_search/cache_search.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Fake extends CacheEmbedder {
  _Fake(String path) : super(modelPath: path);
  final List<String> asked = [];
  @override
  Future<List<double>> embed(String text) async {
    asked.add(text);
    return [0.25, 0.5, 0.75];
  }
}

/// Hugging Face as far as two downloads go: a chat model and the search model, which must be asked for at its pinned commit.
class _Hub {
  late HttpServer server;
  final chat = List<int>.generate(50000, (i) => (i * 7) % 251);
  final search = List<int>.generate(40000, (i) => (i * 13) % 251);
  final paths = <String>[];

  /// While not completed, the chat model's body waits, so a test can look at the queue.
  Completer<void>? hold;

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      final r = req.response;
      final p = req.uri.path;
      List<int>? body;
      if (p == '/acme/chat-GGUF/resolve/main/chat-Q4.gguf') body = chat;
      if (p == '/acme/bge-GGUF/resolve/abc123/bge-m3-Q8_0.gguf') body = search;
      if (body == null) {
        r.statusCode = 404;
        await r.close();
        return;
      }
      if (req.method != 'HEAD') paths.add(p);
      if (req.method != 'HEAD' && body == chat && hold != null) await hold!.future;
      r.headers.set('accept-ranges', 'bytes');
      r.contentLength = body.length;
      if (req.method != 'HEAD') r.add(body);
      await r.close();
    });
  }

  Uri get base => Uri.parse('http://127.0.0.1:${server.port}');
  HfFile get chatFile => HfFile(repo: 'acme/chat-GGUF', path: 'chat-Q4.gguf', size: chat.length, sha256: sha256.convert(chat).toString());
  HfFile get searchFile => HfFile(
    repo: 'acme/bge-GGUF',
    path: 'bge-m3-Q8_0.gguf',
    size: search.length,
    sha256: sha256.convert(search).toString(),
    revision: 'abc123',
  );
}

/// The core as far as search goes: a ZIM, or a "library" (a file named lib-...) whose settings name an embedding model.
/// A search answers with one hit whose title is the model of the query vector it was given ("none" without one).
class _SearchNative implements CsNative {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);

  List<String> paths = [];

  List<String> _paths(String configJson) => [
    for (final s in ((jsonDecode(configJson) as Map)['sources'] as List? ?? const [])) (s as Map)['path'] as String,
  ];

  String? _model(String p) => p.contains('lib-bge') ? 'bge-m3-Q8_0.gguf' : (p.contains('lib-other') ? 'other.gguf' : null);

  @override
  int open(String configJson) {
    paths = _paths(configJson);
    return 1;
  }

  @override
  int setSources(int handle, String configJson) {
    paths = _paths(configJson);
    return 0;
  }

  @override
  String? status(int handle) => jsonEncode({
    'sources': [
      for (final p in paths)
        {
          'id': p.split(RegExp(r'[\\/]')).last,
          'kind': _model(p) == null ? 'zim' : 'library',
          'path': p,
          'title': p,
          'indexed': true,
          'building': false,
          'docs': 1,
          'embedding_model': _model(p),
        },
    ],
  });

  @override
  String? search(int handle, String query, String optionsJson) {
    final o = jsonDecode(optionsJson) as Map;
    final qv = o['query_vector'] as Map?;
    return jsonEncode({
      'results': [
        {'address': 'zim://x/A/1', 'title': qv == null ? 'none' : qv['model'], 'snippet': '${(qv?['vector'] as List?)?.length ?? 0}'},
      ],
      'total_estimate': 1,
    });
  }

  @override
  String? lastError(int handle) => null;

  @override
  void close(int handle) {}

  @override
  int clearLocation(int handle) => 0;
}

CsNative _makeSearchNative() => _SearchNative();

class _Embedding implements LibraryEmbedding {
  _Embedding(this.present);
  final Set<String> present;
  final asked = <String>[];
  @override
  String get defaultModel => kSearchModel.fileName;
  @override
  bool has(String model) => present.contains(model);
  @override
  Future<QueryVector?> vectorFor(String model, String text) async {
    asked.add('$model:$text');
    return QueryVector(model, [1, 2, 3]);
  }
}

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('search-model'));
  tearDown(() => dir.deleteSync(recursive: true));

  group('the embedder', () {
    test('without the model file there is no query vector, so the core searches by keywords', () async {
      final e = SearchEmbedder(modelsDir: () async => dir, make: _Fake.new);
      expect(await e('pharmacy'), isNull);
    });

    test('with the file the query vector carries the file name as its model id, which is what the pack records', () async {
      File('${dir.path}/${kSearchModel.fileName}').writeAsStringSync('x');
      final made = <_Fake>[];
      final e = SearchEmbedder(modelsDir: () async => dir, make: (p) => _Fake(p)..also(made.add));
      final v = (await e('somewhere to get water'))!;
      expect(v.model, 'bge-m3-Q8_0.gguf');
      expect(v.vector, [0.25, 0.5, 0.75]);
      await e('again');
      expect(made, hasLength(1), reason: 'one embedder, loaded once');
      expect(made.single.asked, ['somewhere to get water', 'again']);
    });

    test('the pinned file is the decided bge-m3 Q8_0, downloaded from its commit', () {
      expect(kSearchModel.fileName, 'bge-m3-Q8_0.gguf');
      expect(kSearchModel.size, 634553856);
      expect(kSearchModel.sha256, 'c98c7c907bb3ab8c3be4c8ad827cc934c7c1a7e014d1c999e0c45c8027c158bb');
      expect(HfHub().downloadUrl(kSearchModel.file).toString(),
          'https://huggingface.co/lm-kit/bge-m3-gguf/resolve/9379ce497e8814b200f2dc0d18eb4045426dcb8c/bge-m3-Q8_0.gguf');
    });
  });

  group('in the models folder', () {
    late AppState app;
    setUp(() async {
      app = AppState(settingsDirOverride: dir, modelsDirOverride: Directory('${dir.path}/models'));
      Directory('${dir.path}/models').createSync();
    });

    test('the search model is not a chat model: it is left out of the list and kept apart', () async {
      File('${dir.path}/models/chat-Q4.gguf').writeAsBytesSync([1, 2]);
      File('${dir.path}/models/bge-m3-Q8_0.gguf').writeAsBytesSync([1, 2, 3]);
      await app.init();
      expect(app.models.map((m) => m.fileName), ['chat-Q4.gguf']);
      expect(app.searchModel?.fileName, 'bge-m3-Q8_0.gguf');
      final sm = SearchModel(app: app, modelsDir: () async => app.modelsDir!);
      addTearDown(sm.dispose);
      expect(sm.state, SearchModelState.ready);
    });

    test('an install with a chat model is offered the search model once, and the answer is kept', () async {
      File('${dir.path}/models/chat-Q4.gguf').writeAsBytesSync([1, 2]);
      await app.init();
      final sm = SearchModel(app: app, modelsDir: () async => app.modelsDir!);
      addTearDown(sm.dispose);
      expect(sm.shouldOffer, isTrue);
      await sm.markOffered();
      expect(sm.shouldOffer, isFalse);
      final again = AppState(settingsDirOverride: dir, modelsDirOverride: Directory('${dir.path}/models'));
      await again.init();
      expect(again.searchModelOffered, isTrue, reason: 'read back from the settings file');
    });

    test('no offer without a chat model, nor when the search model is there', () async {
      await app.init();
      final sm = SearchModel(app: app, modelsDir: () async => app.modelsDir!);
      addTearDown(sm.dispose);
      expect(sm.shouldOffer, isFalse, reason: 'no chat model: it comes with the first one');
      File('${dir.path}/models/chat-Q4.gguf').writeAsBytesSync([1, 2]);
      File('${dir.path}/models/bge-m3-Q8_0.gguf').writeAsBytesSync([1, 2, 3]);
      await app.refreshModels();
      expect(sm.shouldOffer, isFalse);
    });

    test('a library naming the search model uses the shared embedder; another model is used only when its file is here', () async {
      await app.init();
      final sm = SearchModel(app: app, modelsDir: () async => app.modelsDir!, make: _Fake.new);
      addTearDown(sm.dispose);
      expect(sm.has('bge-m3-Q8_0.gguf'), isFalse);
      expect(sm.has('other.gguf'), isFalse);
      expect(sm.has('../other.gguf'), isFalse);
      File('${dir.path}/models/bge-m3-Q8_0.gguf').writeAsBytesSync([1]);
      File('${dir.path}/models/other.gguf').writeAsBytesSync([1]);
      await app.refreshModels();
      expect(sm.has('bge-m3-Q8_0.gguf'), isTrue);
      expect(sm.has('other.gguf'), isTrue);
      expect((await sm.vectorFor('bge-m3-Q8_0.gguf', 'q'))!.model, 'bge-m3-Q8_0.gguf');
      expect((await sm.vectorFor('other.gguf', 'q'))!.model, 'other.gguf');
    });
  });

  group('downloads', () {
    late _Hub hub;
    late AppState app;
    late ModelDownloads d;
    setUp(() async {
      hub = _Hub();
      await hub.start();
      app = AppState(settingsDirOverride: dir, modelsDirOverride: Directory('${dir.path}/models'));
      app.modelsDir = Directory('${dir.path}/models')..createSync();
      d = ModelDownloads(app: app, hub: HfHub(base: hub.base), searchModel: hub.searchFile);
    });
    tearDown(() => hub.server.close(force: true));

    Future<void> until(bool Function() done) async {
      for (var i = 0; i < 500 && !done(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(done(), isTrue);
    }

    test('the first chat model brings the search model after it, from its pinned commit, and it is not queued twice', () async {
      hub.hold = Completer<void>();
      final run = d.start(hub.chatFile);
      await until(() => d.busy);
      expect(d.queue.map((f) => f.fileName), ['bge-m3-Q8_0.gguf']);
      expect(d.searchModelQueued, isTrue);
      await d.start(hub.searchFile);
      expect(d.queue, hasLength(1), reason: 'already waiting');
      hub.hold!.complete();
      await run;
      expect(d.finished?.fileName, 'chat-Q4.gguf', reason: 'the chat model is the one offered for use');
      await until(() => app.searchModel != null && !d.busy);
      expect(hub.paths, ['/acme/chat-GGUF/resolve/main/chat-Q4.gguf', '/acme/bge-GGUF/resolve/abc123/bge-m3-Q8_0.gguf']);
      expect(app.models.map((m) => m.fileName), ['chat-Q4.gguf']);
      expect(d.finished?.fileName, 'chat-Q4.gguf');

      // A second chat model does not bring it again.
      await d.start(HfFile(repo: 'acme/chat-GGUF', path: 'chat-Q4.gguf', size: hub.chat.length, sha256: sha256.convert(hub.chat).toString()));
      expect(d.queue, isEmpty);
      expect(hub.paths.where((p) => p.contains('bge')), hasLength(1));
    });

    test('stopping the chat model drops the search model waiting after it', () async {
      hub.hold = Completer<void>();
      final run = d.start(hub.chatFile);
      await until(() => d.busy);
      expect(d.queue, hasLength(1));
      d.cancel();
      hub.hold!.complete();
      await run;
      expect(d.queue, isEmpty);
      expect(d.busy, isFalse);
      expect(app.searchModel, isNull);
    });

    test('a failed search model download is told apart from the chat model, and Try again starts it', () async {
      final bad = HfFile(repo: 'acme/bge-GGUF', path: 'bge-m3-Q8_0.gguf', size: hub.search.length, sha256: 'c' * 64, revision: 'abc123');
      final d2 = ModelDownloads(app: app, hub: HfHub(base: hub.base), searchModel: bad);
      final sm = SearchModel(app: app, downloads: d2, modelsDir: () async => app.modelsDir!);
      addTearDown(sm.dispose);
      await sm.ensure();
      expect(sm.state, SearchModelState.failed);
      expect(sm.failure, contains('checksum'));
      expect(d2.error, isNull);
    });

    testWidgets('the bar shows the search model waiting under the chat model, and a stopped one with Try again', (tester) async {
      d.queue.add(hub.searchFile);
      d.current = hub.chatFile;
      d.total = 100;
      await tester.pumpWidget(MaterialApp(theme: buildTheme(CacheThemeId.dark), home: Scaffold(body: ModelDownloadBar(downloads: d))));
      expect(find.text('Next: Search model, 635 MB'), findsOneWidget);
      d.current = null;
      d.searchModelError = 'the connection dropped';
      d.cancel(); // tells the bar
      await tester.pump();
      expect(find.text('Search model: download stopped (the connection dropped)'), findsOneWidget);
      expect(find.byKey(const ValueKey('search-model-retry')), findsOneWidget);
    });
  });

  group('library and tool search', () {
    late Directory zims;
    setUp(() => zims = Directory('${dir.path}/zims')..createSync());

    Future<SourcesState> open(List<String> names, LibraryEmbedding? e) async {
      for (final n in names) {
        File('${zims.path}/$n').writeAsBytesSync([0]);
      }
      final s = SourcesState(
        zimsDirOverride: zims,
        indexesDirOverride: Directory('${dir.path}/indexes'),
        nativeFactory: _makeSearchNative,
        coreExtras: const {},
      )..embedding = e;
      addTearDown(s.dispose);
      await s.init();
      return s;
    }

    test('with the search model, library search and the tool search send its query vector', () async {
      final e = _Embedding({'bge-m3-Q8_0.gguf'});
      final s = await open(['a.zim', 'lib-bge.zim'], e);
      expect((await s.search('water')).single.title, 'bge-m3-Q8_0.gguf');
      expect((await s.searchIn('water')).results.single.title, 'bge-m3-Q8_0.gguf');
      expect((await s.searchIn('water', zimIds: ['lib-bge.zim'])).results.single.snippet, '3');
      expect(e.asked, ['bge-m3-Q8_0.gguf:water', 'bge-m3-Q8_0.gguf:water', 'bge-m3-Q8_0.gguf:water']);
      expect(s.missingModel(), isNull);
    });

    test('without it the search runs on keywords and the missing model is named', () async {
      final e = _Embedding({});
      final s = await open(['lib-bge.zim'], e);
      expect((await s.search('water')).single.title, 'none');
      expect((await s.searchIn('water')).results.single.title, 'none');
      expect(e.asked, isEmpty);
      expect(s.missingModel(), 'bge-m3-Q8_0.gguf');
    });

    test('ZIMs alone are never embedded for, and need no model', () async {
      final e = _Embedding({'bge-m3-Q8_0.gguf'});
      final s = await open(['a.zim'], e);
      expect((await s.search('water')).single.title, 'none');
      expect(e.asked, isEmpty, reason: 'no library has vectors, so the model is not loaded');
      expect(s.missingModel(), isNull);
    });

    test('a library naming another model gets that model, not the search model', () async {
      final e = _Embedding({'other.gguf', 'bge-m3-Q8_0.gguf'});
      final s = await open(['lib-other.zim'], e);
      expect((await s.searchIn('water')).results.single.title, 'other.gguf');
      final missing = await open(['lib-other.zim'], _Embedding({'bge-m3-Q8_0.gguf'}));
      expect((await missing.searchIn('water')).results.single.title, 'none');
      expect(missing.missingModel(), 'other.gguf');
    });
  });

  group('the missing-model line', () {
    Widget wrap(Widget w) => MaterialApp(theme: buildTheme(CacheThemeId.dark), home: Scaffold(body: w));

    testWidgets('says meaning search needs the search model, with Get it', (tester) async {
      final app = AppState(settingsDirOverride: dir, modelsDirOverride: dir);
      final sm = SearchModel(app: app, modelsDir: () async => dir);
      addTearDown(sm.dispose);
      await tester.pumpWidget(wrap(SearchModelLine(searchModel: sm)));
      expect(find.text('Meaning search needs the search model.'), findsOneWidget);
      expect(find.text('Get it'), findsOneWidget);
    });

    testWidgets('names another model a library needs, with no button', (tester) async {
      final app = AppState(settingsDirOverride: dir, modelsDirOverride: dir);
      final sm = SearchModel(app: app, modelsDir: () async => dir);
      addTearDown(sm.dispose);
      await tester.pumpWidget(wrap(SearchModelLine(searchModel: sm, model: 'other.gguf')));
      expect(find.text('Meaning search needs the model other.gguf.'), findsOneWidget);
      expect(find.text('Get it'), findsNothing);
    });

    testWidgets('the one-time question shows once', (tester) async {
      final app = AppState(settingsDirOverride: dir, modelsDirOverride: Directory('${dir.path}/models'));
      await tester.runAsync(() async {
        Directory('${dir.path}/models').createSync();
        File('${dir.path}/models/chat-Q4.gguf').writeAsBytesSync([1, 2]);
        await app.init();
      });
      final sm = SearchModel(app: app, modelsDir: () async => app.modelsDir!);
      addTearDown(sm.dispose);
      await tester.pumpWidget(wrap(const SizedBox()));
      final ctx = tester.element(find.byType(SizedBox));
      late Future<bool> shown;
      await tester.runAsync(() async {
        shown = offerSearchModelOnce(ctx, sm);
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpAndSettle();
      expect(find.text('Get the search model?'), findsOneWidget);
      expect(find.text('Meaning search in your libraries, places and the assistant needs it. 635 MB.'), findsOneWidget);
      await tester.tap(find.text('Not now'));
      await tester.pumpAndSettle();
      expect(await shown, isTrue);
      expect(app.searchModelOffered, isTrue);
      expect(await offerSearchModelOnce(ctx, sm), isFalse);
      await tester.pumpAndSettle();
      expect(find.text('Get the search model?'), findsNothing);
    });
  });
}

extension _Also<T> on T {
  void also(void Function(T) f) => f(this);
}
