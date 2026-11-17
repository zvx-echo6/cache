import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../../../packages/cache_search/lib/src/core_dispatch.dart';
import '../../../packages/cache_search/lib/src/native_api.dart';
import '../bin/keystore.dart';
import '../bin/line_protocol.dart';
import 'fake_native.dart';

/// A fake core whose tool answers from the engine-wide location and web state, so a test sees which state a tool ran with.
class _StateNative extends FakeNative implements CsActNative {
  String location = 'none';
  String web = 'off';
  final List<String> toolArgs = [];
  final List<String> finishReplies = [];

  @override
  bool get hasAct => true;
  @override
  int conversationNew() => 5;
  @override
  int setLocation(int handle, double lat, double lon, double accuracyM, String fixedAt) {
    calls.add('setLocation:$lat:$lon:$accuracyM:$fixedAt');
    location = '$lat,$lon,$accuracyM,$fixedAt';
    return 0;
  }

  @override
  int clearLocation(int handle) {
    calls.add('clearLocation');
    location = 'none';
    return 0;
  }

  @override
  int setWeb(int handle, String? provider, String? key, bool online) {
    calls.add('setWeb:$provider:$key:$online');
    web = provider == null ? 'off' : '$provider:$online';
    return 0;
  }

  @override
  String? tool(int handle, int conv, String name, String argsJson, String now) {
    toolArgs.add(argsJson);
    return jsonEncode({'content': 'near=$location web=$web args=$argsJson', 'ids': []});
  }

  @override
  String? actFinish(int conv, String runId, String replyJson) {
    finishReplies.add(replyJson);
    return 'finish near=$location web=$web reply=$replyJson';
  }
}

void main() {
  late Directory tmp;
  late File file;
  late KeyStore keys;
  late _StateNative fake;
  late CoreDispatcher d;
  late List<String> logs;
  var id = 0;

  Future<Map<String, dynamic>> run(String op, Map<String, dynamic> args) async =>
      jsonDecode(await handleLine(jsonEncode({'id': ++id, 'op': op, 'args': args}), d, handlers: [keys], hook: keys, log: logs.add)) as Map<String, dynamic>;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('per_request_test');
    file = File('${tmp.path}/keystore.json');
    keys = KeyStore(file);
    keys.set('search.kagi.key', 'KAGI');
    fake = _StateNative()..replies['version'] = '{"core":"0.9.0","abi":3}';
    d = CoreDispatcher(() => fake);
    logs = [];
    await run('open', {'sources': []});
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  Future<String> tool(Map<String, dynamic> extra, {Map<String, dynamic> args = const {'q': 'coffee'}}) async {
    final r = await run('convTool', {'conv': 1, 'name': 'search', 'args': args, 'now': '2026-11-17T10:00:00-07:00', ...extra});
    expect(r['ok'], isTrue, reason: '$r');
    return (r['result'] as Map)['content'] as String;
  }

  Map<String, dynamic> loc(double lat, double lon) => {'lat': lat, 'lon': lon, 'accuracyM': 12.0, 'fixedAt': '2026-11-17T09:00:00-07:00'};

  Future<void> convNew() async {
    final r = await run('convNew', {});
    expect(r['result'], 1);
  }

  test('two tabs interleaved: each tool result reflects its own location', () async {
    await convNew();
    final a = loc(43.6, -116.2), b = loc(46.7, -117.0);
    expect(await tool({'location': a}), contains('near=43.6,-116.2,12.0,'));
    expect(await tool({'location': b}), contains('near=46.7,-117.0,12.0,'));
    expect(await tool({'location': a}), contains('near=43.6,-116.2,12.0,'));
    expect(await tool({'location': null}), contains('near=none'));
  });

  test('byte-identical: the per-request location equals a plain setLocation then a plain tool call', () async {
    await convNew();
    final viaField = await tool({'location': loc(43.6, -116.2)});
    await run('clearLocation', {});
    await run('setLocation', {'lat': 43.6, 'lon': -116.2, 'accuracy': 12.0, 'fixedAt': '2026-11-17T09:00:00-07:00'});
    final plain = await tool({});
    expect(viaField, plain);
  });

  test('the core sees exactly the tool args it saw before: location and web are stripped', () async {
    await convNew();
    await tool({'location': loc(1, 2), 'web': {'provider': 'kagi', 'reference': KeyStore.refOf('search.kagi.key'), 'online': true}}, args: {'q': 'coffee', 'n': 3});
    expect(fake.toolArgs.single, jsonEncode({'q': 'coffee', 'n': 3}));
    final r = await run('convActFinish', {'conv': 1, 'run_id': 'r1', 'reply': {'ok': true}, 'location': loc(1, 2), 'web': null});
    expect(r['ok'], isTrue, reason: '$r');
    expect(fake.finishReplies.single, jsonEncode({'ok': true}));
    expect(r['result'], contains('near=1.0,2.0'));
    expect(r['result'], contains('web=off'));
  });

  test('web: tab one with web on (key from the keystore), tab two with web null runs with web off; no raw key in args or logs', () async {
    await convNew();
    final on = {'provider': 'kagi', 'reference': KeyStore.refOf('search.kagi.key'), 'online': true};
    expect(await tool({'web': on}), contains('web=kagi:true'));
    expect(fake.calls, contains('setWeb:kagi:KAGI:true'));
    expect(await tool({'web': null}), contains('web=off'));
    expect(await tool({'web': on}), contains('web=kagi:true'));
    for (final a in fake.toolArgs) {
      expect(a, isNot(contains('KAGI')));
      expect(a, isNot(contains('reference')));
    }
    expect(logs.join('\n'), isNot(contains('KAGI')));
    // a tab's own setting is never what the server remembers and replays
    expect(file.readAsStringSync(), isNot(contains('"web"')));
  });

  test('a web reference the keystore does not have is an error, not a tool run', () async {
    await convNew();
    final r = await run('convTool', {'conv': 1, 'name': 'search', 'args': {}, 'now': 'x', 'web': {'provider': 'kagi', 'reference': KeyStore.refOf('nope'), 'online': true}});
    expect(r['ok'], isFalse);
    expect((r['error'] as Map)['code'], 'not_found');
    expect(fake.toolArgs, isEmpty);
  });

  test('old client: no fields means the engine-wide state is left alone and used', () async {
    await convNew();
    await run('setLocation', {'lat': 10.0, 'lon': 20.0, 'accuracy': 5.0, 'fixedAt': 'f'});
    await run('setWeb', {'provider': 'kagi', 'key': KeyStore.refOf('search.kagi.key'), 'online': true});
    fake.calls.clear();
    final out = await tool({});
    expect(out, contains('near=10.0,20.0,5.0,f'));
    expect(out, contains('web=kagi:true'));
    expect(fake.calls, isEmpty, reason: 'nothing was applied or cleared');
    expect(fake.toolArgs.single, jsonEncode({'q': 'coffee'}));
  });
}
