import 'dart:convert';

import 'package:cache_search/cache_search.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// The browser's core over HTTP: every POST to /api/core is recorded as {op, args}.
class _Web {
  final List<Map<String, dynamic>> posts = [];

  late final HttpTransport transport = HttpTransport(
    client: MockClient((r) async {
      final body = jsonDecode(r.body) as Map<String, dynamic>;
      posts.add(body);
      final Object? result = switch (body['op']) {
        'convNew' => 1,
        'convTool' => {'content': 'ok', 'ids': <Object>[]},
        'convActFinish' => 'done',
        _ => null,
      };
      return http.Response(jsonEncode({'ok': true, 'result': result}), 200, headers: {'content-type': 'application/json'});
    }),
    endpoint: Uri.parse('https://cache.test/api/core'),
  );

  Map<String, dynamic> last(String op) => (posts.lastWhere((p) => p['op'] == op)['args'] as Map).cast<String, dynamic>();
}

Future<(SearchCore, CoreConversation, _Web)> _open({RequestContext Function()? context}) async {
  final web = _Web();
  final core = await SearchCore.open(const [], transport: web.transport);
  if (context != null) core.requestContext = context;
  return (core, await core.newConversation(), web);
}

const _fix = {'lat': 43.6, 'lon': -116.2, 'accuracyM': 12.5, 'fixedAt': '2026-11-17T09:00:00-07:00'};
const _on = {'provider': 'kagi', 'reference': 'keystore://search.kagi.key', 'online': true};

void main() {
  test('1. a web convTool call carries this tab\'s location, or null with no position', () async {
    Map<String, dynamic>? here = _fix;
    final (core, conv, web) = await _open(context: () => (location: here, web: null));
    await conv.tool('search', {'query': 'x'}, now: '2026-11-17T09:00:00-07:00');
    expect(web.last('convTool')['location'], _fix);
    here = null;
    await conv.tool('search', {'query': 'x'}, now: '2026-11-17T09:00:00-07:00');
    final args = web.last('convTool');
    expect(args.containsKey('location'), isTrue, reason: 'null, not absent: absent means an old client');
    expect(args['location'], isNull);
    expect(args['args'], {'query': 'x'}, reason: 'the tool\'s own args are not touched');
    await core.close();
  });

  test('2. web carries provider, reference and online when on, null when off, and never a key', () async {
    Map<String, dynamic>? w = _on;
    final (core, conv, web) = await _open(context: () => (location: null, web: w));
    await conv.tool('web_search', {'query': 'x'}, now: 'n');
    expect(web.last('convTool')['web'], _on);
    expect((web.last('convTool')['web'] as Map).keys.toSet(), {'provider', 'reference', 'online'});
    expect(jsonEncode(web.last('convTool')), isNot(contains('"key"')));
    w = null;
    await conv.tool('web_search', {'query': 'x'}, now: 'n');
    expect(web.last('convTool').containsKey('web'), isTrue);
    expect(web.last('convTool')['web'], isNull);
    await core.close();
  });

  test('3. convActFinish carries both the same way', () async {
    Map<String, dynamic>? here = _fix;
    Map<String, dynamic>? w = _on;
    final (core, conv, web) = await _open(context: () => (location: here, web: w));
    await conv.actFinish('run1', {'ok': true});
    var a = web.last('convActFinish');
    expect(a['location'], _fix);
    expect(a['web'], _on);
    expect(a['run_id'], 'run1');
    here = null;
    w = null;
    await conv.actFinish('run2', {'ok': true});
    a = web.last('convActFinish');
    expect(a.containsKey('location'), isTrue);
    expect(a['location'], isNull);
    expect(a.containsKey('web'), isTrue);
    expect(a['web'], isNull);
    await core.close();
  });

  test('4. with no context set (the phone and the desktop app) the args are unchanged', () async {
    final (core, conv, web) = await _open();
    await conv.tool('search', {'query': 'x'}, now: 'n');
    expect(web.last('convTool'), {'conv': 1, 'name': 'search', 'args': {'query': 'x'}, 'now': 'n'});
    await conv.actFinish('r', {'ok': true});
    expect(web.last('convActFinish'), {'conv': 1, 'run_id': 'r', 'reply': {'ok': true}});
    await core.close();
  });

  test('5. a key check (perRequest false) leaves both fields off, so the engine-wide setWeb it lent still applies', () async {
    final (core, conv, web) = await _open(context: () => (location: _fix, web: null));
    await conv.tool('web_search', {'query': 'Cache'}, now: 'n', perRequest: false);
    expect(web.last('convTool'), {'conv': 1, 'name': 'web_search', 'args': {'query': 'Cache'}, 'now': 'n'});
    await core.close();
  });
}
