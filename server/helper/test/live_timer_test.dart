import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../../../packages/cache_search/lib/src/core_dispatch.dart';
import '../../../packages/cache_search/lib/src/native_api.dart';
import '../bin/live_timer.dart';
import 'fake_native.dart';

/// The core with live data: downloads are jobs (cs_live_fetch_start) that finish at the first poll, and the stored data is canned.
class _LiveFake extends FakeNative implements CsLiveJobNative {
  final Map<int, String> results = {};
  final Set<String> failSources = {};
  final Map<String, String> stored = {};
  final List<String> liveOps = [];
  String? policy;
  int jobsStarted = 0;

  @override
  bool get hasLivePolicy => true;

  @override
  int liveSetFetchPolicy(int handle, String? policyJson) {
    policy = policyJson;
    return 0;
  }

  @override
  String? live(int handle, String op, String requestJson) {
    liveOps.add(op);
    if (op == 'sources') return '{"sources":[],"errors":[]}';
    final r = jsonDecode(requestJson) as Map;
    if (op == 'get') return stored['${r['source']}'] ?? '{"items":[]}';
    return '{"fetched":true}';
  }

  @override
  int liveFetchStart(int handle, String requestJson) {
    final r = jsonDecode(requestJson) as Map;
    final id = 500 + jobsStarted++;
    results[id] = failSources.contains(r['source'])
        ? '{"state":"failed","done":0,"total":1,"error":{"code":"fetch_failed","message":"HTTP 503"}}'
        : '{"state":"done","done":1,"total":1,"result":{"fetched":true}}';
    return id;
  }

  @override
  String? jobProgress(int job) => results[job];
}

void main() {
  late _LiveFake fake;
  late CoreDispatcher d;
  late Directory support;
  late LiveTimer timer;
  var clock = DateTime(2026, 11, 9, 12);

  File plan() => File('${support.path}/live_plan.json');

  void writePlan(Map<String, dynamic> p) => plan().writeAsStringSync(jsonEncode(p));

  Map<String, dynamic> planOf(List<Map<String, dynamic>> sources) => {
        'sources': sources,
        'places': [
          {'id': 'here', 'name': 'Home', 'request': {'key': 'at:43.61,-116.20', 'name': 'current location', 'lat': 43.61, 'lon': -116.2}},
        ],
      };

  setUp(() {
    fake = _LiveFake();
    d = CoreDispatcher(() => fake);
    d.handle('open', {'sources': <Object>[], 'extra': null});
    support = Directory.systemTemp.createTempSync('live-timer');
    clock = DateTime(2026, 11, 9, 12);
    timer = LiveTimer(d, support: support, poll: const Duration(milliseconds: 1), clock: () => clock);
  });
  tearDown(() {
    timer.stop();
    support.deleteSync(recursive: true);
  });

  test('with no plan a run does nothing', () async {
    expect(await timer.runOnce(), isNull);
    expect(fake.policy, isNull);
  });

  test('a run grants the policy for the planned sources, fetches each for each place and writes the status', () async {
    writePlan(planOf([
      {'id': 'weather', 'title': 'Weather', 'alerts': false},
      {'id': 'alerts', 'title': 'Alerts', 'alerts': true},
    ]));
    final r = await timer.runOnce();
    expect(r, (ok: 2, failed: 0));
    expect(jsonDecode(fake.policy!)['enabled_sources'], ['alerts', 'weather']);
    expect(jsonDecode(fake.policy!)['online'], true);
    expect(fake.calls.where((c) => c.startsWith('jobFree:')).length, 2);
    final status = jsonDecode(File('${support.path}/live-catalogues/status.json').readAsStringSync()) as Map;
    expect(status['run'], clock.millisecondsSinceEpoch);
    expect(status['ok'], clock.millisecondsSinceEpoch);
    expect(status['failure'], isNull);
  });

  test('a failed download is counted, and a source that works still marks the run ok', () async {
    fake.failSources.add('weather');
    writePlan(planOf([
      {'id': 'weather', 'title': 'Weather', 'alerts': false},
      {'id': 'alerts', 'title': 'Alerts', 'alerts': true},
    ]));
    expect(await timer.runOnce(), (ok: 1, failed: 1));
    final status = jsonDecode(File('${support.path}/live-catalogues/status.json').readAsStringSync()) as Map;
    expect(status['ok'], isNotNull);
    expect(status['failure'], 'HTTP 503');
  });

  test('alerts in force are recorded once in the inbox; expired and "none active" items are not', () async {
    fake.stored['alerts'] = jsonEncode({
      'expired': false,
      'items': [
        {'address': 'live:alerts/here/a1', 'label': 'Red Flag Warning', 'fields': {'Severity': 'Moderate', 'Area': 'Ada'}},
        {'address': 'live:alerts/here/none', 'label': 'No active alerts', 'none_active': true},
      ],
    });
    writePlan(planOf([
      {'id': 'weather', 'title': 'Weather', 'alerts': false},
      {'id': 'alerts', 'title': 'Alerts', 'alerts': true},
    ]));
    await timer.runOnce();
    await timer.runOnce();
    final inbox = jsonDecode(File('${support.path}/alerts_inbox.json').readAsStringSync()) as List;
    expect(inbox, hasLength(1));
    expect((inbox.single as Map)['label'], 'Red Flag Warning');
    expect((inbox.single as Map)['summary'], 'Severity Moderate · Area Ada');
    expect((inbox.single as Map)['place_name'], 'Home');

    fake.stored['alerts'] = jsonEncode({'expired': true, 'items': [{'address': 'live:alerts/here/a2', 'label': 'Old'}]});
    await timer.runOnce();
    expect((jsonDecode(File('${support.path}/alerts_inbox.json').readAsStringSync()) as List), hasLength(1));
  });

  test('a core that is not open is waited for, not an error', () async {
    d.handle('close', const {});
    writePlan(planOf([{'id': 'weather', 'title': 'Weather', 'alerts': false}]));
    expect(await timer.runOnce(), isNull);
  });
}
