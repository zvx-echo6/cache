import 'package:flutter/material.dart';

import '../../settings/hub.dart';
import '../../settings/web_search_setup.dart';
import '../../theme.dart';

/// The sheet for adding a key to a service, the same for every service that needs one: what it gives you, a button to the page
/// where you get a key, a field to paste it, and "Check and save". The key is checked with the service, stored (by [onSave]) and
/// never shown again. Answers true when a key was saved.
///
/// [steps] are the steps after getting the key; the first step (the button) and the last ("Paste it below") are added here.
Future<bool?> showAddKeySheet(
  BuildContext context, {
  required String title,
  required String gives,
  required String getKeyLabel,
  required String getKeyUrl,
  required List<String> steps,
  required Future<KeyCheck> Function(String key) onSave,
  required UrlOpener openUrl,
  required String savedNote,
}) {
  return showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    showDragHandle: false,
    useSafeArea: true,
    builder: (ctx) => AddKeySheet(
      title: title,
      gives: gives,
      getKeyLabel: getKeyLabel,
      getKeyUrl: getKeyUrl,
      steps: steps,
      onSave: onSave,
      openUrl: openUrl,
      savedNote: savedNote,
    ),
  );
}

class AddKeySheet extends StatefulWidget {
  const AddKeySheet({
    super.key,
    required this.title,
    required this.gives,
    required this.getKeyLabel,
    required this.getKeyUrl,
    required this.steps,
    required this.onSave,
    required this.openUrl,
    required this.savedNote,
  });

  final String title;
  final String gives;
  final String getKeyLabel;
  final String getKeyUrl;
  final List<String> steps;
  final Future<KeyCheck> Function(String key) onSave;
  final UrlOpener openUrl;
  final String savedNote;

  @override
  State<AddKeySheet> createState() => _AddKeySheetState();
}

class _AddKeySheetState extends State<AddKeySheet> {
  final _key = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _key.dispose();
    super.dispose();
  }

  Future<void> _open() async {
    try {
      await widget.openUrl(widget.getKeyUrl);
    } catch (_) {
      if (mounted) setState(() => _error = "Couldn't open the page. Go to ${widget.getKeyUrl}");
    }
  }

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final KeyCheck r;
    try {
      r = await widget.onSave(_key.text);
    } catch (_) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = "Couldn't check the key. Try again.";
        });
      }
      return;
    }
    if (!mounted) return;
    if (r.ok) {
      _key.clear();
      Navigator.pop(context, true);
    } else {
      setState(() {
        _busy = false;
        _error = r.message ?? "That key wasn't accepted.";
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final steps = [null, ...widget.steps, 'Paste it below'];
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(18, 22, 18, 22),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(widget.title, style: TextStyle(fontSize: 20, fontWeight: FontWeight.w500, color: k.text)),
            const SizedBox(height: 14),
            Text(widget.gives, style: TextStyle(fontSize: 15, height: 1.5, color: k.secondary)),
            const SizedBox(height: 14),
            for (var i = 0; i < steps.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    SizedBox(width: 24, child: Text('${i + 1}.', style: TextStyle(fontSize: 15, color: k.text))),
                    Expanded(
                      child: steps[i] == null
                          ? Wrap(
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                TextButton(
                                  key: const ValueKey('get-key'),
                                  onPressed: _open,
                                  style: TextButton.styleFrom(
                                    padding: EdgeInsets.zero,
                                    minimumSize: const Size(0, 36),
                                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                    foregroundColor: k.accent,
                                  ),
                                  child: Text(widget.getKeyLabel, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500)),
                                ),
                                Text(' (opens their page)', style: TextStyle(fontSize: 15, color: k.text)),
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
            TextField(
              key: const ValueKey('key-field'),
              controller: _key,
              enabled: !_busy,
              autocorrect: false,
              enableSuggestions: false,
              keyboardType: TextInputType.visiblePassword,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 16),
              decoration: InputDecoration(
                isDense: false,
                contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: k.accent, width: 1.5)),
                enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: k.accent, width: 1.5)),
                focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: k.accent, width: 2)),
              ),
              onChanged: (_) {
                if (_error != null) setState(() => _error = null);
              },
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(_error!, key: const ValueKey('key-error'), style: TextStyle(fontSize: 14, height: 1.4, color: k.emergency)),
              ),
            const SizedBox(height: 14),
            Text(widget.savedNote, style: TextStyle(fontSize: 13, height: 1.5, color: k.secondary)),
            const SizedBox(height: 14),
            Wrap(
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
                  onPressed: _busy ? null : _save,
                  style: FilledButton.styleFrom(minimumSize: const Size(0, 48), shape: const StadiumBorder()),
                  child: _busy
                      ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.5))
                      : const Text('Check and save', style: TextStyle(fontSize: 16)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
