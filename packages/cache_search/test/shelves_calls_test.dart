import 'dart:convert';

import 'package:cache_search/cache_search.dart';
import 'package:flutter_test/flutter_test.dart';

import 'engine_test.dart' show FakeNative;

/// The native seam with the Bookshelves calls: answers from canned strings by op and records what was passed.
class ShelvesFake extends FakeNative implements CsShelvesNative {
  bool has = true;
  final Map<String, String?> shelvesReplies = {};
  final List<String> shelvesCalls = [];

  @override
  bool get hasShelves => has;

  @override
  String? shelves(String op, String argsJson) {
    shelvesCalls.add('$op:$argsJson');
    return shelvesReplies[op];
  }
}

// Runs inside the worker isolate, so it builds its own fake.
CsNative _worker() => ShelvesFake()
  ..shelvesReplies['detect'] = '[{"with":"B","how":"blake3","score":1.0}]'
  ..shelvesReplies['append'] = '{"written":2,"last_at":7}'
  ..shelvesReplies['resolve'] = '{"format":1,"books":{}}'
  ..shelvesReplies['import'] = '{"events":0,"files":[]}';

void main() {
  test('each Bookshelves call goes to its cs_shelves_ function with its JSON, and needs no open handle', () {
    final n = ShelvesFake()
      ..shelvesReplies['detect'] = '[{"with":"B","how":"text","score":0.9}]'
      ..shelvesReplies['append'] = '{"written":1,"last_at":5}';
    final matches = SearchEngine.shelvesCall(n, 'detect', {'copy': {'copy': 'A'}, 'against': []}) as List;
    expect((matches.single as Map)['with'], 'B');
    expect(n.shelvesCalls.single, 'detect:${jsonEncode({'copy': {'copy': 'A'}, 'against': []})}');
    final e = SearchEngine(n, 0);
    expect((e.shelves('append', {'dir': '/b', 'dev': 'd', 'events': []}) as Map)['written'], 1, reason: 'handle 0: nothing is opened');
  });

  test('a refused call raises the core\'s error; an unknown call and an older core are refused', () {
    final n = ShelvesFake()..error = '{"code":"bad_json","message":"\\"dir\\" is missing"}';
    expect(() => SearchEngine.shelvesCall(n, 'resolve', {}), throwsA(isA<CacheSearchException>().having((x) => x.code, 'code', 'bad_json')));
    expect(() => SearchEngine.shelvesCall(n, 'frob', {}), throwsA(isA<CacheSearchException>().having((x) => x.code, 'code', 'bad_json')));
    n.has = false;
    expect(() => SearchEngine.shelvesCall(n, 'resolve', {}), throwsA(isA<CacheSearchException>().having((x) => x.code, 'code', 'unsupported')));
  });

  test('the worker isolate runs the four calls and types their answers', () async {
    final core = await SearchCore.open(const [], native: _worker);
    expect((await core.shelvesDetect({'copy': {'copy': 'A'}, 'against': []})).single['how'], 'blake3');
    expect((await core.shelvesAppend({'dir': '/b', 'dev': 'd', 'events': []}))['last_at'], 7);
    expect((await core.shelvesResolve({'dir': '/b', 'libraries': []}))['format'], 1);
    expect((await core.shelvesImport({'dir': '/b', 'dev': 'd', 'libraries': []}))['files'], isEmpty);
    await core.close();
  });
}
