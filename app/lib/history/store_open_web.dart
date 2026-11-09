import 'package:cache_search/cache_search.dart' show HttpTransport;

import 'conversation_store.dart';
import 'memory_conversation_store.dart';
import 'server_conversation_store.dart';

/// In a browser the conversations are kept on Cache for Linux (the helper's `history.*` ops), so they are the same in every tab
/// and browser and stay when the page closes. [onChanged] runs when another tab or browser changed them. If the server cannot be
/// reached when the page opens, this session keeps them in memory only.
Future<ConversationStore> openHistoryStore({void Function()? onChanged}) async {
  try {
    return await ServerConversationStore.open(HttpTransport(), onChanged: onChanged);
  } catch (_) {
    return MemoryConversationStore();
  }
}
