import 'dart:convert';

import 'package:cache_search/cache_search.dart';
import 'package:flutter_test/flutter_test.dart';

import 'engine_test.dart' show FakeNative;

/// The native seam with the act calls: answers from canned strings and records what was passed.
class ActFake extends FakeNative implements CsActNative {
  bool act = true;
  final Map<String, String?> actReplies = {};
  final List<String> actCalls = [];
  int modulesOffResult = 0;

  @override
  bool get hasAct => act;

  @override
  String? actSetDefinitions(int handle, String defsJson) {
    actCalls.add('defs:$defsJson');
    return actReplies['defs'];
  }

  @override
  int actSetModulesOff(int handle, String? modulesJson) {
    actCalls.add('off:$modulesJson');
    return modulesOffResult;
  }

  @override
  String? actResolve(int handle, String action, String? fieldsJson) {
    actCalls.add('resolve:$action:$fieldsJson');
    return actReplies['resolve'];
  }

  @override
  String? actFinish(int conv, String runId, String replyJson) {
    actCalls.add('finish:$conv:$runId:$replyJson');
    return actReplies['finish'];
  }

  @override
  String? actOutcome(int conv, String outcomeJson) {
    actCalls.add('outcome:$conv:$outcomeJson');
    return actReplies['outcome'];
  }
}

void main() {
  test('definitions, modules off and resolve go to the core as JSON and come back parsed', () {
    final n = ActFake()
      ..actReplies['defs'] = '{"accepted":1,"rejected":[],"not_listed":[]}'
      ..actReplies['resolve'] = '{"ok":true,"action":"places.save","fields":{"name":"Elk camp","place":{"lat":44.21,"lon":-114.93}}}';
    final e = SearchEngine(n, 7);
    final defs = [
      {'id': 'places.list', 'module': 'places', 'title': 'List saved places', 'description': "The user's saved places.", 'effect': 'read', 'fields': <String, dynamic>{}, 'required': <String>[]},
    ];
    expect(e.actSetDefinitions(defs)['accepted'], 1);
    expect(n.actCalls.last, 'defs:${jsonEncode(defs)}');
    e.actSetModulesOff(['weather']);
    expect(n.actCalls.last, 'off:["weather"]');
    expect(e.actResolve('places.save', {'name': 'Elk camp', 'place': '44.21,-114.93'})['fields']['place'], {'lat': 44.21, 'lon': -114.93});
    expect(n.actCalls.last, 'resolve:places.save:{"name":"Elk camp","place":"44.21,-114.93"}');
  });

  test('finish and outcome return the core\'s exact text, in the conversation', () {
    const finished = '{"ok":true,"status":"done","action":"places.list","result":{"places":[{"n":3,"name":"Home"}]}}';
    const outcome = '{"host_event":"act_outcome","ok":true,"status":"declined","confirm_id":"c1","action":"places.save"}';
    final n = ActFake()
      ..actReplies['finish'] = finished
      ..actReplies['outcome'] = outcome;
    final e = SearchEngine(n, 7);
    final c = ConversationNumbers(n, 9);
    expect(e.actFinish(c, 'r1', {'ok': true, 'result': {'places': []}}), finished);
    expect(n.actCalls.last, 'finish:9:r1:{"ok":true,"result":{"places":[]}}');
    expect(e.actOutcome(c, {'ok': true, 'status': 'declined', 'confirm_id': 'c1', 'action': 'places.save'}), outcome);
    expect(n.actCalls.last, 'outcome:9:{"ok":true,"status":"declined","confirm_id":"c1","action":"places.save"}');
  });

  test('a refused call raises the core\'s error, and an older core says it has no act tool', () {
    final n = ActFake()..error = '{"code":"not_found","message":"no such run"}';
    final e = SearchEngine(n, 7);
    expect(() => e.actFinish(ConversationNumbers(n, 9), 'r9', {'ok': true, 'result': {}}),
        throwsA(isA<CacheSearchException>().having((x) => x.code, 'code', 'not_found')));
    n.modulesOffResult = -1;
    expect(() => e.actSetModulesOff([]), throwsA(isA<CacheSearchException>()));
    n.act = false;
    expect(() => e.actSetDefinitions([]), throwsA(isA<CacheSearchException>().having((x) => x.code, 'code', 'unsupported')));
  });
}
