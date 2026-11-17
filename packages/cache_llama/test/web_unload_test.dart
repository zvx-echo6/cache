import 'dart:convert';

import 'package:cache_llama/llm_remote_unload.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the web session asks the server to unload: POST /api/llm/unload with {"v":1}', () async {
    final seen = <(String, Map<String, dynamic>)>[];
    await unloadOnServer((path, body) async {
      seen.add((path, body));
      return LlmHttpReply(200, jsonEncode({'v': 1, 'ok': true, 'result': {'unloaded': true}}));
    });
    expect(seen, [('/api/llm/unload', {'v': 1})]);
  });

  test('a refusal surfaces with the server\'s own message', () async {
    final body = jsonEncode({'v': 1, 'ok': false, 'error': {'code': 'busy', 'message': 'too many requests are waiting for the model; try again shortly'}});
    await expectLater(
      unloadOnServer((path, b) async => LlmHttpReply(429, body)),
      throwsA(isA<StateError>().having((e) => e.message, 'message', 'too many requests are waiting for the model; try again shortly')),
    );
  });

  test('a failure with no message from the server gets a plain one', () async {
    await expectLater(
      unloadOnServer((path, b) async => LlmHttpReply(502, '<html>bad gateway</html>')),
      throwsA(isA<StateError>().having((e) => e.message, 'message', 'The server could not unload the model (HTTP 502)')),
    );
  });

  test('a server that cannot be reached surfaces too', () async {
    await expectLater(
      unloadOnServer((path, b) async => throw Exception('network down')),
      throwsA(isA<StateError>().having((e) => e.message, 'message', 'The server could not be reached to unload the model')),
    );
  });
}
