import 'dart:convert';

import 'road_511_def.dart';
import 'road_sources.dart';
import 'wzdx_def.dart';

// The road source definitions the app makes, as the core's tests read them (tool/road_defs_fixtures.dart writes them to
// packages/cache_search/native/cache_live/tests/fixtures/road/generated/; test/road_defs_fixtures_test.dart keeps them equal).

const String kFixtureDir = '../packages/cache_search/native/cache_live/tests/fixtures/road/generated';

/// File name to definition text.
Map<String, String> roadFixtures(RoadSourcesFile f) {
  String enc(Map<String, dynamic> j) => '${const JsonEncoder.withIndent('  ').convert(j)}\n';
  RoadSite site(String host) => f.siteByHost(host)!;
  final out = <String, String>{
    'idaho-events.json': enc(road511EventsDef(site('511.idaho.gov'))),
    'idaho-conditions.json': enc(road511ConditionsDef(site('511.idaho.gov'))!),
    'ontario-events.json': enc(road511EventsDef(site('511on.ca'))),
    'ontario-conditions.json': enc(road511ConditionsDef(site('511on.ca'))!),
    'nl-events.json': enc(road511EventsDef(site('511nl.ca'))),
    'georgia-events.json': enc(road511EventsDef(site('511ga.org'))),
    'nc-conditions.json': enc(road511ConditionsDef(site('drivenc.gov'))!),
    'wzdx-idaho.json': enc(wzdxDef(const WzdxSpec(id: 'wzdx-idaho', title: 'Road work zones near the place, Idaho (WZDx)', provider: 'Idaho Transportation Department', area: 'Idaho', url: 'https://511.idaho.gov/api/wzdx', legacy: true))),
    'wzdx-open.json': enc(wzdxDef(const WzdxSpec(id: 'wzdx-nysdot', title: 'Road work zones near the place, New York (WZDx)', provider: 'New York DOT', area: 'New York', url: 'https://511ny.org/api/wzdx', updateMinutes: 15))),
    'wzdx-query-key.json': enc(wzdxDef(WzdxSpec(id: 'wzdx-ncdot', title: 'Road work zones near the place, North Carolina (WZDx)', provider: 'North Carolina DOT', area: 'North Carolina', url: 'https://www.drivenc.gov/api/wzdx', auth: f.feedById('ncdot')!.auth, keyAlias: 'wzdx.ncdot', updateMinutes: 4))),
    'wzdx-header-key.json': enc(wzdxDef(WzdxSpec(id: 'wzdx-ohio', title: 'Road work zones near the place, Ohio (WZDx)', provider: 'Ohio DOT', area: 'Ohio', url: 'https://example.org/wzdx/ohio', auth: f.feedById('ohio')!.auth, keyAlias: 'wzdx.ohio', updateMinutes: 60))),
  };
  return out;
}

