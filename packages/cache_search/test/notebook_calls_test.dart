import 'package:cache_search/cache_search.dart';
import 'package:flutter_test/flutter_test.dart';

import 'engine_test.dart' show FakeNative;

/// The native seam with cs_notebook: answers from a canned string and records what was passed.
class NotebookFake extends FakeNative implements CsNotebookNative {
  bool has = true;
  String? reply;
  final List<String> nbCalls = [];

  @override
  bool get hasNotebook => has;

  @override
  String? notebook(int handle, String op, String? argsJson) {
    nbCalls.add('$handle:$op:$argsJson');
    return reply;
  }
}

void main() {
  test('an op goes to the core with its arguments as JSON and comes back parsed', () {
    final n = NotebookFake()..reply = '{"notebooks":[{"id":"a","def":{"name":"Generator test","fields":[]}}]}';
    final e = SearchEngine(n, 7);
    expect(e.notebook('notebooks', {})['notebooks'][0]['def']['name'], 'Generator test');
    expect(n.nbCalls.last, '7:notebooks:{}');
    e.notebook('entry', {'id': 'x'});
    expect(n.nbCalls.last, '7:entry:{"id":"x"}');
  });

  test('a refused op raises the core\'s error, and an older core says it has no Notebook', () {
    final n = NotebookFake()..error = '{"code":"not_found","message":"no entry with id \\"x\\""}';
    final e = SearchEngine(n, 7);
    expect(() => e.notebook('entry', {'id': 'x'}), throwsA(isA<CacheSearchException>().having((x) => x.code, 'code', 'not_found')));
    n.has = false;
    expect(() => e.notebook('notebooks', {}), throwsA(isA<CacheSearchException>().having((x) => x.code, 'code', 'unsupported')));
  });
}
