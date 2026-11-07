import 'package:path_provider/path_provider.dart';

import 'conversation_store.dart';

/// The conversations live in the app's private storage (the phone's own SQLite file, in the support folder).
Future<ConversationStore> openHistoryStore() async {
  final dir = await getApplicationSupportDirectory();
  await dir.create(recursive: true);
  return ConversationStore.open('${dir.path}/conversations.db');
}
