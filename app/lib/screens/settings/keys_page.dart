import 'package:flutter/material.dart';

import '../../theme.dart';
import 'deps.dart';
import 'weather_page.dart' show addKeyFor;
import 'widgets.dart';

/// Settings > ... > Manage keys: the keys saved on this phone for data sources, to replace or remove. A key is never shown.
class KeysPage extends StatelessWidget {
  const KeysPage({super.key, required this.deps});

  final SettingsDeps deps;

  Future<void> _change(BuildContext context, String alias, String name) async {
    final w = deps.hub.weather;
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
      final users = w.sourcesUsingKey(alias);
      if (users.isNotEmpty) await addKeyFor(context, deps, users.first, replace: true);
      return;
    }
    final users = w.sourcesUsingKey(alias);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Remove the $name key?'),
        content: Text(users.isEmpty ? 'You can add a key again later.' : '${users.map((c) => c.title).join(' and ')} turns off. You can add a key again later.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep')),
          TextButton(key: const ValueKey('confirm-remove-key'), onPressed: () => Navigator.pop(ctx, true), child: const Text('Remove')),
        ],
      ),
    );
    if (ok == true) {
      await w.removeKey(alias);
      if (context.mounted) say(context, 'Key removed');
    }
  }

  @override
  Widget build(BuildContext context) {
    final w = deps.hub.weather;
    return ListenableBuilder(
      listenable: w,
      builder: (context, _) {
        final aliases = w.savedKeyAliases;
        return SettingsPage(
          title: 'Manage keys',
          children: [
            if (aliases.isEmpty)
              const NoteText('No keys are saved on this phone. A source that needs one asks for it when you switch it on.')
            else
              SettingsGroup(
                rows: [
                  for (final a in aliases)
                    () {
                      final users = w.sourcesUsingKey(a);
                      final name = users.isEmpty || users.first.provider.isEmpty ? a : users.first.provider;
                      return SettingsRow(
                        key: ValueKey('key-$a'),
                        title: '$name key',
                        status: [Part(users.isEmpty ? 'Saved on this phone' : 'Used by ${users.map((c) => c.title).join(', ')}')],
                        trailing: RowButton(label: 'Change', onPressed: () => _change(context, a, name)),
                      );
                    }(),
                ],
              ),
            const NoteText('Keys stay on this phone, in its secure storage. They are never shown again.'),
          ],
        );
      },
    );
  }
}
