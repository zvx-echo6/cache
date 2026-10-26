import 'dart:io';

import 'package:cache/nav/query_embedder.dart';
import 'package:cache_llama/cache_llama.dart';
import 'package:flutter_test/flutter_test.dart';

class _Fake extends CacheEmbedder {
  _Fake(String path) : super(modelPath: path);
  final List<String> asked = [];
  @override
  Future<List<double>> embed(String text) async {
    asked.add(text);
    return [0.25, 0.5, 0.75];
  }
}

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('embed'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('without the model file there is no query vector, so the core searches by keywords', () async {
    final e = PhoneQueryEmbedder(modelsDir: () async => dir, make: _Fake.new);
    expect(await e('pharmacy'), isNull);
  });

  test('with the file the query vector carries the file name as its model id, which is what the pack records', () async {
    File('${dir.path}/$kQueryEmbedModelFile').writeAsStringSync('x');
    final made = <_Fake>[];
    final e = PhoneQueryEmbedder(modelsDir: () async => dir, make: (p) => _Fake(p)..also(made.add));
    final v = (await e('somewhere to get water'))!;
    expect(v.model, 'bge-m3-Q8_0.gguf');
    expect(v.vector, [0.25, 0.5, 0.75]);
    await e('again');
    expect(made, hasLength(1), reason: 'one embedder, loaded once');
    expect(made.single.asked, ['somewhere to get water', 'again']);
  });
}

extension _Also<T> on T {
  void also(void Function(T) f) => f(this);
}
