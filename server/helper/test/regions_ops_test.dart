import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:test/test.dart';

import '../../../packages/cache_search/lib/src/core_dispatch.dart';
import '../../../packages/cache_search/lib/src/errors.dart';
import '../bin/core_open.dart';
import '../bin/offroad_packs.dart';
import '../bin/regions_ops.dart';
import 'fake_native.dart';

class FakeRegions implements RegionsEngine {
  final List<String> calls = [];
  final Map<String, String> answers = {};

  @override
  String? call(String method, String argsJson) {
    calls.add('$method:$argsJson');
    return answers[method] ?? '{"ok":true}';
  }
}

String codeOf(void Function() f) {
  try {
    f();
  } on CacheSearchException catch (e) {
    return e.code;
  }
  return 'none';
}

Future<void> until(bool Function() ok) async {
  for (var i = 0; i < 200 && !ok(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
}

void main() {
  late Directory tmp;
  late Directory support;
  late FakeRegions engine;
  late RegionsOps ops;
  late HttpServer server;
  late List<int> body;
  var requests = 0;
  String? lastRange;
  late Future<void> Function(HttpRequest) serve;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('regions_ops_test');
    support = Directory('${tmp.path}/support')..createSync();
    engine = FakeRegions();
    body = List<int>.generate(5000, (i) => i % 251);
    requests = 0;
    lastRange = null;
    server = await HttpServer.bind('127.0.0.1', 0);
    serve = (req) async {
      requests++;
      lastRange = req.headers.value(HttpHeaders.rangeHeader);
      req.response.statusCode = 200;
      req.response.add(body);
      await req.response.close();
    };
    server.listen((req) => serve(req));
    ops = RegionsOps(
      support,
      config: {'dir': '${support.path}/regions'},
      open: (c) => engine,
      packs: OffroadPacks(Directory('${support.path}/regions/offroad'), allowed: (u) => u.host == '127.0.0.1'),
    );
  });

  tearDown(() async {
    await server.close(force: true);
    tmp.deleteSync(recursive: true);
  });

  Map<String, dynamic> pack({String path = 'na-1/US-ID/offroad.sqlite', String? sha, int? bytes}) => {
        'path': path,
        'url': 'http://127.0.0.1:${server.port}/p',
        'bytes': bytes ?? body.length,
        'sha256': sha ?? sha256.convert(body).toString(),
      };

  test('handles only regions.* ops', () {
    expect(ops.handles('regions.call'), isTrue);
    expect(ops.handles('fs.read'), isFalse);
  });

  test('engine methods go to the engine and its answer comes back', () {
    engine.answers['status'] = '{"build":"na-1","regions":[]}';
    final r = ops.handle('regions.call', {'method': 'status', 'args': {}}) as Map;
    expect(r['build'], 'na-1');
    expect(engine.calls, ['status:{}']);
  });

  test('an engine error is raised with its code and message', () {
    engine.answers['plan'] = '{"error":"no index","code":"offline"}';
    try {
      ops.handle('regions.call', {'method': 'plan', 'args': {'id': 'x'}});
      fail('should throw');
    } on CacheSearchException catch (e) {
      expect(e.code, 'offline');
      expect(e.message, 'no index');
    }
  });

  test('an unknown method is refused and never reaches the engine', () {
    expect(codeOf(() => ops.handle('regions.call', {'method': 'rm_rf', 'args': {}})), 'bad_method');
    expect(engine.calls, isEmpty);
  });

  test('a pack downloads into place, checked against its SHA-256', () async {
    final r = ops.handle('regions.call', {'method': 'offroad_fetch', 'args': pack()}) as Map;
    expect(r['state'], 'running');
    final file = File('${support.path}/regions/offroad/na-1/US-ID/offroad.sqlite');
    await until(file.existsSync);
    expect(file.readAsBytesSync(), body);
    expect(File('${file.parent.path}/.offroad.sqlite.part').existsSync(), isFalse);
    final st = ops.handle('regions.call', {
      'method': 'offroad_status',
      'args': {'paths': ['na-1/US-ID/offroad.sqlite']},
    }) as Map;
    expect((st['packs'] as Map)['na-1/US-ID/offroad.sqlite']['on_disk'], isTrue);
  });

  test('a pack that does not match its SHA-256 is thrown away and reported', () async {
    ops.handle('regions.call', {'method': 'offroad_fetch', 'args': pack(sha: 'ab' * 32)});
    const path = 'na-1/US-ID/offroad.sqlite';
    Map<String, dynamic> st() =>
        ((ops.handle('regions.call', {'method': 'offroad_status', 'args': {'paths': [path]}}) as Map)['packs'] as Map)[path] as Map<String, dynamic>;
    await until(() => st()['error'] != null);
    expect(st()['error'], isNotNull);
    expect(st()['on_disk'], isFalse);
    expect(File('${support.path}/regions/offroad/na-1/US-ID/.offroad.sqlite.part').existsSync(), isFalse);
  });

  test('a part left by an earlier try is continued with a range request', () async {
    final dir = Directory('${support.path}/regions/offroad/na-1/US-ID')..createSync(recursive: true);
    File('${dir.path}/.offroad.sqlite.part').writeAsBytesSync(body.sublist(0, 1000));
    serve = (req) async {
      lastRange = req.headers.value(HttpHeaders.rangeHeader);
      req.response.statusCode = 206;
      req.response.add(body.sublist(1000));
      await req.response.close();
    };
    ops.handle('regions.call', {'method': 'offroad_fetch', 'args': pack()});
    final file = File('${dir.path}/offroad.sqlite');
    await until(file.existsSync);
    expect(lastRange, 'bytes=1000-');
    expect(file.readAsBytesSync(), body);
  });

  test('Pause stops the downloads and nothing starts until it is lifted', () async {
    ops.handle('regions.call', {'method': 'set_policy', 'args': {'hold': true}});
    final r = ops.handle('regions.call', {'method': 'offroad_fetch', 'args': pack()}) as Map;
    expect(r['state'], 'held');
    expect(requests, 0);
    ops.handle('regions.call', {'method': 'set_policy', 'args': {'hold': false}});
    expect((ops.handle('regions.call', {'method': 'offroad_fetch', 'args': pack()}) as Map)['state'], 'running');
    await until(() => File('${support.path}/regions/offroad/na-1/US-ID/offroad.sqlite').existsSync());
  });

  test('a pack path outside <build>/<id>/offroad.sqlite and an address off the allow-list are refused', () {
    expect(codeOf(() => ops.handle('regions.call', {'method': 'offroad_fetch', 'args': pack(path: '../x/offroad.sqlite')})), 'bad_path');
    expect(codeOf(() => ops.handle('regions.call', {'method': 'offroad_fetch', 'args': pack(path: 'a/b/other.sqlite')})), 'bad_path');
    expect(codeOf(() => ops.handle('regions.call', {'method': 'offroad_remove', 'args': {'path': '/etc/passwd'}})), 'bad_path');
    final guarded = RegionsOps(support, config: const {}, open: (c) => engine);
    expect(codeOf(() => guarded.handle('regions.call', {'method': 'offroad_fetch', 'args': pack()})), 'bad_url');
    expect(kPackHosts, contains('data.cached.info'));
  });

  test('offroad_remove deletes the pack and its part', () {
    final dir = Directory('${support.path}/regions/offroad/na-1/US-ID')..createSync(recursive: true);
    File('${dir.path}/offroad.sqlite').writeAsStringSync('x');
    File('${dir.path}/.offroad.sqlite.part').writeAsStringSync('y');
    ops.handle('regions.call', {'method': 'offroad_remove', 'args': {'path': 'na-1/US-ID/offroad.sqlite'}});
    expect(dir.listSync(), isEmpty);
  });

  test('afterOpen gives the engine the Pause from regions-app.json and carries on the packs still missing', () async {
    File('${support.path}/regions-app.json').writeAsStringSync(jsonEncode({
      'regions': {
        'US-ID': {'offroad': [pack()]},
      },
    }));
    ops.afterOpen();
    expect(engine.calls.first, contains('"hold":false'));
    await until(() => File('${support.path}/regions/offroad/na-1/US-ID/offroad.sqlite').existsSync());
    expect(File('${support.path}/regions/offroad/na-1/US-ID/offroad.sqlite').existsSync(), isTrue);
  });

  test('afterOpen with the downloads held sets the engine on hold and fetches nothing', () async {
    File('${support.path}/regions-app.json').writeAsStringSync(jsonEncode({
      'held': true,
      'regions': {
        'US-ID': {'offroad': [pack()]},
      },
    }));
    ops.afterOpen();
    expect(engine.calls.first, contains('"hold":true'));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(requests, 0);
  });

  test('OpenOp calls onOpened after the core is open', () {
    final fake = FakeNative();
    final d = CoreDispatcher(() => fake);
    var called = false;
    final dirs = AppDirs(support, Directory('${tmp.path}/docs')..createSync());
    OpenOp(dirs, d, onOpened: () => called = true).handle('open', {'sources': []});
    expect(called, isTrue);
  });
}
