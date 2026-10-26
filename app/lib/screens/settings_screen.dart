import 'package:flutter/material.dart';

import '../chat/chat_controller.dart';
import '../theme.dart';

/// Settings. Technical settings sit behind Advanced, closed by default.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key, required this.chat});

  final ChatController chat;

  Future<void> _deleteAll(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete all conversations?'),
        content: const Text('Every saved chat is removed from this phone. This cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Delete all', style: TextStyle(color: ctx.t.emergency)),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    chat.deleteAllConversations();
    final m = ScaffoldMessenger.of(context);
    m.hideCurrentSnackBar();
    m.showSnackBar(const SnackBar(content: Text('All conversations deleted')));
  }

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          Theme(
            data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
            child: ExpansionTile(
              title: const Text('Advanced', style: TextStyle(fontSize: 18)),
              children: [
                ListTile(
                  minTileHeight: 56,
                  leading: Icon(Icons.delete_outline, color: k.emergency),
                  title: Text('Delete all conversations', style: TextStyle(fontSize: 18, color: k.emergency)),
                  subtitle: const Text('Removes every saved chat from this phone'),
                  onTap: () => _deleteAll(context),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
