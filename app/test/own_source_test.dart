import 'dart:convert';
import 'dart:io';

import 'package:cache/weather/own_source.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// The definition the core's own test runs (packages/cache_search/native/cache_live/tests/own_source.rs): what the form saves for
/// the creek gauge below must be exactly it, so the core's check and run of that file are the check and run of what the app saves.
const String _fixtures = '../packages/cache_search/native/cache_live/tests/fixtures';

const _key = 'SECRET-KEY-123';

const _creek = OwnDraft(
  name: 'Creek level at the bridge',
  address: 'https://sensors.example.org/api/creek?site=12&lat={lat}&lon={lon}&key=$_key',
  key: _key,
  refreshMinutes: 30,
);

/// A server on this machine that answers each path as [answer] says.
Future<HttpServer> _serve(Future<void> Function(HttpRequest r) answer) async {
  final s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  s.listen((r) async {
    try {
      await answer(r);
    } catch (_) {}
  });
  return s;
}

void main() {
  group('the form', () {
    test('says what is missing or wrong, one thing at a time', () {
      expect(const OwnDraft().problem(), 'Give the source a name.');
      expect(const OwnDraft(name: 'A').problem(), 'Enter the web address of the service.');
      expect(const OwnDraft(name: 'A', address: 'http://example.org/x').problem(), 'Enter an address that starts with https://');
      expect(const OwnDraft(name: 'A', address: 'example.org/x').problem(), 'Enter an address that starts with https://');
      expect(const OwnDraft(name: 'A', address: 'https://example.org/x?q={city}').problem(), contains("doesn't fill in"));
      expect(const OwnDraft(name: 'A', address: 'https://example.org/x?q={lat').problem(), contains("doesn't fill in"));
      expect(const OwnDraft(name: 'A', address: 'https://example.org/x', key: 'abc').problem(), 'Put your key in the web address where the service asks for it.');
      expect(const OwnDraft(name: 'A', address: 'https://example.org/x?k={api_key}').problem(), 'This address needs your key. Type it under Key.');
      expect(const OwnDraft(name: 'A', address: 'https://example.org/x?k={api_key}', savedKey: true).problem(), isNull, reason: 'editing: the key kept is used');
      expect(const OwnDraft(name: 'A', address: 'https://example.org/x?lat={lat}&lon={lon:2}').problem(), isNull);
      expect(const OwnDraft(name: 'A', address: 'http://127.0.0.1:8080/x').problem(), isNull, reason: 'this phone, for testing');
      expect(_creek.problem(), isNull);
    });

    test('the key typed into the address is kept as {api_key}, never as itself', () {
      expect(_creek.keptAddress, 'https://sensors.example.org/api/creek?site=12&lat={lat}&lon={lon}&key={api_key}');
      expect(_creek.needsKey, isTrue);
      expect(_creek.usesPlace, isTrue);
      expect(const OwnDraft(address: 'https://x.example.org/a').usesPlace, isFalse);
    });

    test('Latitude and Longitude go in where the cursor is, over a selection, or at the end', () {
      final at = insertPlaceholder(const TextEditingValue(text: 'https://x/?lat=&n=1', selection: TextSelection.collapsed(offset: 15)), kLatPlaceholder);
      expect(at.text, 'https://x/?lat={lat}&n=1');
      expect(at.selection, const TextSelection.collapsed(offset: 20));
      final over = insertPlaceholder(const TextEditingValue(text: 'https://x/?lon=99', selection: TextSelection(baseOffset: 15, extentOffset: 17)), kLonPlaceholder);
      expect(over.text, 'https://x/?lon={lon}');
      final end = insertPlaceholder(const TextEditingValue(text: 'https://x/?lat='), kLatPlaceholder);
      expect(end.text, 'https://x/?lat={lat}');
      expect(end.selection.baseOffset, end.text.length);
    });

    test('the place and the key are filled in as the core fills them', () {
      expect(fillAddress('https://x/?a={lat}&b={lon}&c={lat:2}&k={api_key}', lat: 42.5361, lon: -113.79, key: 'a b'), 'https://x/?a=42.5361&b=-113.7900&c=42.54&k=a%20b');
    });

    test('the choices of Check every', () {
      expect([for (final m in kOwnRefreshChoices) ownRefreshWords(m)], ['15 minutes', '30 minutes', '1 hour', '6 hours']);
    });
  });

  group('the values of an answer', () {
    test('every value, by the path the definition reads, named from its key; a list gives its first element', () {
      final v = flattenJson(jsonDecode(File('$_fixtures/own_source_response.json').readAsStringSync()));
      expect([for (final x in v) x.path], [
        'station.id',
        'station.name',
        'station.latitude',
        'station.longitude',
        'water.level',
        'water.unit',
        'water.trend',
        'updated',
        'battery',
        'readings[0].t',
        'readings[0].v',
      ]);
      expect(v.firstWhere((x) => x.path == 'water.level').label, 'Level');
      expect(v.firstWhere((x) => x.path == 'water.level').value, '1.42');
      expect(v.firstWhere((x) => x.path == 'battery').value, '87');
      expect(findPoint(v), (lat: 'station.latitude', lon: 'station.longitude'));
    });

    test('a list at the root, nulls and keys a path cannot name are left out', () {
      final v = flattenJson([
        {'time_tag': '2026-11-07', 'flux': 151.0, 'gone': null, 'a.b': 1, '@x': 2, 'ok': true},
      ]);
      expect([for (final x in v) (x.path, x.label, x.value)], [('[0].time_tag', 'Time tag', '2026-11-07'), ('[0].flux', 'Flux', '151'), ('[0].ok', 'Ok', 'true')]);
      expect(flattenJson(3.5).single.path, '^');
      expect(flattenJson({}), isEmpty);
    });

    test('names from keys', () {
      expect(labelFromKey('waterLevel'), 'Water level');
      expect(labelFromKey('water_level'), 'Water level');
      expect(labelFromKey('gage-height'), 'Gage height');
      expect(labelFromKey('pm25_AQI'), 'Pm25 AQI');
      expect(labelFromKey(''), 'Value');
    });
  });

  group('Try it, against a server on this machine', () {
    late HttpServer server;
    late String base;

    setUp(() async {
      server = await _serve((r) async {
        switch (r.uri.path) {
          case '/ok':
            r.response.headers.contentType = ContentType.json;
            r.response.write('{"water": {"level": 1.42}, "lat": "${r.uri.queryParameters['lat']}"}');
          case '/down':
            r.response.statusCode = 503;
          case '/page':
            r.response.write('<html><body>Hello</body></html>');
          case '/slow':
            await Future<void>.delayed(const Duration(seconds: 3));
            r.response.write('{}');
          case '/empty':
            r.response.write('{"a": null, "b": []}');
        }
        await r.response.close();
      });
      base = 'http://127.0.0.1:${server.port}';
    });

    tearDown(() => server.close(force: true));

    test('ok: the values of the answer, for the place asked', () async {
      final t = await tryOwnAddress(Uri.parse(fillAddress('$base/ok?lat={lat}', lat: 42.5, lon: 1)));
      expect(t.ok, isTrue);
      expect(t.words, 'It answered. Here is what came back.');
      expect([for (final v in t.values) (v.path, v.value)], [('water.level', '1.42'), ('lat', '42.5000')]);
    });

    test('an HTTP error, an answer that is not JSON, one with no values, and one that does not come in time', () async {
      final down = await tryOwnAddress(Uri.parse('$base/down'));
      expect(down.failure, OwnTryFailure.status);
      expect(down.words, '127.0.0.1 answered with an error (HTTP 503).');
      final page = await tryOwnAddress(Uri.parse('$base/page'));
      expect(page.failure, OwnTryFailure.notJson);
      expect(page.words, contains('not with JSON'));
      final empty = await tryOwnAddress(Uri.parse('$base/empty'));
      expect(empty.failure, OwnTryFailure.empty);
      final slow = await tryOwnAddress(Uri.parse('$base/slow'), timeout: const Duration(milliseconds: 300));
      expect(slow.failure, OwnTryFailure.timedOut);
      expect(slow.words, "127.0.0.1 didn't answer in time.");
    });

    test('nothing listening: it could not be reached', () async {
      final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = s.port;
      await s.close();
      final t = await tryOwnAddress(Uri.parse('http://127.0.0.1:$port/x'));
      expect(t.failure, OwnTryFailure.unreachable);
    });
  });

  group('the definition it saves', () {
    final values = flattenJson(jsonDecode(File('$_fixtures/own_source_response.json').readAsStringSync()));
    const picks = [OwnPick('water.level', 'Water level'), OwnPick('water.trend', 'Trend'), OwnPick('updated', 'Updated')];
    String build() => buildOwnDefinition(id: ownIdFor(_creek.name, {}), draft: _creek, picks: picks, point: findPoint(values));

    test('is the definition the core checks and runs in its own test (the shared fixture)', () {
      expect(jsonDecode(build()), jsonDecode(File('$_fixtures/own_source_def.json').readAsStringSync()));
    });

    test('the key never appears in it; it is referenced by the alias, as published keyed sources do', () {
      final text = build();
      expect(text, isNot(contains(_key)));
      final def = jsonDecode(text) as Map<String, dynamic>;
      expect(def['api_key'], {'alias': 'own-creek-level-at-the-bridge', 'required': true});
      expect((def['request'] as Map)['url'], contains('{api_key}'));
    });

    test('without a key in the address there is no api_key; Check every sets how often and how long it is good', () {
      const d = OwnDraft(name: 'Flux', address: 'https://x.example.org/f', refreshMinutes: 360);
      final def = jsonDecode(buildOwnDefinition(id: 'own-flux', draft: d, picks: const [OwnPick('[0].flux', 'Flux')])) as Map<String, dynamic>;
      expect(def.containsKey('api_key'), isFalse);
      expect(def['refresh_minutes'], 360);
      expect(def['validity'], {'fixed_hours': 18.0});
      expect(((def['items'] as List).single as Map).containsKey('point'), isFalse);
      final q = jsonDecode(buildOwnDefinition(id: 'own-q', draft: d.copyWithMinutes(15), picks: const [OwnPick('a', 'A')])) as Map<String, dynamic>;
      expect(q['validity'], {'fixed_hours': 1.0});
    });

    test('names are made unique and braces taken out; ids are unique', () {
      expect([for (final p in tidyPicks(const [OwnPick('a', 'Level'), OwnPick('b', 'level'), OwnPick('c', '{x}')])) p.label], ['Level', 'level 2', 'x']);
      expect(ownIdFor('Creek level!', {}), 'own-creek-level');
      expect(ownIdFor('Creek level', {'own-creek-level'}), 'own-creek-level-2');
      expect(ownIdFor('???', {}), 'own-source');
    });

    test('is read back to edit: the form and the ticked values, in order; another definition is not', () {
      final back = readOwnDefinition(jsonDecode(build()) as Map<String, dynamic>)!;
      expect(back.draft.name, 'Creek level at the bridge');
      expect(back.draft.address, _creek.keptAddress);
      expect(back.draft.refreshMinutes, 30);
      expect(back.draft.needsKey, isTrue);
      expect([for (final p in back.picks) (p.path, p.label)], [('water.level', 'Water level'), ('water.trend', 'Trend'), ('updated', 'Updated')]);
      expect(readOwnDefinition({'id': 'swpc-kp', 'items': []}), isNull);
    });
  });
}

extension on OwnDraft {
  OwnDraft copyWithMinutes(int m) => OwnDraft(name: name, address: address, key: key, refreshMinutes: m, id: id, savedKey: savedKey);
}
