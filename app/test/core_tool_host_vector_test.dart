import 'dart:convert';

import 'package:cache_search/cache_search.dart';
import 'package:cache/search/core_numbering.dart';
import 'package:cache/search/core_tool_host.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../packages/cache_search/test/engine_test.dart' show FakeNative;

/// Answers every cs_tool call with the arguments it was given, so the test sees what reached the core.
class EchoNative extends FakeNative {
  @override
  String? tool(int handle, int conv, String name, String args, String now) => jsonEncode({'content': args, 'ids': []});
}

CsNative echoNative() => EchoNative();

void main() {
  Future<Map<String, dynamic>> sent(CoreToolHost host, String name, Map<String, dynamic> args) async =>
      (jsonDecode((await host.call(name, args, DateTime(2026))).content) as Map).cast<String, dynamic>();

  test('the search tool carries the search model query vector to the core', () async {
    final core = await SearchCore.open(const [], native: echoNative);
    final numbering = CoreNumbering(core.newConversation);
    try {
      final asked = <String>[];
      final host = CoreToolHost(
        core: core,
        numbering: numbering,
        queryVector: (q) async {
          asked.add(q);
          return const QueryVector('bge-m3-Q8_0', [0.5, 0.25]);
        },
      );
      expect(await sent(host, 'search', {'query': 'water filter'}), {
        'query': 'water filter',
        'query_vector': {'model': 'bge-m3-Q8_0', 'vector': [0.5, 0.25]},
      });
      expect(asked, ['water filter']);
      // only search gets one
      expect(await sent(host, 'nearby', {'category': 'pharmacy'}), {'category': 'pharmacy'});
      expect(asked, ['water filter']);

      // no search model: keywords, nothing added
      final none = CoreToolHost(core: core, numbering: numbering, queryVector: (q) async => null);
      expect(await sent(none, 'search', {'query': 'water filter'}), {'query': 'water filter'});
    } finally {
      await numbering.dispose();
      await core.close();
    }
  });
}
