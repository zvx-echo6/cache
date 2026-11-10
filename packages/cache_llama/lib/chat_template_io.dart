import 'dart:convert';
import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'cache_llama_bindings.dart';
import 'partial_message.dart';

/// A rendered request: the prompt text (no leading BOS), its token count as the llama path counts it, and whether a tool-call
/// opening in the output ends the generation (tool_choice "none" with tools).
class RenderedPrompt {
  const RenderedPrompt({required this.prompt, required this.promptTokens, required this.stopOnToolOpen, this.split = 0});

  final String prompt;
  final int promptTokens;
  final bool stopOnToolOpen;

  /// Where the last control token starts in [prompt] (a token boundary), or 0 for none.
  final int split;
}

/// A chat template and tokenizer with no model behind them (cl_tmpl_*): renders a request's prompt and parses generated text into
/// an assistant message while another engine decodes. One request at a time. Native calls run on the calling isolate.
class ChatTemplate {
  ChatTemplate._(this._b, this._h);

  final CacheLlamaBindings _b;
  Pointer<Void> _h;

  static const int _errLen = 512;
  static const int _initialBuf = 256 * 1024;

  /// Loads the vocabulary of [ggufPath] and the chat template ([templateOverride], or the GGUF's own when null or empty).
  /// Throws a [StateError] with the reason on failure. [lib] is for tests that open the native library themselves.
  static ChatTemplate load(String ggufPath, {String? templateOverride, CacheLlamaBindings? lib}) {
    final b = lib ?? CacheLlamaBindings.open();
    final f = b.clTmplLoad;
    if (f == null) throw StateError('This native library has no template support');
    final err = malloc<Uint8>(_errLen).cast<Utf8>();
    final p = ggufPath.toNativeUtf8();
    final t = (templateOverride ?? '').toNativeUtf8();
    try {
      final h = f(p, t, err, _errLen);
      if (h == nullptr) throw StateError(err.toDartString());
      return ChatTemplate._(b, h);
    } finally {
      malloc.free(err);
      malloc.free(p);
      malloc.free(t);
    }
  }

  /// Calls a native function that writes JSON into a buffer, growing the buffer when it is too small.
  String _json(int Function(Pointer<Utf8> out, int len) call) {
    var size = _initialBuf;
    for (var i = 0; i < 6; i++) {
      final out = malloc<Uint8>(size).cast<Utf8>();
      try {
        final n = call(out, size);
        if (n >= 0) return out.toDartString();
      } finally {
        malloc.free(out);
      }
      size *= 4;
    }
    throw StateError('The template output is too large');
  }

  /// Renders [request] (OpenAI style, as for a llama generation) and starts its parser.
  RenderedPrompt render(Map<String, dynamic> request) {
    final f = _b.clTmplRender!;
    final req = jsonEncode(request).toNativeUtf8();
    try {
      final j = jsonDecode(_json((out, len) => f(_h, req, out, len))) as Map<String, dynamic>;
      if (j['error'] != null) throw StateError(j['error'] as String);
      return RenderedPrompt(
        prompt: j['prompt'] as String,
        promptTokens: j['prompt_tokens'] as int,
        stopOnToolOpen: j['stop_on_tool_open'] as bool,
        split: (j['split'] as int?) ?? 0,
      );
    } finally {
      malloc.free(req);
    }
  }

  PartialMessage _message(String json, {bool isFinal = false}) =>
      PartialMessage.fromJson(jsonDecode(json) as Map<String, dynamic>, isFinal: isFinal);

  /// Feeds generated text; the message parsed so far.
  PartialMessage feed(String chunk) {
    final f = _b.clTmplFeed!;
    final c = chunk.toNativeUtf8();
    try {
      return _message(_json((out, len) => f(_h, c, out, len)));
    } finally {
      malloc.free(c);
    }
  }

  /// Finishes the parse with the rest of the text; the final message (statistics are the caller's to add).
  PartialMessage finish([String rest = '']) {
    final f = _b.clTmplFinish!;
    final c = rest.toNativeUtf8();
    try {
      return _message(_json((out, len) => f(_h, c, out, len)), isFinal: true);
    } finally {
      malloc.free(c);
    }
  }

  /// Token count of [text] (special tokens parsed, no BOS).
  int count(String text) {
    final c = text.toNativeUtf8();
    try {
      return _b.clTmplCount!(_h, c);
    } finally {
      malloc.free(c);
    }
  }

  void dispose() {
    if (_h != nullptr) {
      _b.clTmplFree?.call(_h);
      _h = nullptr;
    }
  }
}
