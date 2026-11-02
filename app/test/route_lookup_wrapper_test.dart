import 'dart:convert';

import 'package:cache_search/cache_search.dart';
import 'package:cache/search/core_numbering.dart';
import 'package:cache/search/core_tool_host.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../packages/cache_search/test/engine_test.dart' show FakeNative;
import 'nav_fakes.dart';

class LookupNative extends FakeNative implements CsMapNative {
  @override
  bool get hasMap => true;
  @override
  String? tool(int handle, int conv, String name, String args, String now) =>
      jsonEncode({
        'content': jsonEncode({
          'ok': true,
          'route_id': 'exact',
          'distance_m': 1,
        }),
        'ids': [
          {'n': 1, 'address': 'nav:exact', 'title': 'Route'},
        ],
      });

  @override
  String? mapRoute(int handle, String requestJson) {
    final request = jsonDecode(requestJson) as Map;
    if (request.length != 1 || request['route_id'] != 'exact') {
      throw StateError('Lookup must pass only the exact raw route_id');
    }
    return jsonEncode(fakeRouteJson(id: 'exact'));
  }
}

CsNative lookupNative() => LookupNative();

void main() {
  test(
    'public wrapper sends sole route_id through existing worker/engine/FFI seam',
    () async {
      final core = await SearchCore.open(const [], native: lookupNative);
      try {
        final route = await core.mapRouteById('exact');
        expect(route.routeId, 'exact');
        expect(route.geometry, fakeRouteJson(id: 'exact')['geometry']);
        expect(route.alternatives, isEmpty);
        final numbering = CoreNumbering(core.newConversation);
        final host = CoreToolHost(core: core, numbering: numbering);
        final result = await host.call('navigate', {
          'to': 'hospital',
        }, DateTime(2026));
        expect(result.navigationActions.single.route!.raw, route.raw);
        expect(jsonDecode(result.content)['route_id'], 'exact');
        expect(result.content, isNot(contains(route.geometry)));
        await numbering.dispose();
      } finally {
        await core.close();
      }
    },
  );
}
