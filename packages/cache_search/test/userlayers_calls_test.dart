import 'package:cache_search/cache_search.dart';
import 'package:flutter_test/flutter_test.dart';

import 'engine_test.dart' show FakeNative;

/// The native seam with the user-layer calls: answers from a canned string and records what was passed.
class UserLayersFake extends FakeNative implements CsUserLayersNative {
  bool has = true;
  String? reply;
  final List<String> ulCalls = [];

  @override
  bool get hasUserLayers => has;

  @override
  String? userLayers(int handle, String call, String? arg) {
    ulCalls.add('$handle:$call:$arg');
    return reply;
  }
}

void main() {
  test('each call goes to the core with its argument and comes back parsed', () {
    final n = UserLayersFake()..reply = '{"layers":[{"id":"y1","name":"Rally Points"}],"repeater_lists":[]}';
    final e = SearchEngine(n, 7);
    expect(e.userLayers('list')['layers'][0]['id'], 'y1');
    expect(n.ulCalls.last, '7:list:null');
    n.reply = '{"id":"l2","kind":"repeaters"}';
    expect(e.userLayers('import', '{"kind":"repeaters","paths":["/a.csv"]}')['id'], 'l2');
    expect(n.ulCalls.last, '7:import:{"kind":"repeaters","paths":["/a.csv"]}');
    e.userLayers('delete', 'l2');
    expect(n.ulCalls.last, '7:delete:l2');
  });

  test('a refused call raises the core\'s error; an unknown call and an older core are refused', () {
    final n = UserLayersFake()..error = '{"code":"not_found","message":"no map layer or repeater list with id \\"y9\\""}';
    final e = SearchEngine(n, 7);
    expect(() => e.userLayers('get', 'y9'), throwsA(isA<CacheSearchException>().having((x) => x.code, 'code', 'not_found')));
    expect(() => e.userLayers('frob'), throwsA(isA<CacheSearchException>().having((x) => x.code, 'code', 'bad_json')));
    n.has = false;
    expect(() => e.userLayers('list'), throwsA(isA<CacheSearchException>().having((x) => x.code, 'code', 'unsupported')));
  });
}
