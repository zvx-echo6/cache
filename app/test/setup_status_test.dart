import 'dart:convert';

import 'package:cache/actions/action_registry.dart';
import 'package:cache/actions/setup_status.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/parity_fixtures.dart';

List<SetupItem> _items(Object? list) => [for (final i in list as List) SetupItem((i as Map)['label'] as String, i['value'] as String)];

DateTime _at(String checkedAt) => DateTime.parse(checkedAt.replaceFirst(' ', 'T'));

SetupDeps _deps(Map<String, List<SetupItem>> by, [List<String>? read]) {
  Future<List<SetupItem>> Function() part(String id) => () async {
        read?.add(id);
        return by[id] ?? const [];
      };
  return SetupDeps(
    connection: part('connection'),
    regions: part('regions'),
    libraries: part('libraries'),
    liveData: part('live_data'),
    webSearch: part('web_search'),
    places: part('places'),
    models: part('models'),
    location: part('location'),
  );
}

void main() {
  test('the definition is the trained one, byte for byte', () {
    expect('${jsonEncode(kSetupStatusDefinition)}\n', parityText('app-setup-status-definition.json'));
    expect((kSetupStatusDefinition['description'] as String).length, 115);
    final reg = ActionRegistry()..publish('app', [kSetupStatusDefinition], {'app.setup_status': (_) async => {}});
    expect(reg.rejected, isEmpty);
  });

  for (final row in ['act-048', 'act-116']) {
    test('the host reply matches the captures ($row)', () async {
      final fixture = parityJson('setup-status-$row.json') as Map<String, dynamic>;
      final calls = fixture['calls'] as List;
      expect(calls, isNotEmpty);
      for (final c in calls) {
        final args = jsonDecode(((c as Map)['tool_call'] as Map)['function']['arguments'] as String) as Map;
        final area = (args['fields'] as Map?)?['area'] as String?;
        // The regenerated fixtures carry the host reply itself (area-filtered, addresses kept). The first ones only have what
        // the model saw, which the core numbered ("address" became "n") and which had every part whatever the area: the parts
        // are put back by their order.
        final Map<String, dynamic> expected;
        String? asked = area;
        if (c['host_reply'] != null) {
          expected = (c['host_reply'] as Map).cast<String, dynamic>();
        } else {
          final seen = (jsonDecode(c['tool_message'] as String) as Map)['result'] as Map;
          final sections = seen['sections'] as List;
          expect(sections, hasLength(kSetupAreas.length));
          expected = {
            'checked_at': seen['checked_at'],
            'sections': [
              for (var i = 0; i < sections.length; i++)
                {
                  'address': 'app:setup/${kSetupAreas[i].id}',
                  for (final e in (sections[i] as Map).entries)
                    if (e.key != 'n') e.key as String: e.value,
                },
            ],
          };
          asked = null;
        }
        final by = {
          for (final s in expected['sections'] as List) ((s as Map)['address'] as String).split('/').last: _items(s['items']),
        };
        final reply = await runSetupStatus(_deps(by), {'area': ?asked}, now: () => _at(expected['checked_at'] as String));
        expect(jsonEncode(reply), jsonEncode(expected));
      }
    });
  }

  test('an area gives only that part, and only that part is read; no area gives every part in order', () async {
    final read = <String>[];
    final deps = _deps({
      'web_search': [const SetupItem('Kagi key', 'not set')],
    }, read);
    final one = await runSetupStatus(deps, {'area': 'web_search'}, now: () => DateTime(2026, 10, 29, 14, 30));
    expect(read, ['web_search']);
    expect(jsonEncode(one),
        '{"checked_at":"2026-10-29 14:30","sections":[{"address":"app:setup/web_search","title":"Web search","items":[{"label":"Kagi key","value":"not set"}],"guide":"Cache guide: 3. Settings, page by page: Web search with Kagi"}]}');
    read.clear();
    final all = await runSetupStatus(deps, {}, now: () => DateTime(2026, 10, 29, 14, 30));
    expect(read, [for (final a in kSetupAreas) a.id]);
    expect([for (final s in all['sections'] as List) (s as Map)['address']], [for (final a in kSetupAreas) 'app:setup/${a.id}']);
  });

  test('parts, titles and guide pointers are the spec\'s', () {
    expect([for (final a in kSetupAreas) (a.id, a.title, a.guide)], [
      ('connection', 'Connection', 'Cache guide: 3. Settings, page by page: Mobile data'),
      ('regions', 'Regions', 'Cache guide: 1. Getting started: Download a region'),
      ('libraries', 'Libraries', 'Cache guide: 3. Settings, page by page: Libraries page'),
      ('live_data', 'Live data', 'Cache guide: 3. Settings, page by page: Weather and alerts'),
      ('web_search', 'Web search', 'Cache guide: 3. Settings, page by page: Web search with Kagi'),
      ('places', 'Place details', 'Cache guide: 2. Using Cache: The place card and saving a place'),
      ('models', 'Models', 'Cache guide: 1. Getting started: Choose a model'),
      ('location', 'Location', 'Cache guide: 3. Settings, page by page: Notifications and location'),
    ]);
    expect((kSetupStatusDefinition['fields'] as Map)['area']['enum'], [for (final a in kSetupAreas) a.id]);
  });

  test('a part with nothing to report says so in one item', () async {
    final r = await runSetupStatus(_deps({}), {'area': 'regions'}, now: () => DateTime(2026, 10, 29, 14, 30));
    expect(((r['sections'] as List).single as Map)['items'], [{'label': 'Regions', 'value': 'none installed'}]);
    final live = await runSetupStatus(_deps({}), {'area': 'live_data'}, now: () => DateTime(2026, 10, 29, 14, 30));
    expect(((live['sections'] as List).single as Map)['items'], [{'label': 'Live data', 'value': 'no sources installed'}]);
  });

  test('a part that fails to read says it has nothing, the rest still answer', () async {
    final deps = SetupDeps(
      connection: () async => throw StateError('no probe'),
      regions: () async => const [],
      libraries: () async => const [],
      liveData: () async => const [],
      webSearch: () async => [const SetupItem('Kagi key', 'set')],
      places: () async => const [],
      models: () async => const [],
      location: () async => const [],
    );
    final r = await runSetupStatus(deps, {}, now: () => DateTime(2026, 10, 29, 14, 30));
    expect(((r['sections'] as List).first as Map)['items'], [{'label': 'Connection', 'value': 'not known'}]);
    expect(((r['sections'] as List)[4] as Map)['items'], [{'label': 'Kagi key', 'value': 'set'}]);
  });

  test('values are plain screen words', () {
    expect(liveSourceValue(on: false, age: '2 hours old'), 'off');
    expect(liveSourceValue(on: true), 'on, never downloaded');
    expect(liveSourceValue(on: true, age: '2 hours old'), 'on, updated 2 hours ago');
    expect(liveSourceValue(on: true, age: '40 minutes old'), 'on, updated 40 minutes ago');
    expect(setupAge(const Duration(seconds: 30)), 'less than a minute old');
    expect(setupAge(const Duration(minutes: 1)), '1 minute old');
    expect(setupAge(const Duration(hours: 3, minutes: 59)), '3 hours old');
    expect(setupAge(const Duration(days: 21)), '21 days old');
    expect(setupCheckedAt(DateTime(2026, 10, 29, 9, 5)), '2026-10-29 09:05');
  });
}
