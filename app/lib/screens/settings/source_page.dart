import 'package:flutter/material.dart';

import '../../theme.dart';
import '../../weather/weather_state.dart';
import '../../weather/words.dart';
import 'deps.dart';
import 'weather_page.dart' show addKeyFor;
import 'widgets.dart';

/// One data source: what it gives, who provides it, how often it updates, how old the copy on this phone is, and its switch (or the
/// button for its key).
class SourcePage extends StatefulWidget {
  const SourcePage({super.key, required this.deps, required this.sourceId});

  final SettingsDeps deps;
  final String sourceId;

  @override
  State<SourcePage> createState() => _SourcePageState();
}

class _SourcePageState extends State<SourcePage> {
  SourceInfo? _info;

  WeatherState get w => widget.deps.hub.weather;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final c = w.sourceById(widget.sourceId);
    if (c == null) return;
    final i = await w.infoFor(c);
    if (mounted) setState(() => _info = i);
  }

  /// Forgets the key after a confirm; the sources that need it turn off.
  Future<void> _removeKey(String alias) async {
    final users = w.sourcesUsingKey(alias);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove the key?'),
        content: Text(users.isEmpty ? 'You can add a key again later.' : '${users.map((c) => c.title).join(' and ')} turns off. You can add a key again later.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep')),
          TextButton(key: const ValueKey('confirm-remove-key'), onPressed: () => Navigator.pop(ctx, true), child: const Text('Remove')),
        ],
      ),
    );
    if (ok != true) return;
    await w.removeKey(alias);
    if (mounted) say(context, 'Key removed');
  }

  SettingsRow _fact(String title, String value, {Tone tone = Tone.normal}) => SettingsRow(title: title, status: [Part(value, tone)], chevron: false, statusLines: null);

  @override
  Widget build(BuildContext context) {
    final d = widget.deps;
    return ListenableBuilder(
      listenable: Listenable.merge([w, d.hub.settings]),
      builder: (context, _) {
        final c = w.sourceById(widget.sourceId);
        if (c == null) {
          return const SettingsPage(title: 'Data source', children: [NoteText('This source is no longer in the catalogue.')]);
        }
        final i = _info;
        final on = w.isOn(c.id);
        final hasKey = c.keyAlias != null && w.hasKey(c.keyAlias!);
        return SettingsPage(
          title: c.title,
          children: [
            if (c.description.isNotEmpty) NoteText(c.description),
            SettingsGroup(
              rows: [
                if (c.needsKey && !hasKey)
                  SettingsRow(
                    title: 'Needs your own key',
                    status: [Part(c.provider.isEmpty ? 'A free key switches this on' : 'A free key from ${c.provider}')],
                    trailing: RowButton(label: 'Get key', onPressed: () => addKeyFor(context, d, c)),
                  )
                else
                  SwitchRow(title: 'Use this source', status: [Part(on ? 'On' : 'Off', on ? Tone.ok : Tone.normal)], value: on, onChanged: (v) async {
                    await w.setSourceOn(c, v);
                    _load();
                  }),
                if (hasKey) ...[
                  SettingsRow(
                    title: 'Key',
                    status: const [Part('Saved on this phone, not shown again')],
                    trailing: RowButton(label: 'Replace', onPressed: () => addKeyFor(context, d, c, replace: true)),
                  ),
                  SettingsRow(key: const ValueKey('remove-key'), title: 'Remove the key', danger: true, chevron: false, onTap: () => _removeKey(c.keyAlias!)),
                ],
              ],
            ),
            SettingsGroup(
              label: 'About this source',
              rows: [
                if (c.provider.isNotEmpty) _fact('Provider', c.provider),
                if (c.coverage.isNotEmpty) _fact('Covers', c.coverage),
                _fact('Updates', '${everyWords(c.refreshMinutes)[0].toUpperCase()}${everyWords(c.refreshMinutes).substring(1)}'),
                if (c.attribution.isNotEmpty) _fact('Credit', c.attribution),
                if (c.license.isNotEmpty) _fact('Licence', c.license),
                _fact('From', c.origin.catalogueTitle),
              ],
            ),
            SettingsGroup(
              label: 'On this phone',
              rows: [
                _fact('Last update', i == null ? '…' : (i.age == null ? 'Nothing downloaded yet' : i.age!)),
                if (i?.age != null) _fact('Data', i!.expired ? 'Out of date' : 'Current', tone: i.expired ? Tone.warn : Tone.ok),
                if (i?.lastError != null) _fact('Last problem', i!.lastError!, tone: Tone.warn),
              ],
            ),
            if (c.docs != null)
              SettingsGroup(
                rows: [
                  SettingsRow(title: "The provider's documentation", status: [Part(Uri.parse(c.docs!).host)], onTap: () => d.hub.openUrl(c.docs!), trailing: Icon(Icons.open_in_new, size: 20, color: context.t.secondary)),
                ],
              ),
          ],
        );
      },
    );
  }
}
