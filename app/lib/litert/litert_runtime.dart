import 'dart:async';

import 'package:cache_llama/cache_llama.dart';
import 'package:flutter/services.dart';

import '../chat/model_backend.dart';
import 'litertlm_header.dart';

/// The LiteRT-LM chat path of the Cache test APK (Android; compiled in only with CACHE_LITERT, see litert_flag.dart). A
/// .litertlm model is rendered with its own Jinja template by the native template layer (cl_tmpl_*, the vocabulary of a
/// Gemma 4 GGUF), decoded by the LiteRT engine behind the `cache/litert` channel (android/app/src/litert), and its output is
/// parsed by the same layer, so the Ask loop sees the same messages as with llama.cpp.
class LiteRtRuntime {
  LiteRtRuntime({MethodChannel? channel, EventChannel? events, ChatTemplate Function(String gguf, String template)? loadTemplate})
      : _channel = channel ?? const MethodChannel('cache/litert'),
        _events = events ?? const EventChannel('cache/litert/stream'),
        _loadTemplate = loadTemplate ?? ((gguf, t) => ChatTemplate.load(gguf, templateOverride: t));

  final MethodChannel _channel;
  final EventChannel _events;
  final ChatTemplate Function(String gguf, String template) _loadTemplate;

  final StreamController<Map<Object?, Object?>> _bus = StreamController.broadcast(sync: true);
  StreamSubscription<dynamic>? _eventSub;
  ChatTemplate? _tmpl;
  String _backend = 'cpu';
  bool _busy = false;
  int _nextId = 1;

  bool get isLoaded => _tmpl != null;

  /// The tool-call opening Gemma 4 writes; with tool_choice "none" the text from it on is dropped and the generation stopped.
  static const String toolOpen = '<|tool_call>';

  /// Loads [path] (a .litertlm file). [vocabGguf]: a Gemma 4 GGUF whose vocabulary the template layer uses. Returns what the
  /// app shows for a loaded model. Throws a [StateError] with the reason on failure.
  Future<ModelInfo> load(String path, {required int nCtx, required String? vocabGguf, required String cacheDir}) async {
    await unload();
    final LiteRtLmHeader header;
    try {
      header = LiteRtLmHeader.fromFile(path);
    } on FormatException catch (e) {
      throw StateError('Cannot read the .litertlm file: ${e.message}');
    }
    if (header.hasPromptTemplates) {
      throw StateError('This .litertlm file has its own prompt templates (turn prefixes the engine adds), which Cache does not support yet');
    }
    final template = header.jinjaTemplate;
    if (template == null || template.isEmpty) throw StateError('This .litertlm file has no chat template');
    if (vocabGguf == null) {
      throw StateError('A .litertlm model needs a Gemma 4 .gguf chat model in the models folder (its tokenizer is used for the prompt)');
    }
    final tmpl = _loadTemplate(vocabGguf, template);
    try {
      _eventSub ??= _events.receiveBroadcastStream().listen((e) {
        if (e is Map) _bus.add(e);
      });
      final r = await _channel.invokeMapMethod<String, dynamic>('load', {'path': path, 'maxNumTokens': nCtx, 'cacheDir': cacheDir});
      _backend = (r?['backend'] as String?) ?? 'cpu';
    } on PlatformException catch (e) {
      tmpl.dispose();
      throw StateError(e.message ?? 'The LiteRT engine did not load the model');
    } on MissingPluginException {
      tmpl.dispose();
      throw StateError('This build has no LiteRT engine');
    }
    _tmpl = tmpl;
    final stem = path.split(RegExp(r'[\\/]')).last.replaceFirst(RegExp(r'\.litertlm$', caseSensitive: false), '');
    return ModelInfo(description: stem, nCtx: nCtx, chatFormat: 'litert', supportsTools: true);
  }

  Future<void> unload() async {
    final t = _tmpl;
    _tmpl = null;
    if (t == null) return;
    stop();
    try {
      await _channel.invokeMethod<void>('unload');
    } catch (_) {
      // The engine is gone with the app's process anyway.
    }
    t.dispose();
  }

  void stop() {
    if (_tmpl == null) return;
    unawaited(_channel.invokeMethod<void>('stop').then<void>((_) {}, onError: (Object _) {}));
  }

  /// Runs one generation: [request] is OpenAI style, as for the llama path. Emits the message parsed so far, then a final one.
  Stream<PartialMessage> generate(Map<String, dynamic> request) {
    final tmpl = _tmpl;
    if (tmpl == null) return Stream.error(StateError('No model is loaded'));
    if (_busy) return Stream.error(StateError('The model is already answering'));
    _busy = true;
    late StreamController<PartialMessage> c;
    var running = true;
    c = StreamController<PartialMessage>(onCancel: () {
      if (running) stop();
    });
    unawaited(() async {
      try {
        await _run(tmpl, request, c);
      } catch (e) {
        if (!c.isClosed) c.addError(e is StateError ? e : StateError(e.toString()));
      } finally {
        running = false;
        _busy = false;
        if (!c.isClosed) await c.close();
      }
    }());
    return c.stream;
  }

  Future<void> _run(ChatTemplate tmpl, Map<String, dynamic> request, StreamController<PartialMessage> c) async {
    final rendered = tmpl.render(request);
    final id = _nextId++;
    final max = request['max_tokens'];
    final temp = request['temperature'];
    final all = StringBuffer(); // everything fed to the parser
    var stopped = false;
    final done = Completer<Map<Object?, Object?>>();
    final sub = _bus.stream.listen((e) {
      if (e['id'] != id || done.isCompleted) return;
      if (e['error'] != null) {
        done.complete(e);
      } else if (e['done'] == true) {
        done.complete(e);
      } else if (e['chunk'] is String && !stopped && !c.isClosed) {
        var chunk = e['chunk'] as String;
        if (rendered.stopOnToolOpen) {
          final at = chunk.indexOf(toolOpen);
          if (at >= 0) {
            chunk = chunk.substring(0, at);
            stopped = true;
            stop();
          }
        }
        if (chunk.isNotEmpty) {
          all.write(chunk);
          c.add(tmpl.feed(chunk));
        }
      }
    });
    try {
      await _channel.invokeMethod<void>('generate', {
        'id': id,
        'prompt': rendered.prompt,
        'split': rendered.split,
        'maxTokens': max is int && max > 0 ? max : null,
        'temperature': temp is num ? temp.toDouble() : null,
      });
      final ev = await done.future;
      if (ev['error'] != null) throw StateError(ev['error'] as String);
      final reusedChars = (ev['reusedChars'] as int?) ?? 0;
      final fin = tmpl.finish();
      final text = all.toString();
      c.add(PartialMessage(
        content: fin.content,
        reasoning: fin.reasoning,
        toolCalls: fin.toolCalls,
        isFinal: true,
        parseError: fin.parseError,
        promptTokens: rendered.promptTokens,
        generatedTokens: tmpl.count(text),
        reusedTokens: reusedChars == 0 ? 0 : tmpl.count(rendered.prompt.substring(0, reusedChars)),
        startMs: ev['prefillMs'] as int?,
        firstTokenMs: (ev['firstTokenMs'] as int?) == -1 ? null : ev['firstTokenMs'] as int?,
        totalMs: ev['totalMs'] as int?,
        prefixNote: 'litert $_backend reused $reusedChars chars',
      ));
    } finally {
      await sub.cancel();
    }
  }
}

/// The [ModelBackend] of a .litertlm model. [extras] are the loaded model's own request settings, as for the llama backend.
class LiteRtBackend implements ModelBackend {
  LiteRtBackend(this.runtime, {this.extras});

  final LiteRtRuntime runtime;
  final Map<String, dynamic> Function()? extras;

  @override
  Stream<PartialMessage> generate(Map<String, dynamic> request) {
    final e = extras?.call();
    return runtime.generate(e == null || e.isEmpty ? request : {...e, ...request});
  }

  @override
  void stop() => runtime.stop();
}
