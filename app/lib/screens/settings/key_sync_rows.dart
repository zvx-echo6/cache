import 'package:flutter/material.dart';

import '../../settings/api_keys.dart';
import '../../sharing/settings_sync.dart';
import '../../theme.dart';
import 'deps.dart';

/// "Shared with" in an open key row: each linked device that takes this key, from the same switches as Sharing and sync > a device >
/// API keys (one state, two views). Nothing is listed where there is no sync or the key cannot sync.
List<Widget> keySharedWithRows(BuildContext context, SettingsDeps deps, KeyProvider p) {
  final sync = deps.hub.settingsSync;
  final sharing = deps.hub.sharing;
  if (sync == null || sharing == null || !p.canSync) return const [];
  final k = context.t;
  final name = p.kind == KeyKind.kagi ? kKagiKeyName : p.storageName;
  final peers = [for (final x in sharing.peers) if (x['id'] is String) (x['id'] as String, '${x['name'] ?? 'Linked device'}')];
  return [
    Padding(padding: const EdgeInsets.only(top: 12, bottom: 4), child: Text('SHARED WITH', style: TextStyle(fontSize: 12, letterSpacing: 0.6, color: k.secondary, fontWeight: FontWeight.w600))),
    if (peers.isEmpty) Text('No linked devices', style: TextStyle(fontSize: 14, color: k.secondary)),
    for (final (id, device) in peers)
      Row(
        children: [
          Expanded(child: Text(device, style: TextStyle(fontSize: 14, color: k.text))),
          Switch(
            key: ValueKey('shared-${p.id}-$id'),
            value: sync.includeKeys(id) && sync.keyOn(id, name),
            onChanged: sync.includeKeys(id) ? (v) => sync.setKeyOn(id, name, v) : null,
          ),
        ],
      ),
    if (peers.isNotEmpty && peers.any((x) => !sync.includeKeys(x.$1)))
      Text('Turn on Include API keys under Sharing and sync to share.', style: TextStyle(fontSize: 12, color: k.secondary)),
  ];
}
