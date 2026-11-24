import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../settings/api_keys.dart';
import '../../settings/hub.dart';
import '../../settings/web_search_setup.dart';
import '../../theme.dart';

/// The sheet for adding or replacing a key, made from the provider's record: what it is used for, a button to the page where you get a
/// key (and that address as text, to copy), the provider's numbered steps, a field with Paste, and "Check and save". A key is checked with
/// the provider and stored by [onSave], never shown again. Saving turns nothing on. A failed check keeps the typed key and says why in one
/// sentence; a limit offers "Save anyway" and no connection "Save without checking". Answers true when a key was saved.
Future<bool?> showKeySheet(
  BuildContext context, {
  required KeyProvider provider,
  required Future<KeyCheck> Function(String key, {bool check}) onSave,
  required UrlOpener openUrl,
  bool replace = false,
  bool onServer = false,
}) {
  return showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    showDragHandle: false,
    useSafeArea: true,
    builder: (ctx) => KeySheet(provider: provider, onSave: onSave, openUrl: openUrl, replace: replace, onServer: onServer),
  );
}

/// "Add your Kagi key" / "Replace your 511 key (511.idaho.gov)".
String keySheetTitle(KeyProvider p, {required bool replace}) {
  final name = p.title.endsWith(' API key') ? '${p.provider} key' : p.title;
  return '${replace ? 'Replace' : 'Add'} your $name';
}

class KeySheet extends StatefulWidget {
  const KeySheet({super.key, required this.provider, required this.onSave, required this.openUrl, this.replace = false, this.onServer = false});

  final KeyProvider provider;
  final Future<KeyCheck> Function(String key, {bool check}) onSave;
  final UrlOpener openUrl;
  final bool replace;

  /// The key is kept by the Cache server (a browser), not on this device.
  final bool onServer;

  @override
  State<KeySheet> createState() => _KeySheetState();
}

class _KeySheetState extends State<KeySheet> {
  final _key = TextEditingController();
  bool _busy = false;
  KeyCheck? _failed;
  String? _note;

  @override
  void initState() {
    super.initState();
    _key.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _key.dispose();
    super.dispose();
  }

  KeyProvider get p => widget.provider;

  Future<void> _open() async {
    try {
      await widget.openUrl(p.getKeyUrl);
    } catch (_) {
      if (mounted) setState(() => _note = "Couldn't open the page. Go to ${p.getKeyUrl}");
    }
  }

  Future<void> _paste() async {
    final d = await Clipboard.getData(Clipboard.kTextPlain);
    final t = d?.text?.trim();
    if (t != null && t.isNotEmpty) _key.text = t;
  }

  Future<void> _save({bool check = true}) async {
    setState(() {
      _busy = true;
      _failed = null;
    });
    final KeyCheck r;
    try {
      r = await widget.onSave(_key.text, check: check);
    } catch (_) {
      if (mounted) {
        setState(() {
          _busy = false;
          _failed = const KeyCheck.failed("Couldn't check the key. Try again.");
        });
      }
      return;
    }
    if (!mounted) return;
    if (r.ok) {
      _key.clear();
      Navigator.pop(context, true);
    } else {
      // The typed key stays in the field.
      setState(() {
        _busy = false;
        _failed = r;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final steps = [null, ...p.steps, 'Paste it below'];
    final failed = _failed;
    final where = widget.onServer ? 'on the computer running Cache' : 'on this device';
    final empty = _key.text.trim().isEmpty;
    final affects = widget.replace && p.uses.isNotEmpty ? 'Replaces the key for ${p.usesWords}. ' : '';
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(18, 22, 18, 0),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(keySheetTitle(p, replace: widget.replace), style: TextStyle(fontSize: 20, fontWeight: FontWeight.w500, color: k.text)),
                  const SizedBox(height: 14),
                  Text(
                    [
                      if (p.uses.isNotEmpty) 'Used for: ${p.usesWords}.',
                      'You need your own key from ${p.provider}. It works for ${p.kind == KeyKind.road ? 'this site' : p.provider} only.',
                      ?p.costLine,
                    ].join(' '),
                    style: TextStyle(fontSize: 15, height: 1.5, color: k.secondary),
                  ),
                  if (p.rate != null) ...[const SizedBox(height: 8), Text(p.rate!, style: TextStyle(fontSize: 14, height: 1.5, color: k.secondary))],
                  const SizedBox(height: 14),
                  for (var i = 0; i < steps.length; i++)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(width: 24, child: Text('${i + 1}.', style: TextStyle(fontSize: 15, height: 1.6, color: k.text))),
                          Expanded(
                            child: steps[i] == null
                                ? Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Wrap(
                                        crossAxisAlignment: WrapCrossAlignment.center,
                                        children: [
                                          TextButton(
                                            key: const ValueKey('get-key'),
                                            onPressed: _open,
                                            style: TextButton.styleFrom(padding: EdgeInsets.zero, minimumSize: const Size(0, 36), tapTargetSize: MaterialTapTargetSize.shrinkWrap, foregroundColor: k.accent),
                                            child: Text('Get a key from ${p.provider}', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500)),
                                          ),
                                          Text(' (opens their page)', style: TextStyle(fontSize: 15, color: k.text)),
                                        ],
                                      ),
                                      SelectableText(p.getKeyUrl, key: const ValueKey('key-page-url'), style: TextStyle(fontSize: 13, color: k.secondary)),
                                    ],
                                  )
                                : Text(steps[i]!, style: TextStyle(fontSize: 15, height: 1.6, color: k.text)),
                          ),
                        ],
                      ),
                    ),
                  const SizedBox(height: 10),
                  Text('Key', style: TextStyle(fontSize: 13, color: k.secondary)),
                  const SizedBox(height: 6),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Expanded(
                        child: TextField(
                          key: const ValueKey('key-field'),
                          controller: _key,
                          enabled: !_busy,
                          autocorrect: false,
                          enableSuggestions: false,
                          keyboardType: TextInputType.visiblePassword,
                          style: const TextStyle(fontFamily: 'monospace', fontSize: 16),
                          decoration: InputDecoration(
                            contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: k.accent, width: 1.5)),
                            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: k.accent, width: 1.5)),
                            focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: k.accent, width: 2)),
                          ),
                          onChanged: (_) {
                            if (_failed != null) setState(() => _failed = null);
                          },
                        ),
                      ),
                      const SizedBox(width: 10),
                      OutlinedButton(
                        key: const ValueKey('paste-key'),
                        onPressed: _busy ? null : _paste,
                        style: OutlinedButton.styleFrom(minimumSize: const Size(0, 48), shape: const StadiumBorder(), side: BorderSide(color: k.accent, width: 1.5)),
                        child: const Text('Paste'),
                      ),
                    ],
                  ),
                  if (_busy)
                    Padding(padding: const EdgeInsets.only(top: 8), child: Text('Checking with ${p.provider}', key: const ValueKey('key-checking'), style: TextStyle(fontSize: 14, color: k.secondary))),
                  if (failed != null) ...[
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(failed.message ?? "That key wasn't accepted.", key: const ValueKey('key-error'), style: TextStyle(fontSize: 14, height: 1.4, color: k.emergency)),
                    ),
                    if (failed.kind == KeyFailure.limit)
                      TextButton(key: const ValueKey('save-anyway'), onPressed: _busy ? null : () => _save(check: false), child: const Text('Save anyway')),
                    if (failed.kind == KeyFailure.offline)
                      TextButton(key: const ValueKey('save-unchecked'), onPressed: _busy ? null : () => _save(check: false), child: const Text('Save without checking')),
                  ],
                  if (_note != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_note!, style: TextStyle(fontSize: 14, color: k.secondary))),
                  const SizedBox(height: 14),
                  Text(
                    '${affects}The key stays $where, is checked with one request, and isn\'t shown again. Saving turns nothing on.',
                    style: TextStyle(fontSize: 13, height: 1.5, color: k.secondary),
                  ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 14, 18, 22),
            child: Wrap(
              alignment: WrapAlignment.end,
              spacing: 10,
              runSpacing: 10,
              children: [
                OutlinedButton(
                  onPressed: _busy ? null : () => Navigator.pop(context, false),
                  style: OutlinedButton.styleFrom(minimumSize: const Size(0, 48), shape: const StadiumBorder(), foregroundColor: k.text, side: BorderSide(color: k.secondary.withValues(alpha: 0.6), width: 1.5)),
                  child: const Text('Cancel', style: TextStyle(fontSize: 16)),
                ),
                FilledButton(
                  key: const ValueKey('check-and-save'),
                  onPressed: _busy || empty ? null : _save,
                  style: FilledButton.styleFrom(minimumSize: const Size(0, 48), shape: const StadiumBorder()),
                  child: _busy
                      ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.5))
                      : const Text('Check and save', style: TextStyle(fontSize: 16)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
