import 'conversation_store.dart';
import 'memory_conversation_store.dart';

/// In a browser the conversations are kept in memory for now (the server will keep them in a later step): the store starts empty
/// and keeps nothing once the page closes.
Future<ConversationStore> openHistoryStore() async => MemoryConversationStore();
