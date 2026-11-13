import 'dart:io' show Directory;

import '../app_fs.dart';

import 'conversation_store.dart';

/// The conversations live in the app's private storage (the phone's own SQLite file, in the support folder).
Future<ConversationStore> openHistoryStore({void Function()? onChanged}) async {
  final dir = Directory(await appSupportPath());
  await dir.create(recursive: true);
  return ConversationStore.open('${dir.path}/conversations.db');
}
