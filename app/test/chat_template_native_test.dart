// The template layer (cl_tmpl_* in cache_llama.cpp): rendering a request with a template given as text, and parsing generated
// text, with no chat model loaded. The LiteRT-LM path (lib/litert) depends on it.
//
// Needs the native library (libcache_llama.so loadable, LD_LIBRARY_PATH) and a GGUF for its vocabulary: CACHE_EMBED_MODELS_DIR is
// a folder holding bge-m3-Q8_0.gguf (the only GGUF CI downloads; only its vocabulary is read, the template is the Gemma 4 one
// from a .litertlm file). Skipped without them. The Gemma 4 tool-call tokens are not special tokens in that vocabulary, which
// does not matter here: rendering and parsing work on text.
import 'dart:io';

import 'package:cache_llama/cache_llama.dart';
import 'package:flutter_test/flutter_test.dart';

final String? _models = Platform.environment['CACHE_EMBED_MODELS_DIR'];

const _tools = [
  {
    'type': 'function',
    'function': {
      'name': 'search',
      'description': 'Search the library.',
      'parameters': {
        'type': 'object',
        'properties': {
          'query': {'type': 'string', 'description': 'What to search for.'},
        },
        'required': ['query'],
      },
    },
  },
];

Map<String, dynamic> _req({bool tools = true, String? toolChoice}) => {
      'messages': [
        {'role': 'system', 'content': 'Be brief.'},
        {'role': 'user', 'content': 'Hi'},
      ],
      if (tools) 'tools': _tools,
      if (toolChoice != null) 'tool_choice': toolChoice,
      'enable_thinking': false,
    };

void main() {
  late ChatTemplate t;
  final skip = _models == null ? 'CACHE_EMBED_MODELS_DIR is not set' : false;

  setUpAll(() {
    if (_models == null) return;
    final template = File('../packages/cache_llama/test/fixtures/gemma4-litertlm-stock-template.jinja').readAsStringSync();
    t = ChatTemplate.load('$_models/bge-m3-Q8_0.gguf', templateOverride: template);
  });
  tearDownAll(() {
    if (_models != null) t.dispose();
  });

  test('renders the system, user and model turns without a leading BOS', () {
    final r = t.render(_req(tools: false));
    // ignore: avoid_print
    print('rendered: ${r.prompt.replaceAll('\n', r'\n')}');
    expect(r.prompt, startsWith('<|turn>system\nBe brief.<turn|>\n<|turn>user\nHi<turn|>\n<|turn>model\n'));
    expect(r.promptTokens, greaterThan(5));
    expect(r.stopOnToolOpen, isFalse);
  }, skip: skip);

  test('declares the tool in the system turn, and tool_choice none asks to stop at a tool-call opening', () {
    final auto = t.render(_req());
    expect(auto.prompt, startsWith('<|turn>system\nBe brief.\n\n<|tool>declaration:search{'));
    expect(auto.stopOnToolOpen, isFalse);
    final none = t.render(_req(toolChoice: 'none'));
    expect(none.prompt, auto.prompt);
    expect(none.stopOnToolOpen, isTrue);
  }, skip: skip);

  test('counts tokens of generated text', () {
    expect(t.count('Hello there'), greaterThan(0));
  }, skip: skip);

  test('a tool call that stopped at its closing token (no <tool_call|>) is closed and parsed', () {
    t.render(_req());
    const call = '<|tool_call>call:search{query:<|"|>water<|"|>}';
    t.feed(call);
    final fin = t.finish();
    expect(fin.parseError, isNull);
    expect(fin.toolCalls, hasLength(1));
    expect(fin.toolCalls.single.name, 'search');
    expect(fin.toolCalls.single.argumentsMap['query'], 'water');
  }, skip: skip);

  test('the same call given whole to finish is closed too', () {
    t.render(_req());
    final fin = t.finish('<|tool_call>call:search{query:<|"|>water<|"|>}');
    expect(fin.toolCalls, hasLength(1));
    expect(fin.toolCalls.single.argumentsMap['query'], 'water');
  }, skip: skip);

  test('a call that already has its closing token is not closed twice', () {
    t.render(_req());
    t.feed('<|tool_call>call:search{query:<|"|>water<|"|>}<tool_call|>');
    final fin = t.finish();
    expect(fin.parseError, isNull);
    expect(fin.toolCalls, hasLength(1));
  }, skip: skip);

  test('plain text is the content', () {
    t.render(_req());
    final p = t.feed('Boil it for a minute.');
    expect(p.content, contains('Boil'));
    final fin = t.finish();
    expect(fin.content, 'Boil it for a minute.');
    expect(fin.toolCalls, isEmpty);
  }, skip: skip);
}
