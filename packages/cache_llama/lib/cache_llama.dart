/// Cache native LLM layer: llama.cpp with its chat engine, behind a small Dart API.
library;

export 'llama_session.dart' show LlamaSession;
export 'partial_message.dart' show PartialMessage, ModelInfo, ToolCall;
export 'embedder.dart' show CacheEmbedder;
export 'embed_remote.dart' show EmbedHttp, EmbedRemoteException, ServerEmbedderState, ServerEmbedderStatus, embedRemote;
export 'load_options.dart' show llamaLoadOptions;
