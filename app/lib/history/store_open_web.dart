import 'package:cache_search/cache_search.dart' show HttpTransport;

import 'conversation_store.dart';
import 'server_conversation_store.dart';

/// In a browser the conversations are kept on Cache for Linux (the helper's `history.*` ops), so they are the same in every tab
/// and browser and stay when the page closes. [onChanged] runs when another tab or browser changed them. The first sync is tried
/// a few times (the helper may still be starting). If it still fails, that is logged and the session goes on with its own chats:
/// they queue, and the first later sync that works loads the server's history and sends them, so nothing written is lost.
Future<ConversationStore> openHistoryStore({void Function()? onChanged}) {
  return ServerConversationStore.open(HttpTransport(), onChanged: onChanged, attempts: 4, keepOnFailure: true);
}
