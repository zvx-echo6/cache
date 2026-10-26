import 'package:flutter/material.dart';

import '../../settings/data_policy.dart';
import '../../theme.dart';
import '../../weather/catalogue.dart';
import '../../weather/catalogue_store.dart';
import '../../weather/connector.dart';
import 'deps.dart';
import 'widgets.dart';

/// Settings > ... > Add sources from a link: the catalogues in use (the main one, whose address Advanced can change, and the ones
/// people added), and adding another from its address. A catalogue is shown, and every source in it checked, before anything is kept.
class CataloguesPage extends StatefulWidget {
  const CataloguesPage({super.key, required this.deps});

  final SettingsDeps deps;

  @override
  State<CataloguesPage> createState() => _CataloguesPageState();
}

class _CataloguesPageState extends State<CataloguesPage> {
  final _link = TextEditingController();
  LoadedCatalogue? _preview;
  String? _error;
  bool _busy = false;
  MobileDataBlocked? _blocked;

  @override
  void dispose() {
    _link.dispose();
    super.dispose();
  }

  Future<void> _check({bool anyway = false}) async {
    setState(() {
      _busy = true;
      _error = null;
      _preview = null;
      _blocked = null;
    });
    try {
      final p = await widget.deps.hub.weather.previewCatalogue(_link.text, anyway: anyway);
      if (mounted) setState(() => _preview = p);
    } on MobileDataBlocked catch (e) {
      if (mounted) setState(() => _blocked = e);
    } on CatalogueException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) setState(() => _error = "Couldn't check that link. Try again.");
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _add() async {
    final p = _preview;
    if (p == null) return;
    setState(() => _busy = true);
    await widget.deps.hub.weather.addCatalogue(p);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _preview = null;
      _link.clear();
    });
    say(context, '${p.catalogue.title} added');
  }

  Future<void> _remove(LoadedCatalogue c) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Remove ${c.catalogue.title}?'),
        content: const Text('Its sources are taken off this phone. You can add the link again later.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep')),
          TextButton(key: const ValueKey('confirm-remove-catalogue'), onPressed: () => Navigator.pop(ctx, true), child: const Text('Remove')),
        ],
      ),
    );
    if (ok != true) return;
    await widget.deps.hub.weather.removeCatalogue(c.url);
    if (mounted) say(context, 'Removed');
  }

  Future<void> _changeAddress() async {
    final w = widget.deps.hub.weather;
    final r = await showDialog<(String, String)>(context: context, builder: (_) => _AddressDialog(initial: w.catalogueUrl));
    if (r == null) return;
    if (r.$1 == 'save') {
      final u = Uri.tryParse(r.$2);
      if (u == null || !isAllowedAddress(u)) {
        if (mounted) say(context, 'Enter an address that starts with https://');
        return;
      }
    }
    await w.setCatalogueUrl(r.$1 == 'default' ? null : r.$2);
  }

  Future<void> _update({bool anyway = false}) async {
    final w = widget.deps.hub.weather;
    await w.refreshCatalogues(anyway: anyway);
    if (!mounted) return;
    final errs = w.catalogueErrors;
    say(context, errs.isEmpty ? 'Sources are up to date' : errs.values.first);
  }

  Widget _previewCard(BuildContext context, LoadedCatalogue p) {
    final k = context.t;
    final c = p.catalogue;
    final list = p.connectors;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: k.surface, borderRadius: BorderRadius.circular(16)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(c.title, key: const ValueKey('preview-title'), style: TextStyle(fontSize: 20, fontWeight: FontWeight.w500, color: k.text)),
          const SizedBox(height: 4),
          Text(
            [if (c.maintainer.isNotEmpty) 'From ${c.maintainer}', if (c.homepage.isNotEmpty) Uri.tryParse(c.homepage)?.host ?? ''].where((s) => s.isNotEmpty).join(' · '),
            style: TextStyle(fontSize: 14, color: k.secondary),
          ),
          const SizedBox(height: 12),
          Text('This adds ${list.length} ${list.length == 1 ? 'source' : 'sources'}. They stay off until you switch them on.', style: TextStyle(fontSize: 15, height: 1.4, color: k.text)),
          const SizedBox(height: 8),
          for (final s in list) _previewLine(k, s),
          if (p.skipped.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text('Left out (${p.skipped.length})', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: k.warning)),
            for (final e in p.skipped.entries)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text('${e.key}: ${e.value}', style: TextStyle(fontSize: 13, height: 1.4, color: k.secondary)),
              ),
          ],
          const SizedBox(height: 14),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: 10,
            children: [
              OutlinedButton(
                onPressed: _busy ? null : () => setState(() => _preview = null),
                style: OutlinedButton.styleFrom(minimumSize: const Size(0, 48), shape: const StadiumBorder(), foregroundColor: k.text, side: BorderSide(color: k.secondary.withValues(alpha: 0.6), width: 1.5)),
                child: const Text('Cancel', style: TextStyle(fontSize: 16)),
              ),
              FilledButton(
                key: const ValueKey('add-catalogue'),
                onPressed: _busy ? null : _add,
                style: FilledButton.styleFrom(minimumSize: const Size(0, 48), shape: const StadiumBorder()),
                child: const Text('Add these sources', style: TextStyle(fontSize: 16)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _previewLine(CacheTokens k, Connector s) => Padding(
    padding: const EdgeInsets.only(top: 6),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Text(
            [s.title, if (s.provider.isNotEmpty) s.provider, if (s.coverage.isNotEmpty) s.coverage, if (s.needsKey) 'needs your own key'].join(' · '),
            style: TextStyle(fontSize: 14, height: 1.35, color: k.secondary),
          ),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final d = widget.deps;
    final w = d.hub.weather;
    final k = context.t;
    return ListenableBuilder(
      listenable: w,
      builder: (context, _) {
        final byUrl = {for (final c in w.catalogues) c.url: c};
        return SettingsPage(
          title: 'Add sources from a link',
          children: [
            const NoteText('A catalogue is a list of data sources that someone publishes at a web address. Paste the link to see what it adds. Nothing is added until you say so.'),
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  key: const ValueKey('catalogue-link'),
                  controller: _link,
                  enabled: !_busy,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  enableSuggestions: false,
                  style: TextStyle(fontSize: 15, color: k.text, fontFamily: 'monospace'),
                  decoration: InputDecoration(
                    hintText: 'https://example.org/catalogue.json',
                    hintStyle: TextStyle(color: k.secondary),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: k.accent, width: 1.5)),
                    enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: k.accent, width: 1.5)),
                    focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: k.accent, width: 2)),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                  ),
                ),
                const SizedBox(height: 10),
                FilledButton(
                  key: const ValueKey('check-link'),
                  onPressed: _busy ? null : _check,
                  style: FilledButton.styleFrom(minimumSize: const Size(0, 48), shape: const StadiumBorder()),
                  child: _busy
                      ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.5))
                      : const Text('Check this link', style: TextStyle(fontSize: 16)),
                ),
              ],
            ),
            if (_error != null) Text(_error!, key: const ValueKey('link-error'), style: TextStyle(fontSize: 14, height: 1.4, color: k.emergency)),
            if (_blocked != null)
              Row(
                children: [
                  Expanded(child: Text(_blocked!.message, style: TextStyle(fontSize: 14, height: 1.4, color: k.warning))),
                  TextButton(onPressed: () => _check(anyway: true), child: const Text('Check anyway')),
                ],
              ),
            if (_preview != null) _previewCard(context, _preview!),
            SettingsGroup(
              label: 'Catalogues in use',
              rows: [
                for (final url in w.catalogueUrls)
                  () {
                    final c = byUrl[url];
                    final isMain = url == w.catalogueUrl;
                    final err = w.catalogueErrors[url];
                    return SettingsRow(
                      key: ValueKey('catalogue-$url'),
                      title: c?.catalogue.title ?? (isMain ? 'Cache connectors' : Uri.tryParse(url)?.host ?? url),
                      status: err != null
                          ? [Part(err, Tone.warn)]
                          : c == null
                          ? [const Part('Not downloaded yet', Tone.warn)]
                          : joinParts([
                              [Part('${c.connectors.length} ${c.connectors.length == 1 ? 'source' : 'sources'}')],
                              if (c.catalogue.updated.isNotEmpty) [Part('Updated ${c.catalogue.updated}')],
                              if (c.skipped.isNotEmpty) [Part('${c.skipped.length} left out', Tone.warn)],
                            ]),
                      trailing: isMain
                          ? RowButton(label: 'Address', onPressed: _changeAddress)
                          : RowButton(label: 'Remove', onPressed: c == null ? null : () => _remove(c)),
                      dim: false,
                    );
                  }(),
                SettingsRow(
                  key: const ValueKey('check-updates'),
                  title: 'Check for updates',
                  status: [Part(w.refreshingCatalogues ? 'Checking…' : 'Looks for new and changed sources')],
                  chevron: false,
                  onTap: w.refreshingCatalogues ? null : () => _update(),
                ),
              ],
            ),
            NoteText('Main catalogue: ${w.catalogueUrl}'),
          ],
        );
      },
    );
  }
}

/// Asks for the address of the main catalogue. Answers ("save", address) or ("default", ""), or nothing when cancelled.
class _AddressDialog extends StatefulWidget {
  const _AddressDialog({required this.initial});

  final String initial;

  @override
  State<_AddressDialog> createState() => _AddressDialogState();
}

class _AddressDialogState extends State<_AddressDialog> {
  late final TextEditingController _ctl = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Address of the main catalogue'),
    content: TextField(key: const ValueKey('catalogue-address'), controller: _ctl, keyboardType: TextInputType.url, autocorrect: false, style: const TextStyle(fontFamily: 'monospace', fontSize: 14)),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
      TextButton(onPressed: () => Navigator.pop(context, ('default', '')), child: const Text('Use the default')),
      TextButton(key: const ValueKey('save-address'), onPressed: () => Navigator.pop(context, ('save', _ctl.text.trim())), child: const Text('Save')),
    ],
  );
}
