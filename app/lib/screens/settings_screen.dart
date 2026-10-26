import 'package:flutter/material.dart';

import '../app_state.dart';
import '../chat/chat_controller.dart';
import '../sources/sources_state.dart';
import '../theme.dart';
import 'models_screen.dart';
import 'sources_screen.dart';

/// Settings. Technical settings sit behind Advanced, closed by default.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key, required this.app, required this.chat, required this.sources});

  final AppState app;
  final ChatController chat;
  final SourcesState sources;

  Future<void> _pickTheme(BuildContext context) async {
    final chosen = await showDialog<CacheThemeId>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Theme'),
        children: [
          for (final id in CacheThemeId.values)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, id),
              padding: EdgeInsets.zero,
              child: ListTile(
                minTileHeight: 56,
                leading: Icon(id == app.theme ? Icons.radio_button_checked : Icons.radio_button_off, color: ctx.t.accent),
                title: Text(id.label, style: const TextStyle(fontSize: 18)),
                subtitle: Text(id.hint),
              ),
            ),
        ],
      ),
    );
    if (chosen != null) app.setTheme(chosen);
  }

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
          ListenableBuilder(
            listenable: Listenable.merge([app, sources]),
            builder: (context, _) => Column(
              children: [
                ListTile(
                  minTileHeight: 56,
                  leading: const Icon(Icons.palette_outlined),
                  title: const Text('Theme', style: TextStyle(fontSize: 18)),
                  subtitle: Text(app.theme.label),
                  onTap: () => _pickTheme(context),
                ),
                ListTile(
                  minTileHeight: 56,
                  leading: const Icon(Icons.memory),
                  title: const Text('Model', style: TextStyle(fontSize: 18)),
                  subtitle: Text(app.loading != null
                      ? 'Loading…'
                      : app.active == null
                          ? 'No model'
                          : app.displayName(app.active!)),
                  onTap: () => openModels(context, app),
                ),
                ListTile(
                  minTileHeight: 56,
                  leading: const Icon(Icons.menu_book_outlined),
                  title: const Text('Reading sources', style: TextStyle(fontSize: 18)),
                  subtitle: Text(sources.summary),
                  onTap: () {
                    sources.refresh();
                    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => SourcesScreen(sources: sources)));
                  },
                ),
              ],
            ),
          ),
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
