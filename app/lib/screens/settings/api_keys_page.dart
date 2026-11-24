import 'package:flutter/material.dart';

import '../../settings/api_keys.dart';
import '../../theme.dart';
import '../../weather/words.dart';
import 'deps.dart';
import 'key_sync_rows.dart';
import 'key_sheet.dart';
import 'widgets.dart';

/// Settings > API keys: the one place a key is added, replaced, tested or removed. "Your keys" (saved) and "Keys Cache can use" (not set
/// yet) are made from the key registry ([ApiKeys.providers]). A row opens in place with its status, Replace, Test key, Used by, Shared
/// with, About and Remove. Removing a key turns nothing off.
class ApiKeysScreen extends StatefulWidget {
  const ApiKeysScreen({super.key, required this.deps, this.openId});

  final SettingsDeps deps;

  /// Scroll to this provider and open it (a shortcut row in a module); null: the plain list.
  final String? openId;

  @override
  State<ApiKeysScreen> createState() => _ApiKeysScreenState();
}

/// Pushes the master list at [providerId] (scrolled to it, open, tinted); Back returns to where it was pushed from.
Future<void> openApiKeys(BuildContext context, SettingsDeps deps, {String? providerId}) =>
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ApiKeysScreen(deps: deps, openId: providerId)));

class _ApiKeysScreenState extends State<ApiKeysScreen> {
  late final Set<String> _open = {if (widget.openId != null) widget.openId!};
  final Map<String, GlobalKey> _keys = {};
  final Map<String, String> _result = {};
  final Set<String> _testing = {};

  ApiKeys get keys => widget.deps.hub.apiKeys;

  GlobalKey _gk(String id) => _keys.putIfAbsent(id, GlobalKey.new);

  @override
  void initState() {
    super.initState();
    if (widget.openId != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final c = _gk(widget.openId!).currentContext;
        if (c != null) Scrollable.ensureVisible(c, duration: Duration.zero, alignment: 0.05);
      });
    }
  }

  String _ago(DateTime at) => '${agoWords(DateTime.now().difference(at))} ago'.replaceFirst('less than a minute ago', 'just now');

  Future<void> _addOrReplace(KeyProvider p, {required bool replace}) async {
    final d = widget.deps;
    final saved = await showKeySheet(
      context,
      provider: p,
      replace: replace,
      onServer: d.hub.sharing?.onServer ?? false,
      onSave: (key, {bool check = true}) => keys.save(p, key, check: check),
      openUrl: d.hub.openUrl,
    );
    if (saved == true && mounted) {
      _result.remove(p.id);
      say(context, replace ? 'Key replaced' : 'Key saved');
    }
  }

  Future<void> _test(KeyProvider p) async {
    setState(() => _testing.add(p.id));
    final r = await keys.test(p);
    if (!mounted) return;
    setState(() {
      _testing.remove(p.id);
      _result[p.id] = r.ok ? 'Works, checked just now' : (r.message ?? "Couldn't check the key.");
    });
  }

  Future<void> _remove(KeyProvider p) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Remove the ${p.provider} key?'),
        content: Text(
          '${p.uses.isEmpty ? '' : '${p.usesWords} go${p.uses.length == 1 ? 'es' : ''} back to the data on this device. '}'
          'This removes the key on this device only. You can add a key again later.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep')),
          TextButton(key: const ValueKey('confirm-remove-key'), onPressed: () => Navigator.pop(ctx, true), child: Text('Remove', style: TextStyle(color: ctx.t.emergency))),
        ],
      ),
    );
    if (ok != true) return;
    await keys.remove(p);
    if (mounted) {
      setState(() => _open.remove(p.id));
      say(context, 'Key removed');
    }
  }

  Widget _row(BuildContext context, KeyProvider p) {
    final k = context.t;
    final st = keys.statusOf(p);
    final open = _open.contains(p.id);
    final word = keyWord(st.state);
    final header = SettingsRow(
      key: ValueKey('api-key-${p.id}'),
      title: p.title,
      status: [Part(p.usesWords)],
      selected: widget.openId == p.id && open,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(word, style: TextStyle(fontSize: 15, color: st.state == KeyState.refused ? k.warning : k.secondary)),
          const SizedBox(width: 4),
          Icon(open ? Icons.expand_less : Icons.expand_more, color: k.secondary),
        ],
      ),
      chevron: false,
      onTap: () => setState(() => open ? _open.remove(p.id) : _open.add(p.id)),
    );
    return Column(key: _gk(p.id), crossAxisAlignment: CrossAxisAlignment.stretch, children: [header, if (open) _detail(context, p, st)]);
  }

  Widget _detail(BuildContext context, KeyProvider p, KeyStatus st) {
    final k = context.t;
    final d = widget.deps;
    final w = d.hub.weather;
    final has = st.set;
    final offline = w.noNetwork;
    final line = _result[p.id] ?? keyStatusLine(st, _ago);
    Widget label(String t) => Padding(padding: const EdgeInsets.only(top: 12, bottom: 4), child: Text(t, style: TextStyle(fontSize: 12, letterSpacing: 0.6, color: k.secondary, fontWeight: FontWeight.w600)));
    Widget fact(String a, String b) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [SizedBox(width: 92, child: Text(a, style: TextStyle(fontSize: 14, color: k.secondary))), Expanded(child: Text(b, style: TextStyle(fontSize: 14, color: k.text)))]),
    );
    return Container(
      key: ValueKey('api-key-open-${p.id}'),
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
      margin: const EdgeInsets.only(top: 2),
      decoration: BoxDecoration(color: k.surface, borderRadius: BorderRadius.circular(12)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ...[
            if (line.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 8), child: Text(line, key: ValueKey('key-status-${p.id}'), style: TextStyle(fontSize: 15, color: st.state == KeyState.refused ? k.warning : (st.state == KeyState.working ? k.ok : k.secondary)))),
            const SizedBox(height: 10),
            Wrap(
              spacing: 10,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (has)
                  RowButton(key: ValueKey('replace-${p.id}'), label: 'Replace', onPressed: () => _addOrReplace(p, replace: true))
                else
                  FilledButton(key: ValueKey('add-${p.id}'), onPressed: () => _addOrReplace(p, replace: false), child: const Text('Add key')),
                if (has)
                  RowButton(key: ValueKey('test-${p.id}'), label: _testing.contains(p.id) ? 'Testing' : 'Test key', onPressed: offline || _testing.contains(p.id) ? null : () => _test(p)),
              ],
            ),
            if (has) Padding(padding: const EdgeInsets.only(top: 6), child: Text(offline ? 'Needs a connection.' : 'Test uses one request from your ${p.provider} account.', style: TextStyle(fontSize: 12, color: k.secondary))),
            label('USED BY'),
            if (p.uses.isEmpty) fact('', 'Nothing yet'),
            for (final u in p.uses) fact(u.label, u.on ? 'On' : 'Off'),
            ...sharedWith(context, p),
          ],
          label('ABOUT'),
          fact('Provider', p.provider),
          fact('Key page', p.getKeyUrl),
          if (p.rate != null) fact('Limit', p.rate!),
          if (p.costLine != null) fact('Cost', p.costLine!),
          if (p.creditText != null) fact('Credit', p.creditText!),
          fact('Stored', widget.deps.hub.sharing?.onServer == true ? 'On the computer running Cache' : 'On this device'),
          if (has) ...[
            const SizedBox(height: 8),
            TextButton(
              key: ValueKey('remove-${p.id}'),
              onPressed: () => _remove(p),
              style: TextButton.styleFrom(foregroundColor: k.emergency, padding: EdgeInsets.zero, alignment: Alignment.centerLeft),
              child: const Text('Remove the key', style: TextStyle(fontSize: 16)),
            ),
          ],
        ],
      ),
    );
  }

  /// "Shared with": the devices this key goes to (key_sync_rows.dart); empty when there is no sync here.
  List<Widget> sharedWith(BuildContext context, KeyProvider p) => keySharedWithRows(context, widget.deps, p);

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([keys, widget.deps.hub.settings]),
      builder: (context, _) {
        final saved = keys.saved, other = keys.available;
        final attention = keys.needAttention;
        return SettingsPage(
          title: 'API keys',
          children: [
            NoteText(widget.deps.hub.sharing?.onServer == true ? 'Your own keys for online services. They stay on the computer running Cache.' : 'Your own keys for online services. They stay on this device.'),
            if (attention > 0) Padding(padding: const EdgeInsets.symmetric(horizontal: 6), child: Text('$attention ${attention == 1 ? 'key needs' : 'keys need'} attention', style: TextStyle(fontSize: 14, color: context.t.warning))),
            if (saved.isNotEmpty) SettingsGroup(label: 'Your keys', rows: [for (final p in saved) _row(context, p)]),
            SettingsGroup(label: 'Keys Cache can use', rows: [for (final p in other) _row(context, p)]),
          ],
        );
      },
    );
  }
}

/// A plain row for a module: "Provider API key" with Set, Not set, Not accepted or Limit reached at the end. A tap opens the master list
/// at that provider, open. It never opens the key sheet and has no button or colour.
class ApiKeyShortcutRow extends StatelessWidget {
  const ApiKeyShortcutRow({super.key, required this.deps, required this.providerId});

  final SettingsDeps deps;
  final String providerId;

  @override
  Widget build(BuildContext context) {
    final keys = deps.hub.apiKeys;
    return ListenableBuilder(
      listenable: keys,
      builder: (context, _) {
        final p = keys.providerById(providerId);
        if (p == null) return const SizedBox.shrink();
        final st = keys.statusOf(p);
        return SettingsRow(
          key: ValueKey('key-shortcut-$providerId'),
          title: p.title,
          trailing: Text(keyWord(st.state), style: TextStyle(fontSize: 15, color: context.t.secondary)),
          chevron: true,
          onTap: () => openApiKeys(context, deps, providerId: providerId),
        );
      },
    );
  }
}
