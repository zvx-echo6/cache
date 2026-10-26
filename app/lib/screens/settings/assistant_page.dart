import 'package:flutter/material.dart';

import '../../theme.dart';
import '../../video/format.dart';
import '../history_drawer.dart';
import '../models_screen.dart';
import 'deps.dart';
import 'key_sheet.dart';
import 'widgets.dart';

/// Settings > Assistant: the model, the web search service and its switch, and the saved conversations.
class AssistantPage extends StatelessWidget {
  const AssistantPage({super.key, required this.deps});

  final SettingsDeps deps;

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
    deps.chat.deleteAllConversations();
    say(context, 'All conversations deleted');
  }

  Future<void> _setUp(BuildContext context) async {
    final saved = await showAddKeySheet(
      context,
      title: 'Web search',
      gives: 'Kagi searches the web for the assistant when you are online, so it can answer questions your library cannot. '
          'It is a paid service and you need your own key.',
      getKeyLabel: 'Get a key from Kagi',
      getKeyUrl: 'https://kagi.com/api/keys',
      steps: const ['Sign in to Kagi and add search credit', 'Create a key on that page and copy it'],
      onSave: deps.hub.webSearch.saveKey,
      openUrl: deps.hub.openUrl,
      savedNote: 'Saving checks the key with one real web search and turns on web search. The key stays on this phone and isn\'t shown again.',
    );
    if (saved == true && context.mounted) say(context, 'Web search is on');
  }

  Future<void> _manage(BuildContext context) async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              key: const ValueKey('replace-key'),
              minTileHeight: 56,
              leading: const Icon(Icons.vpn_key_outlined),
              title: const Text('Replace the key', style: TextStyle(fontSize: 18)),
              onTap: () => Navigator.pop(ctx, 'replace'),
            ),
            ListTile(
              key: const ValueKey('remove-key'),
              minTileHeight: 56,
              leading: Icon(Icons.delete_outline, color: ctx.t.emergency),
              title: Text('Remove the key', style: TextStyle(fontSize: 18, color: ctx.t.emergency)),
              onTap: () => Navigator.pop(ctx, 'remove'),
            ),
          ],
        ),
      ),
    );
    if (!context.mounted || choice == null) return;
    if (choice == 'replace') {
      await _setUp(context);
    } else {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Remove the Kagi key?'),
          content: const Text('Web search turns off. You can add a key again later.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep')),
            TextButton(key: const ValueKey('confirm-remove-key'), onPressed: () => Navigator.pop(ctx, true), child: const Text('Remove')),
          ],
        ),
      );
      if (ok == true) {
        await deps.hub.webSearch.removeKey();
        if (context.mounted) say(context, 'Key removed');
      }
    }
  }

  void _openConversations(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => Scaffold(
          appBar: AppBar(title: const Text('Saved conversations')),
          body: HistoryDrawer(chat: deps.chat, width: double.infinity, onChosen: deps.onOpenAsk),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final app = deps.app;
    final web = deps.hub.webSearch;
    return ListenableBuilder(
      listenable: Listenable.merge([app, web, deps.chat.historyRevision]),
      builder: (context, _) {
        final m = app.active;
        final List<Part> modelStatus = app.loading != null
            ? const [Part('Loading…')]
            : m == null
            ? const [Part('No model chosen', Tone.warn)]
            : joinParts([
                const [Part('On this phone')],
                [Part(formatBytes(m.size))],
                const [Part('Ready', Tone.ok)],
              ]);
        final count = deps.chat.store?.list().length ?? 0;
        return SettingsPage(
          title: 'Assistant',
          children: [
            SettingsGroup(
              label: 'Model',
              rows: [
                SettingsRow(
                  title: m == null ? 'Choose a model' : app.displayName(m),
                  status: modelStatus,
                  onTap: () => openModels(context, app),
                ),
              ],
            ),
            SettingsGroup(
              label: 'Web search',
              rows: [
                SettingsRow(
                  title: 'Search service',
                  status: web.hasKey
                      ? joinParts(const [
                          [Part('Set up', Tone.ok)],
                          [Part('Kagi key saved on this phone')],
                        ])
                      : joinParts(const [
                          [Part('Not set up', Tone.warn)],
                          [Part('Kagi, paid, your own key')],
                        ]),
                  trailing: web.hasKey
                      ? RowButton(label: 'Change', onPressed: () => _manage(context))
                      : RowButton(label: 'Set up', onPressed: () => _setUp(context)),
                ),
                SwitchRow(
                  title: 'Search the web when online',
                  status: web.hasKey ? null : const [Part('Set up a search service to turn this on')],
                  value: web.active,
                  onChanged: web.hasKey ? (v) => web.setEnabled(v) : null,
                ),
              ],
            ),
            SettingsGroup(
              label: 'Conversations',
              rows: [
                SettingsRow(
                  title: 'Saved conversations',
                  status: [Part('$count on this phone')],
                  onTap: () => _openConversations(context),
                ),
                SettingsRow(
                  title: 'Delete all conversations',
                  status: const [Part("Asks first. This can't be undone.")],
                  danger: true,
                  chevron: false,
                  onTap: () => _deleteAll(context),
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}
