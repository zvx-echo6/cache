import 'dart:io';

import 'package:cache/chat/local_llama_backend.dart';
import 'package:cache/chat/tool.dart';
import 'package:cache/chat/tool_loop.dart';
import 'package:cache_llama/cache_llama.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

/// TEST-ONLY search tool with two fixed results (the shipped app has no test data).
class TestSearch extends Tool {
  int calls = 0;
  String? lastQuery;

  @override
  String get name => 'search';
  @override
  String get description => "Search the user's offline library and reference articles";
  @override
  Map<String, dynamic> get parameters => {
        'type': 'object',
        'properties': {
          'query': {'type': 'string', 'description': 'What to look for'},
        },
        'required': ['query'],
      };

  @override
  Future<List<SourceResult>> run(Map<String, dynamic> args) async {
    calls++;
    lastQuery = args['query']?.toString();
    return const [
      SourceResult(
        title: 'WikiMed: Burn',
        snippet: 'Cool the burn under cool running water for 20 minutes. Remove rings. Cover loosely with cling film.',
        address: 'test:wikimed/burn',
      ),
      SourceResult(
        title: 'First aid manual p.142',
        snippet: 'Seek medical help if the burn is larger than the palm or on the face, hands, feet or groin.',
        address: 'test:manual/142',
      ),
    ];
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('model loads, supports tools, calls search and answers', (tester) async {
    // Real async work (isolates, file I/O): leave the test's fake-async zone.
    await tester.runAsync(() async {
    // ignore: avoid_print
    print('STEP: test started');
    final base = (await getExternalStorageDirectory())!;
    // ignore: avoid_print
    print('STEP: dir ${base.path}');
    final model = File('${base.path}/models/model.gguf');
    await model.parent.create(recursive: true); // the app owns this folder; adb then copies the model into it
    // The model is copied in from outside (adb) while the test app installs; wait for it to be complete.
    final expectedSize = int.tryParse(const String.fromEnvironment('MODEL_SIZE')) ?? 0;
    for (var i = 0; i < 180; i++) {
      if (i % 5 == 0) {
        // ignore: avoid_print
        print('STEP: waiting exists=${model.existsSync()} want=$expectedSize have=${model.existsSync() ? model.lengthSync() : -1}');
      }
      if (model.existsSync() && (expectedSize == 0 || model.lengthSync() == expectedSize)) break;
      await Future<void>.delayed(const Duration(seconds: 2));
    }
    expect(model.existsSync(), isTrue, reason: 'copy the model into ${model.path} first');

    // ignore: avoid_print
    print('STEP: model file ${model.lengthSync()} bytes, loading');
    final session = LlamaSession();
    final info = await session.load(model.path);
    // ignore: avoid_print
    print('INFO: ${info.description} chat_format=${info.chatFormat} n_ctx=${info.nCtx} supports_tools=${info.supportsTools}');
    expect(info.supportsTools, isTrue);

    final search = TestSearch();
    final loop = ToolLoop(backend: LocalLlamaBackend(session), tools: [search]);
    final sw = Stopwatch()..start();
    TurnUpdate? last;
    final phases = <TurnPhase>[];
    await for (final u in loop.ask('How do I treat a burn on my hand?')) {
      if (phases.isEmpty || phases.last != u.phase) phases.add(u.phase);
      last = u;
    }
    sw.stop();

    // ignore: avoid_print
    print('PHASES: ${phases.map((p) => p.name).join(' > ')}');
    // ignore: avoid_print
    print('SEARCH CALLS: ${search.calls} (last query: ${search.lastQuery})');
    // ignore: avoid_print
    print('VALID CITATIONS: ${last!.cited.length} ${[for (final c in last.cited) c.id]}');
    // ignore: avoid_print
    print('TIME: ${(sw.elapsedMilliseconds / 1000).toStringAsFixed(1)} s '
        '(prompt tokens ${last.promptTokens}, generated ${last.generatedTokens})');
    // ignore: avoid_print
    print('FINAL ANSWER:\n${last.text}\nEND ANSWER');

    expect(last.error, isNull);
    expect(search.calls, greaterThan(0), reason: 'the model should call search');
    expect(last.text.trim(), isNotEmpty);
    await session.dispose();
    });
  }, timeout: const Timeout(Duration(minutes: 20)));
}
