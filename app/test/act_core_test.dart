import 'dart:convert';

import 'package:cache/actions/act_core.dart';
import 'package:cache/actions/action_registry.dart';
import 'package:cache/actions/app_actions.dart';
import 'package:cache/actions/notebook_actions.dart';
import 'package:cache/actions/setup_status.dart';
import 'package:cache/search/core_numbering.dart';
import 'package:cache/search/core_tool_host.dart';
import 'package:cache/weather/places.dart';
import 'package:cache_search/cache_search.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../packages/cache_search/test/engine_test.dart' show FakeNative;
import 'support/parity_fixtures.dart';

/// The core's act calls, inside the worker: an act call is handed back as host_run, cs_act_finish echoes the reply it got (so the
/// test sees what reached the core) and numbers one result, cs_act_outcome tags what it got.
class ActNative extends FakeNative implements CsActNative {
  var finished = false;
  var installs = 0;

  @override
  bool get hasAct => true;

  @override
  String? tool(int handle, int conv, String name, String args, String now) => jsonEncode({
        'content': name == 'act'
            ? jsonEncode({'ok': true, 'status': 'host_run', 'run_id': 'r1', 'action': (jsonDecode(args) as Map)['action'], 'fields': (jsonDecode(args) as Map)['fields'] ?? {}})
            : '{"ok":true}',
        'ids': [],
      });

  @override
  String? conversationIds(int conv) => jsonEncode({
        'ids': [
          {'n': 1, 'address': 'zim:a/1', 'title': 'Earlier'},
          if (finished) {'n': 2, 'address': 'place:k1', 'title': 'Home'},
        ],
      });

  @override
  String? actSetDefinitions(int handle, String defsJson) => jsonEncode({'accepted': ++installs, 'rejected': [], 'not_listed': []});

  @override
  int actSetModulesOff(int handle, String? modulesJson) => 0;

  @override
  String? actResolve(int handle, String action, String? fieldsJson) => jsonEncode({'ok': true, 'action': action, 'fields': jsonDecode(fieldsJson ?? '{}')});

  @override
  String? actFinish(int conv, String runId, String replyJson) {
    finished = true;
    return '{"ok":true,"status":"done","run":"$runId","reply":$replyJson}';
  }

  @override
  String? actOutcome(int conv, String outcomeJson) => 'outcome $outcomeJson';
}

CsNative actNative() => ActNative();

/// The app's own actions as the captures' rows have them: the Places list is just "Home".
Future<ActionRegistry> _appRegistry() async {
  final reg = ActionRegistry();
  final none = SetupDeps(
    connection: () async => const [],
    regions: () async => const [],
    libraries: () async => const [],
    liveData: () async => const [],
    webSearch: () async => const [],
    places: () async => const [],
    models: () async => const [],
    location: () async => const [],
  );
  await AppActions(
    registry: reg,
    setup: none,
    places: PlacesDeps(save: ({required name, required lat, required lon, label}) async => throw UnimplementedError(), list: () async => const []),
    watch: WatchDeps(
      choices: () async => const [WatchPlace(id: 'place:home', kind: PlaceKind.saved, name: 'Home', subtitle: '', lat: 43.6, lon: -116.2, key: 'home')],
      watched: () => const {},
      setWatched: (_, _) {},
    ),
    sources: SourceDeps(available: (_) => true, needsKey: (_) => false, setOn: (_, _) async {}),
    navigation: NavigationDeps(route: (_) async => throw UnimplementedError(), guiding: () => false, preview: (_) => false, start: () async {}, show: () {}),
  ).publishAll();
  return reg;
}

void _publishNotebook(ActionRegistry reg, List<Map<String, dynamic>> logs) {
  final defs = notebookActions(logs);
  expect(reg.publish('notebook', defs, {for (final d in defs) d['id'] as String: (_) async => {}}), isEmpty);
}

List<Map<String, dynamic>> _logs(String file) {
  final j = parityJson(file) as Map;
  return [for (final l in (j['logs'] ?? j['templates']) as List) (l as Map).cast<String, dynamic>()];
}

void main() {
  group('the published definitions are the captures\' bytes', () {
    test('app actions then the Notebook journal (gen-places-038)', () async {
      final reg = await _appRegistry();
      _publishNotebook(reg, const []);
      expect('${jsonEncode(reg.definitions)}\n', parityText('act-definitions-gen-places-038.json'));
    });

    test('app actions then the journal and three logs with their last entries (nb-067)', () async {
      final reg = await _appRegistry();
      _publishNotebook(reg, _logs('notebook-logs-nb-067.json'));
      expect('${jsonEncode(reg.definitions)}\n', parityText('act-definitions-nb-067.json'));
    });

    test('the Notebook generator on the starter templates: no entries, at most 8 logs', () {
      expect('${jsonEncode(notebookActions(_logs('notebook-starters-input.json')))}\n', parityText('notebook-starters-definitions.json'));
    });
  });

  group('the Notebook generator follows notebook_actions.py', () {
    Map<String, dynamic> one(Map<String, dynamic> log) => notebookActions([log])[1];

    test('locked logs are left out, repeated names get _2, and the cap is 8', () {
      final logs = [
        {'name': 'Fuel', 'fields': const []},
        {'name': 'Secret', 'fields': const [], 'locked': true},
        {'name': 'fuel!', 'fields': const []},
        for (var i = 0; i < 10; i++) {'name': 'Log $i', 'fields': const []},
      ];
      final ids = [for (final d in notebookActions(logs)) d['id']];
      expect(ids.take(3), ['notebook.add_journal_entry', 'notebook.log_fuel', 'notebook.log_fuel_2']);
      expect(ids, hasLength(9));
      expect(ids, isNot(contains('notebook.log_secret')));
    });

    test('field names, units, choices, extras and the 10-field limit', () {
      final d = one({
        'name': 'Water',
        'fields': [
          {'label': 'Gallons', 'type': 'number', 'unit': 'gal'},
          {'label': 'Run time', 'type': 'number', 'unit': 'min'},
          {'label': 'Kind', 'type': 'choice', 'choices': ['a|b', 'c']},
          {'label': 'Place', 'type': 'place'},
          {'label': 'Photo', 'type': 'photo'},
          for (var i = 0; i < 8; i++) {'label': 'F$i', 'type': 'yes_no'},
        ],
      });
      final fields = d['fields'] as Map;
      expect(fields.keys, ['gallons', 'run_time_min', 'kind', 'place', 'f0', 'f1', 'f2', 'date', 'time', 'notes']);
      expect(fields['kind'], {'type': 'string', 'maxLength': 500});
      expect(d['required'], isEmpty);
    });

    test('the description: last entry, main value, and cuts that keep the date', () {
      expect(one({'name': 'Eggs', 'fields': const []})['description'], "Add an entry to the user's Eggs log. No entries yet.");
      final fields = [
        {'label': 'Note', 'type': 'text'},
        {'label': 'Count', 'type': 'number', 'unit': 'ea'},
      ];
      expect(one({'name': 'Eggs', 'fields': fields, 'last_entry': {'date': '2026-01-01', 'time': '07:05', 'values': {'Note': '  two \n brown ', 'Count': 2.5}}})['description'],
          "Add an entry to the user's Eggs log. Last: 2026-01-01 07:05, Count 2.5 ea.");
      expect(one({'name': 'Eggs', 'fields': fields, 'last_entry': {'date': '2026-01-01', 'time': '07:05', 'values': {'Note': '  two \n brown '}}})['description'],
          "Add an entry to the user's Eggs log. Last: 2026-01-01 07:05, Note two brown.");
      expect(one({'name': 'Eggs', 'fields': fields, 'last_entry': {'date': '2026-01-01', 'time': '07:05', 'values': {}}})['description'],
          "Add an entry to the user's Eggs log. Last: 2026-01-01 07:05.");
      final long = one({'name': 'N' * 100, 'fields': fields, 'last_entry': {'date': '2026-01-01', 'time': '07:05', 'values': {'Note': 'x' * 50}}});
      expect(long['description'], "Add an entry to the user's ${'N' * 64} log. Last: 2026-01-01 07:05.");
      expect((long['description'] as String).length, 120);
      expect(long['title'], 'Add to ${'N' * 33}');
    });

    test('numbers are written as Python writes them', () {
      expect(notebookNumber(7), '7');
      expect(notebookNumber(7.0), '7');
      expect(notebookNumber(2.5), '2.5');
      expect(notebookNumber(0.1), '0.1');
      expect(notebookNumber(0.0001), '0.0001');
      expect(notebookNumber(0.00001), '1e-05');
      expect(notebookNumber(1.5e-7), '1.5e-07');
      expect(notebookNumber(-12.75), '-12.75');
      expect(notebookNumber(1234567890123456.8), '1234567890123456.8');
      expect(notebookNumber(1e20), '100000000000000000000');
      expect(notebookNumber('7'), isNull);
    });

    test('slugs', () {
      expect(notebookSlug('Fuel fill-up', 32, 'log'), 'fuel_fill_up');
      expect(notebookSlug('  --  ', 32, 'log'), 'log');
      expect(notebookSlug('abc_def', 4, 'x'), 'abc');
    });
  });

  group('the core\'s act calls', () {
    test('a read action handed back as host_run runs in the app and the core\'s answer is the tool message', () async {
      final core = await SearchCore.open(const [], native: actNative);
      final numbering = CoreNumbering(core.newConversation);
      try {
        final ran = <(String, Map<String, dynamic>)>[];
        final host = CoreToolHost(
          core: core,
          numbering: numbering,
          runAction: (action, fields) async {
            ran.add((action, fields));
            return {'ok': true, 'status': 'done', 'action': action, 'result': {'places': [{'address': 'place:k1', 'name': 'Home'}]}};
          },
        );
        final r = await host.call('act', {'action': 'places.list', 'fields': {}}, DateTime(2026));
        expect(ran.single.$1, 'places.list');
        expect(r.content, '{"ok":true,"status":"done","run":"r1","reply":{"ok":true,"result":{"places":[{"address":"place:k1","name":"Home"}]}}}');
        expect([for (final i in r.ids) i.n], [2]);

        final failing = CoreToolHost(
          core: core,
          numbering: numbering,
          runAction: (action, fields) async =>
              {'ok': false, 'status': 'failed', 'action': action, 'error': {'type': 'busy', 'detail': 'Finish or end the route first.'}},
        );
        expect(jsonDecode((await failing.call('act', {'action': 'navigation.start', 'fields': {'route_id': 'x'}}, DateTime(2026))).content)['reply'],
            {'ok': false, 'error': {'type': 'busy', 'detail': 'Finish or end the route first.'}});
        // Any other tool is passed through as it was.
        expect((await host.call('nearby', {}, DateTime(2026))).content, '{"ok":true}');
      } finally {
        await numbering.dispose();
        await core.close();
      }
    });

    test('definitions reach the core once per set and again for a core opened again; outcomes are the core\'s text', () async {
      SearchCore? open = await SearchCore.open(const [], native: actNative);
      final act = CoreActCore(() => open);
      final defs = [kSetupStatusDefinition];
      try {
        expect(await act.install(defs), isTrue);
        expect(await act.install([...defs]), isFalse);
        expect(await act.install(const []), isTrue);
        final numbering = CoreNumbering(open.newConversation);
        expect(await act.outcome(numbering, {'ok': true, 'status': 'declined', 'confirm_id': 'c1', 'action': 'places.save'}),
            'outcome {"ok":true,"status":"declined","confirm_id":"c1","action":"places.save"}');
        await numbering.dispose();
        expect(await act.actResolve('places.list', {}), {'ok': true, 'action': 'places.list', 'fields': {}});
        await act.setModulesOff(const ['weather']);
        final again = await SearchCore.open(const [], native: actNative);
        await open.close();
        open = again;
        expect(await act.install(const []), isTrue, reason: 'the set lives in the core\'s memory only');
      } finally {
        await open?.close();
        open = null;
      }
      expect(await act.install(defs), isFalse, reason: 'no core, nothing to install');
    });

    test('without the core the outcome is the contract\'s message', () async {
      expect(await const ActCoreStandIn().outcome(null, {'ok': false, 'status': 'failed', 'confirm_id': 'c2', 'action': 'a.b', 'error': {'type': 'x'}}),
          '{"host_event":"act_outcome","ok":false,"status":"failed","confirm_id":"c2","action":"a.b","error":{"type":"x"}}');
    });
  });
}
