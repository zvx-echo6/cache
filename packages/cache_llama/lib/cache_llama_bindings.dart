// Hand-written dart:ffi binding of the C API in src/cache_llama.h.
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

typedef _LoadC = Pointer<Void> Function(Pointer<Utf8>, Int32, Int32, Pointer<Utf8>, Int32);
typedef LlamaLoadCall = Pointer<Void> Function(Pointer<Utf8>, int, int, Pointer<Utf8>, int);
typedef _BufC = Int32 Function(Pointer<Void>, Pointer<Utf8>, Int32);
typedef LlamaBufferCall = int Function(Pointer<Void>, Pointer<Utf8>, int);
typedef _StartC = Int32 Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>, Int32);
typedef LlamaStartCall = int Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>, int);
typedef _IntHC = Int32 Function(Pointer<Void>);
typedef LlamaHandleIntCall = int Function(Pointer<Void>);
typedef _VoidHC = Void Function(Pointer<Void>);
typedef LlamaHandleVoidCall = void Function(Pointer<Void>);
typedef _ConfigureC = Int32 Function(Pointer<Utf8>);
typedef LlamaConfigureCall = int Function(Pointer<Utf8>);
typedef _EmbedC = Int32 Function(Pointer<Void>, Pointer<Utf8>, Pointer<Float>, Int32, Int32);
typedef LlamaEmbedCall = int Function(Pointer<Void>, Pointer<Utf8>, Pointer<Float>, int, int);
typedef _TmplLoadC = Pointer<Void> Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Int32);
typedef TmplLoadCall = Pointer<Void> Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, int);
typedef _TmplTextC = Int32 Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>, Int32);
typedef TmplTextCall = int Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>, int);
typedef _TmplCountC = Int32 Function(Pointer<Void>, Pointer<Utf8>);
typedef TmplCountCall = int Function(Pointer<Void>, Pointer<Utf8>);

/// Thin typed wrapper over the native library. Every method is a direct call.
class CacheLlamaBindings {
  CacheLlamaBindings(DynamicLibrary lib)
      : clLoad = lib.lookupFunction<_LoadC, LlamaLoadCall>('cl_load'),
        clInfo = lib.lookupFunction<_BufC, LlamaBufferCall>('cl_info'),
        clStart = lib.lookupFunction<_StartC, LlamaStartCall>('cl_start'),
        clNext = lib.lookupFunction<_BufC, LlamaBufferCall>('cl_next'),
        clPartial = lib.lookupFunction<_BufC, LlamaBufferCall>('cl_partial'),
        clFinish = lib.lookupFunction<_BufC, LlamaBufferCall>('cl_finish'),
        clPromptTokens = lib.lookupFunction<_IntHC, LlamaHandleIntCall>('cl_prompt_tokens'),
        clGeneratedTokens = lib.lookupFunction<_IntHC, LlamaHandleIntCall>('cl_generated_tokens'),
        clReusedTokens = lib.providesSymbol('cl_reused_tokens')
            ? lib.lookupFunction<_IntHC, LlamaHandleIntCall>('cl_reused_tokens')
            : null,
        clConfigure = lib.providesSymbol('cl_configure')
            ? lib.lookupFunction<_ConfigureC, LlamaConfigureCall>('cl_configure')
            : null,
        clPrefixNote = lib.providesSymbol('cl_prefix_note')
            ? lib.lookupFunction<_BufC, LlamaBufferCall>('cl_prefix_note')
            : null,
        clStop = lib.lookupFunction<_VoidHC, LlamaHandleVoidCall>('cl_stop'),
        clFree = lib.lookupFunction<_VoidHC, LlamaHandleVoidCall>('cl_free'),
        clFreeAll = lib.lookupFunction<Int32 Function(), int Function()>('cl_free_all'),
        clEmbedLoad = lib.lookupFunction<_LoadC, LlamaLoadCall>('cl_embed_load'),
        clEmbedInfo = lib.lookupFunction<_BufC, LlamaBufferCall>('cl_embed_info'),
        clEmbed = lib.lookupFunction<_EmbedC, LlamaEmbedCall>('cl_embed'),
        clEmbedFree = lib.lookupFunction<_VoidHC, LlamaHandleVoidCall>('cl_embed_free'),
        clTmplLoad = lib.providesSymbol('cl_tmpl_load') ? lib.lookupFunction<_TmplLoadC, TmplLoadCall>('cl_tmpl_load') : null,
        clTmplRender = lib.providesSymbol('cl_tmpl_render') ? lib.lookupFunction<_TmplTextC, TmplTextCall>('cl_tmpl_render') : null,
        clTmplFeed = lib.providesSymbol('cl_tmpl_feed') ? lib.lookupFunction<_TmplTextC, TmplTextCall>('cl_tmpl_feed') : null,
        clTmplFinish = lib.providesSymbol('cl_tmpl_finish') ? lib.lookupFunction<_TmplTextC, TmplTextCall>('cl_tmpl_finish') : null,
        clTmplCount = lib.providesSymbol('cl_tmpl_count') ? lib.lookupFunction<_TmplCountC, TmplCountCall>('cl_tmpl_count') : null,
        clTmplFree = lib.providesSymbol('cl_tmpl_free') ? lib.lookupFunction<_VoidHC, LlamaHandleVoidCall>('cl_tmpl_free') : null;

  /// Opens the native library of the current platform.
  factory CacheLlamaBindings.open() {
    final DynamicLibrary lib;
    if (Platform.isAndroid || Platform.isLinux) {
      lib = DynamicLibrary.open('libcache_llama.so');
    } else if (Platform.isIOS || Platform.isMacOS) {
      lib = DynamicLibrary.process();
    } else if (Platform.isWindows) {
      lib = DynamicLibrary.open('cache_llama.dll');
    } else {
      throw UnsupportedError('Unsupported platform: ${Platform.operatingSystem}');
    }
    return CacheLlamaBindings(lib);
  }

  final LlamaLoadCall clLoad;
  final LlamaBufferCall clInfo;
  final LlamaStartCall clStart;
  final LlamaBufferCall clNext;
  final LlamaBufferCall clPartial;
  final LlamaBufferCall clFinish;
  final LlamaHandleIntCall clPromptTokens;
  final LlamaHandleIntCall clGeneratedTokens;
  final LlamaHandleIntCall? clReusedTokens;

  /// Options for the next load (JSON: prefix_dir, repack_weights); null in an older library.
  final LlamaConfigureCall? clConfigure;

  /// What the last start did with the saved prompt prefix (one log line, or empty); null in an older library.
  final LlamaBufferCall? clPrefixNote;
  final LlamaHandleVoidCall clStop;
  final LlamaHandleVoidCall clFree;

  /// Frees every chat handle of the process not freed yet (one an earlier engine of the process left); how many.
  final int Function() clFreeAll;
  final LlamaLoadCall clEmbedLoad;
  final LlamaBufferCall clEmbedInfo;
  final LlamaEmbedCall clEmbed;
  final LlamaHandleVoidCall clEmbedFree;

  /// The template and parser without a chat model (cl_tmpl_*, for an engine that decodes elsewhere); null in an older library.
  final TmplLoadCall? clTmplLoad;
  final TmplTextCall? clTmplRender;
  final TmplTextCall? clTmplFeed;
  final TmplTextCall? clTmplFinish;
  final TmplCountCall? clTmplCount;
  final LlamaHandleVoidCall? clTmplFree;
}
