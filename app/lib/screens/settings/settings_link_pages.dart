import 'package:flutter/material.dart';

import '../../sharing/settings_sync.dart';
import '../../theme.dart';
import 'widgets.dart';

/// A linked device's page, its Settings section: how settings go between the two (Match, Send mine, Off), then What's included
/// and API keys while they go. The device it is chosen on is where settings come from. On the device that follows the other's
/// settings, the middle choice says so ("Follows Desk's settings").
class DeviceSettingsSection extends StatelessWidget {
  const DeviceSettingsSection({super.key, required this.sync, required this.peer, required this.name, this.known = true, this.busy = false});

  final SettingsSync sync;
  final String peer;
  final String name;

  /// The other device has this version (it keeps links); until then this one's choice waits for it.
  final bool known;
  final bool busy;

  Future<void> _pick(BuildContext context, SettingsLink to) async {
    try {
      await sync.setLink(peer, to);
    } catch (e) {
      if (context.mounted) say(context, '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: sync,
      builder: (context, _) {
        final k = context.t;
        final link = sync.linkWith(peer);
        final receiving = link == SettingsLink.receiving;
        Widget choice(String id, SettingsLink value, String title, String text, {bool on = false}) {
          final selected = on || link == value;
          return SettingsRow(
            key: ValueKey('link-$id'),
            title: title,
            status: [Part(text)],
            statusLines: null,
            leading: Icon(selected ? Icons.radio_button_checked : Icons.radio_button_off, color: selected ? k.accent : k.secondary),
            chevron: false,
            onTap: busy || selected ? null : () => _pick(context, value),
          );
        }

        final groups = sync.groupsOn(peer);
        final total = SettingsGroupId.values.length;
        final keys = sync.keys();
        final keysOn = sync.keysOn(peer);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const GroupLabel('Settings'),
            SettingsGroup(
              rows: [
                choice('match', SettingsLink.match, 'Match', 'Changes on either device go to both.'),
                if (receiving)
                  choice('send', SettingsLink.sending, "Follows $name's settings", 'Changes on $name come here. Changes you make here stay here.', on: true)
                else
                  choice('send', SettingsLink.sending, 'Send mine', '$name follows my settings. Its own changes stay on $name.'),
                choice('off', SettingsLink.off, 'Off', 'Each keeps its own.'),
                if (link != SettingsLink.off) ...[
                  SettingsRow(
                    key: const ValueKey('link-included'),
                    icon: Icons.tune,
                    title: "What's included",
                    status: [Part(groups == total ? '$total groups of settings' : (groups == 0 ? 'Nothing included' : '$groups of $total groups'))],
                    onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => WhatsIncludedPage(sync: sync, peer: peer, name: name))),
                  ),
                  if (!receiving)
                    SettingsRow(
                      key: const ValueKey('link-keys'),
                      icon: Icons.key_outlined,
                      title: 'API keys',
                      status: [Part(keys.isEmpty ? 'No keys saved here' : (keysOn == 0 ? 'None included' : '$keysOn of ${keys.length} included'))],
                      onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ApiKeysPage(sync: sync, peer: peer, name: name))),
                    ),
                ],
              ],
            ),
            if (!known) ...[const SizedBox(height: 8), NoteText('Settings go once $name has this version of Cache.')],
          ],
        );
      },
    );
  }
}

/// Asked once, right after a new link: how settings go between this device and [name] ([SettingsSync.answer]). Until it is
/// answered nothing goes; closing it is Off, unless the other device has answered meanwhile.
Future<void> askSettingsLink(BuildContext context, SettingsSync sync, String peer, String name) async {
  final to = await showDialog<SettingsLink>(
    context: context,
    builder: (ctx) {
      Widget choice(String id, SettingsLink value, IconData icon, String title, String text) => SettingsRow(
        key: ValueKey('ask-$id'),
        icon: icon,
        title: title,
        status: [Part(text)],
        statusLines: null,
        chevron: false,
        onTap: () => Navigator.pop(ctx, value),
      );
      return AlertDialog(
        key: const ValueKey('ask-settings-link'),
        title: Text('Sync Cache settings with $name?'),
        contentPadding: const EdgeInsets.fromLTRB(16, 16, 16, 20),
        content: SizedBox(
          width: 400,
          child: SingleChildScrollView(
            child: SettingsGroup(
              rows: [
                choice('match', SettingsLink.match, Icons.sync, 'Match', 'Changes on either device go to both.'),
                choice('send', SettingsLink.sending, Icons.north_east, 'Send mine', '$name follows my settings.'),
                choice('off', SettingsLink.off, Icons.block, 'Off', "Each keeps its own. You can change this on $name's page."),
              ],
            ),
          ),
        ),
      );
    },
  );
  try {
    await sync.answer(peer, to);
  } catch (e) {
    if (context.mounted) say(context, '$e');
  }
}

/// "Theme, module icons, dark PDF pages", "2 of 3 settings", "Not included".
List<Part> groupSummary(SettingsSync sync, String peer, SettingsGroupId g) {
  final all = sync.settingsOf(g);
  final on = all.where((s) => sync.settingOn(peer, s.key)).length;
  if (!sync.groupOn(peer, g) || on == 0) return const [Part('Not included', Tone.quiet)];
  if (on == all.length) return [Part(g.summary)];
  return [Part('$on of ${all.length} settings')];
}

/// Settings > Sharing and sync > a device > What's included: six groups, each with its switch and a page for its single
/// settings, and what is never synced.
class WhatsIncludedPage extends StatelessWidget {
  const WhatsIncludedPage({super.key, required this.sync, required this.peer, required this.name});

  final SettingsSync sync;
  final String peer;
  final String name;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: sync,
      builder: (context, _) {
        final k = context.t;
        return SettingsPage(
          title: "What's included",
          children: [
            SettingsGroup(
              rows: [
                for (final g in SettingsGroupId.values)
                  SettingsRow(
                    key: ValueKey('group-${g.name}'),
                    title: g.label,
                    status: groupSummary(sync, peer, g),
                    chevron: false,
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.chevron_right, color: k.secondary.withValues(alpha: 0.8)),
                        const SizedBox(width: 10),
                        Switch(
                          value: sync.groupOn(peer, g) && sync.settingsOf(g).any((s) => sync.settingOn(peer, s.key)),
                          onChanged: (v) => sync.setGroupOn(peer, g, v),
                        ),
                      ],
                    ),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(builder: (_) => SettingsGroupPage(sync: sync, peer: peer, name: name, group: g)),
                    ),
                  ),
              ],
            ),
            Material(
              key: const ValueKey('never-synced'),
              color: k.surface,
              borderRadius: BorderRadius.circular(16),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Never synced', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500, color: k.text)),
                    const SizedBox(height: 4),
                    Text(kNeverSynced, style: TextStyle(fontSize: 14, height: 1.35, color: k.secondary)),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// One group's settings, each ticked on its own. A model the other device uses that is not here says so, with Download (it
/// never downloads on its own); a watched place that has not come yet says "waiting for this place".
class SettingsGroupPage extends StatefulWidget {
  const SettingsGroupPage({super.key, required this.sync, required this.peer, required this.name, required this.group});

  final SettingsSync sync;
  final String peer;
  final String name;
  final SettingsGroupId group;

  @override
  State<SettingsGroupPage> createState() => _SettingsGroupPageState();
}

class _SettingsGroupPageState extends State<SettingsGroupPage> {
  SettingsSync get sync => widget.sync;
  Set<String>? _placesHere;

  @override
  void initState() {
    super.initState();
    if (widget.group == SettingsGroupId.weather) {
      sync.placesHere?.call().then((p) {
        if (mounted) setState(() => _placesHere = p);
      }).catchError((Object _) {});
    }
  }

  List<Part> _status(SyncedSetting s) {
    final shows = s.shows?.call() ?? '';
    if (s.key == kModelSettingKey) {
      final w = sync.waiting(s.key);
      if (w != null) return [Part('Uses ${waitingModelName(w)}, not downloaded here', Tone.warn)];
    }
    if (s.key == kWatchPlacesKey) {
      final missing = sync.placesNotHere(_placesHere);
      if (missing.isNotEmpty) return [Part(shows), Part(' · ${missing.join(', ')}: waiting for this place', Tone.warn)];
    }
    return [Part(shows)];
  }

  @override
  Widget build(BuildContext context) {
    final g = widget.group;
    return ListenableBuilder(
      listenable: Listenable.merge([sync, for (final s in sync.settingsOf(g)) s.listenable]),
      builder: (context, _) {
        final on = sync.groupOn(widget.peer, g) && sync.settingsOf(g).any((s) => sync.settingOn(widget.peer, s.key));
        return SettingsPage(
          title: g.label,
          children: [
            SettingsGroup(
              rows: [
                SettingsRow(
                  key: const ValueKey('group-switch'),
                  title: 'Include ${g.label}',
                  status: groupSummary(sync, widget.peer, g),
                  trailing: Switch(value: on, onChanged: (v) => sync.setGroupOn(widget.peer, g, v)),
                  onTap: () => sync.setGroupOn(widget.peer, g, !on),
                ),
              ],
            ),
            SettingsGroup(
              label: 'Settings',
              rows: [
                for (final s in sync.settingsOf(g))
                  SettingsRow(
                    key: ValueKey('setting-${s.key}'),
                    title: s.label,
                    status: _status(s),
                    statusLines: null,
                    onTap: () => sync.setSettingOn(widget.peer, s.key, !sync.settingOn(widget.peer, s.key)),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (s.key == kModelSettingKey && sync.waiting(s.key) != null && sync.downloadModel != null)
                          Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: RowButton(
                              key: const ValueKey('model-download'),
                              label: 'Download',
                              onPressed: waitingModelDownload(sync.waiting(s.key)!) == null
                                  ? null
                                  : () async {
                                      try {
                                        await sync.downloadModel!(waitingModelDownload(sync.waiting(s.key)!)!);
                                        if (context.mounted) say(context, 'Downloading ${waitingModelName(sync.waiting(s.key)!)}');
                                      } catch (e) {
                                        if (context.mounted) say(context, '$e');
                                      }
                                    },
                            ),
                          ),
                        Switch(value: sync.settingOn(widget.peer, s.key), onChanged: (v) => sync.setSettingOn(widget.peer, s.key, v)),
                      ],
                    ),
                  ),
              ],
            ),
          ],
        );
      },
    );
  }
}

/// Settings > Sharing and sync > a device > API keys: each key saved here, ticked on its own (all off at first).
class ApiKeysPage extends StatelessWidget {
  const ApiKeysPage({super.key, required this.sync, required this.peer, required this.name});

  final SettingsSync sync;
  final String peer;
  final String name;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: sync,
      builder: (context, _) {
        final keys = sync.keys();
        return SettingsPage(
          title: 'API keys',
          children: [
            if (keys.isEmpty)
              const NoteText('No keys are saved on this device.')
            else
              SettingsGroup(
                rows: [
                  for (final key in keys)
                    SwitchRow(
                      key: ValueKey('key-${key.name}'),
                      title: key.label,
                      value: sync.keyOn(peer, key.name),
                      onChanged: (v) => sync.setKeyOn(peer, key.name, v),
                    ),
                ],
              ),
            NoteText(
              'A key you tick goes to $name alone, encrypted for it, and is kept in its secure storage. Keys are never written to a '
              'synced folder.',
            ),
          ],
        );
      },
    );
  }
}
