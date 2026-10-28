import 'package:flutter/material.dart';

import '../../theme.dart';
import '../../weather/connector.dart';
import '../../weather/words.dart';
import 'catalogues_page.dart';
import 'deps.dart';
import 'keys_page.dart';
import 'source_page.dart';
import 'widgets.dart';

/// Settings > Weather and alerts > Advanced > All data sources: every source there is, searchable, grouped as the main page is.
class DataSourcesPage extends StatefulWidget {
  const DataSourcesPage({super.key, required this.deps});

  final SettingsDeps deps;

  @override
  State<DataSourcesPage> createState() => _DataSourcesPageState();
}

class _DataSourcesPageState extends State<DataSourcesPage> {
  final _query = TextEditingController();
  String _q = '';

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  bool _matches(Connector c) {
    if (_q.isEmpty) return true;
    final hay = '${c.title} ${c.provider} ${c.description} ${c.category} ${c.coverage}'.toLowerCase();
    return _q.toLowerCase().split(RegExp(r'\s+')).every(hay.contains);
  }

  Widget _row(BuildContext context, Connector c) {
    final d = widget.deps;
    return SettingsRow(
      key: ValueKey('source-${c.id}'),
      title: c.title,
      status: joinParts([
        if (c.provider.isNotEmpty) [Part(c.provider)],
        [Part(everyWords(c.refreshMinutes))],
      ]),
      onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => SourcePage(deps: d, sourceId: c.id))),
    );
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.deps;
    final w = d.hub.weather;
    final k = context.t;
    return ListenableBuilder(
      listenable: Listenable.merge([w, d.hub.settings]),
      builder: (context, _) {
        final all = w.sources;
        final shown = [for (final c in all) if (_matches(c)) c];
        final on = [for (final c in shown) if (w.isOn(c.id)) c];
        final free = [for (final c in shown) if (!w.isOn(c.id) && !c.needsKey) c];
        final keyed = [for (final c in shown) if (!w.isOn(c.id) && c.needsKey) c];
        final saved = w.savedKeyAliases.length;
        final errors = w.catalogueErrors.values.toList();
        return SettingsPage(
          title: 'All data sources',
          children: [
            TextField(
              key: const ValueKey('search-sources'),
              controller: _query,
              onChanged: (v) => setState(() => _q = v.trim()),
              textInputAction: TextInputAction.search,
              style: TextStyle(fontSize: 16, color: k.text),
              decoration: InputDecoration(
                hintText: 'Search ${all.length} ${all.length == 1 ? 'source' : 'sources'}',
                hintStyle: TextStyle(color: k.secondary),
                prefixIcon: Icon(Icons.search, color: k.secondary),
                suffixIcon: _q.isEmpty
                    ? null
                    : IconButton(
                        tooltip: 'Clear',
                        icon: const Icon(Icons.close),
                        onPressed: () {
                          _query.clear();
                          setState(() => _q = '');
                        },
                      ),
                filled: true,
                fillColor: k.surface,
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none),
              ),
            ),
            if (all.isEmpty)
              NoteText(w.refreshingCatalogues ? 'Loading sources…' : 'No sources downloaded yet. Connect to the internet and they load by themselves.')
            else if (shown.isEmpty)
              const NoteText('No source matches your search.'),
            if (on.isNotEmpty) SettingsGroup(label: 'On', rows: [for (final c in on) _row(context, c)]),
            if (free.isNotEmpty) SettingsGroup(label: 'Free', rows: [for (final c in free) _row(context, c)]),
            if (keyed.isNotEmpty) SettingsGroup(label: 'Needs your own key', rows: [for (final c in keyed) _row(context, c)]),
            if (errors.isNotEmpty) NoteText(errors.first),
            SettingsGroup(
              rows: [
                SettingsRow(
                  title: 'Manage keys',
                  status: [Part(saved == 0 ? 'None saved on this phone' : '$saved saved on this phone')],
                  onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => KeysPage(deps: d))),
                ),
                SettingsRow(
                  title: 'Add sources from a link',
                  status: const [Part('Sources other people publish')],
                  onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => CataloguesPage(deps: d))),
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}
