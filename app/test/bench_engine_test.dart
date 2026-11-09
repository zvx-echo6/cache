import 'dart:convert';

import 'package:cache/platform/bench_engine.dart';
import 'package:cache_llama/cache_llama.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('with no engine config the configure JSON is exactly what every build sends (no engine key)', () {
    final options = jsonDecode(llamaLoadOptions(prefixDir: '/support/prompt-prefix')) as Map<String, dynamic>;
    expect(options, {'prefix_dir': '/support/prompt-prefix', 'repack_weights': false});
    expect(options.containsKey('engine'), isFalse);
    expect(llamaLoadOptions(prefixDir: '/p', engine: null), llamaLoadOptions(prefixDir: '/p'));
  });

  test('an engine config is passed through as the engine object', () {
    final options = jsonDecode(llamaLoadOptions(engine: {'n_threads': 4, 'n_threads_batch': 5})) as Map<String, dynamic>;
    expect(options['engine'], {'n_threads': 4, 'n_threads_batch': 5});
    expect(options['prefix_dir'], '');
  });

  test('the intent extra: a JSON object is used, anything else is no config', () {
    expect(parseBenchEngine(null), isNull);
    expect(parseBenchEngine(''), isNull);
    expect(parseBenchEngine('not json'), isNull);
    expect(parseBenchEngine('[1,2]'), isNull);
    expect(parseBenchEngine('{"n_threads":4,"flash_attn":"on"}'), {'n_threads': 4, 'flash_attn': 'on'});
  });
}
