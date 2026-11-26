import 'package:cache_search/cache_search.dart' show CacheSearchException;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../maps/ui/format.dart';
import '../../sharing/sharing_state.dart';
import '../../theme.dart';
import 'ways_to_connect_page.dart';
import 'widgets.dart';

/// What the form says is wrong, field by field (null: fine). The same checks as the engine's, so a person sees them before anything is
/// sent; the engine checks again.
class EntryPointProblems {
  const EntryPointProblems({this.address, this.port, this.network});

  final String? address, port, network;

  bool get any => address != null || port != null || network != null;
}

/// Checks the add or edit form: the address can't be empty or have spaces, the port is 1 to 65535, a private entry needs a network name
/// or a passphrase (one typed, or one already saved), and host:port can't be one already in [others] (the other entry points).
EntryPointProblems checkEntryPoint({
  required String host,
  required String port,
  required bool private,
  required String networkName,
  required bool hasPassphrase,
  required Iterable<EntryPoint> others,
}) {
  final h = host.trim();
  final p = int.tryParse(port.trim());
  String? address, portProblem, network;
  if (h.isEmpty) {
    address = 'Enter the address of the entry point.';
  } else if (RegExp(r'\s').hasMatch(h)) {
    address = 'The address cannot have spaces in it.';
  }
  if (p == null || p < 1 || p > 65535) portProblem = 'The port has to be a number from 1 to 65535.';
  if (private && networkName.trim().isEmpty && !hasPassphrase) network = 'A private entry point needs a network name or a passphrase.';
  if (address == null && portProblem == null && others.any((e) => e.port == p && e.host.toLowerCase() == h.toLowerCase())) {
    address = 'That entry point is already in your list.';
  }
  return EntryPointProblems(address: address, port: portProblem, network: network);
}

/// The sizes a file through an entry point may be, to pick from.
const List<int> kCapChoices = [10 << 20, 25 << 20, 50 << 20, 100 << 20, 250 << 20];

String _capText(int bytes) => 'Up to ${formatBytes(bytes)} each';

/// Asks before an entry point is removed. True when the person said Remove.
Future<bool> confirmRemoveEntry(BuildContext context, String host) async =>
    await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Remove $host?'),
        content: const Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text("It's removed from all your linked devices, with its network name and passphrase. To use it again, you'll need to enter it again."),
            SizedBox(height: 14),
            Text('To stop using it for now and keep its settings, turn it off instead.'),
          ],
        ),
        actions: [
          TextButton(key: const ValueKey('cancel-remove'), onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(
            key: const ValueKey('confirm-remove'),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Remove', style: TextStyle(color: ctx.t.emergency)),
          ),
        ],
      ),
    ) ==
    true;

/// Settings > Sharing and sync > Ways to connect > one entry point (its [id]), or, with no id, the form that adds one. On an entry
/// point's page the "Use this entry point" switch acts at once; the rest is kept with Save. Remove goes to every linked device.
class EntryPointPage extends StatefulWidget {
  const EntryPointPage({super.key, required this.sharing, this.id});

  final SharingState sharing;

  /// The entry point shown; null: the add form.
  final String? id;

  @override
  State<EntryPointPage> createState() => _EntryPointPageState();
}

class _EntryPointPageState extends State<EntryPointPage> {
  SharingState get s => widget.sharing;
  EntryPoint? get _entry => widget.id == null ? null : s.entryOf(widget.id!);
  bool get _adding => widget.id == null;

  final _host = TextEditingController();
  final _port = TextEditingController();
  final _name = TextEditingController();
  final _pass = TextEditingController();
  bool _private = false;
  bool _show = false;
  int _cap = EntryPoint.defaultCapBytes;
  EntryPointProblems _problems = const EntryPointProblems();
  bool _busy = false;
  bool _filled = false;

  @override
  void initState() {
    super.initState();
    _fill();
  }

  /// The form takes the entry point's settings once, when it is there to read (the list may arrive after the page opens).
  void _fill() {
    final e = _entry;
    if (_filled || e == null) return;
    _filled = true;
    _host.text = e.host;
    _port.text = '${e.port}';
    _name.text = e.networkName ?? '';
    _private = e.private;
    _cap = e.capBytes;
  }

  @override
  void dispose() {
    _host.dispose();
    _port.dispose();
    _name.dispose();
    _pass.dispose();
    super.dispose();
  }

  String _say(Object e) => e is CacheSearchException ? e.message : '$e';

  Future<void> _run(Future<void> Function() f) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await f();
    } catch (e) {
      if (mounted) say(context, _say(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  bool get _hasPassphrase => _pass.text.isNotEmpty || (_private && (_entry?.hasPassphrase ?? false));

  Future<void> _save() async {
    final problems = checkEntryPoint(
      host: _host.text,
      port: _port.text,
      private: _private,
      networkName: _name.text,
      hasPassphrase: _hasPassphrase,
      others: s.entries.where((e) => e.id != widget.id),
    );
    setState(() => _problems = problems);
    if (problems.any) return;
    await _run(() async {
      await s.entryPointSet(
        id: widget.id,
        host: _host.text.trim(),
        port: int.parse(_port.text.trim()),
        private: _private,
        networkName: _private ? _name.text.trim() : '',
        // Left out, the passphrase saved stays; typed, it replaces it.
        passphrase: _private && _pass.text.isNotEmpty ? _pass.text : null,
        capBytes: _cap,
        on: _adding ? true : null,
      );
      if (mounted) Navigator.of(context).pop();
    });
  }

  Future<void> _remove(EntryPoint e) async {
    if (!await confirmRemoveEntry(context, e.host)) return;
    await _run(() async {
      await s.entryPointRemove(e.id);
      if (mounted) Navigator.of(context).pop();
    });
  }

  Future<void> _pickCap() async {
    final picked = await showDialog<int>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Files through this entry point'),
        children: [
          for (final c in {...kCapChoices, _cap}.toList()..sort())
            SimpleDialogOption(key: ValueKey('cap-$c'), onPressed: () => Navigator.pop(ctx, c), child: Text(_capText(c), style: TextStyle(fontWeight: c == _cap ? FontWeight.w600 : FontWeight.w400))),
        ],
      ),
    );
    if (picked != null && mounted) setState(() => _cap = picked);
  }

  InputDecoration _box(CacheTokens k, {String? hint, String? error, Widget? suffix}) => InputDecoration(
    hintText: hint,
    hintStyle: TextStyle(color: k.secondary.withValues(alpha: 0.7)),
    errorText: error,
    errorMaxLines: 3,
    suffixIcon: suffix,
    isDense: true,
    filled: false,
    border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: k.secondary.withValues(alpha: 0.5))),
    enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: k.secondary.withValues(alpha: 0.5))),
    focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: k.accent, width: 2)),
    errorBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: k.emergency, width: 1.5)),
    focusedErrorBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: k.emergency, width: 2)),
    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
  );

  Widget _label(CacheTokens k, String text) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Text(text, style: TextStyle(fontSize: 14, color: k.secondary)),
  );

  Widget _card(CacheTokens k, Widget child) => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(color: k.surface, borderRadius: BorderRadius.circular(16)),
    child: child,
  );

  /// The status card: where the entry point stands, and for how many of this person's devices it is the way.
  Widget _status(CacheTokens k, EntryPoint e) {
    final word = entryStateWord(e);
    final checked = checkedText(e.checked);
    final String? sub = switch (e.state) {
      'connected' => switch (s.onlineThrough(e.id)) {
        0 => checked,
        1 => '$checked · 1 of your devices is online through it',
        final n => '$checked · $n of your devices are online through it',
      },
      'off' || 'connecting' || 'not_running' => null,
      _ => checked,
    };
    return _card(
      k,
      Column(
        key: const ValueKey('entry-status'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(word.text, style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: word.tone == Tone.danger ? k.emergency : k.text)),
          if (sub != null) ...[const SizedBox(height: 2), Text(sub, style: TextStyle(fontSize: 14, height: 1.35, color: k.secondary))],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    return ListenableBuilder(
      listenable: s,
      builder: (context, _) {
        _fill();
        final e = _entry;
        if (!_adding && e == null) {
          return const SettingsPage(title: 'Entry point', children: [NoteText('This entry point is no longer in your list.')]);
        }
        return SettingsPage(
          title: _adding ? 'Add an entry point' : e!.host,
          children: [
            NoteText(
              _adding
                  ? 'The address and port of a Reticulum node you run or trust. Private ones also need a network name and passphrase.'
                  : 'Added on all your linked devices.',
            ),
            if (!_adding)
              _card(
                k,
                Row(
                  children: [
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Use this entry point', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
                          SizedBox(height: 2),
                          _Sub('Off keeps these settings'),
                        ],
                      ),
                    ),
                    Switch(key: const ValueKey('entry-on'), value: e!.on, onChanged: _busy ? null : (v) => _run(() => s.entryPointOn(e.id, v))),
                  ],
                ),
              ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const GroupLabel('Where it is'),
                _card(
                  k,
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _label(k, 'Address'),
                      TextField(
                        key: const ValueKey('entry-host'),
                        controller: _host,
                        keyboardType: TextInputType.url,
                        autocorrect: false,
                        enableSuggestions: false,
                        style: TextStyle(fontSize: 17, color: k.text),
                        decoration: _box(k, hint: 'rt.example.net', error: _problems.address),
                        onChanged: (_) => setState(() => _problems = EntryPointProblems(port: _problems.port, network: _problems.network)),
                      ),
                      const SizedBox(height: 14),
                      _label(k, 'Port'),
                      TextField(
                        key: const ValueKey('entry-port'),
                        controller: _port,
                        keyboardType: TextInputType.number,
                        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                        style: TextStyle(fontSize: 17, color: k.text),
                        decoration: _box(k, hint: '4242', error: _problems.port),
                        onChanged: (_) => setState(() => _problems = EntryPointProblems(address: _problems.address, network: _problems.network)),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            _card(
              k,
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      const Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Private network', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
                            SizedBox(height: 2),
                            _Sub('Needs a network name and passphrase. Ask whoever runs it.'),
                          ],
                        ),
                      ),
                      Switch(key: const ValueKey('entry-private'), value: _private, onChanged: _busy ? null : (v) => setState(() => _private = v)),
                    ],
                  ),
                  if (_private) ...[
                    const SizedBox(height: 14),
                    _label(k, 'Network name'),
                    TextField(
                      key: const ValueKey('entry-network'),
                      controller: _name,
                      autocorrect: false,
                      enableSuggestions: false,
                      style: TextStyle(fontSize: 17, color: k.text),
                      decoration: _box(k, error: _problems.network),
                      onChanged: (_) => setState(() => _problems = EntryPointProblems(address: _problems.address, port: _problems.port)),
                    ),
                    const SizedBox(height: 14),
                    _label(k, 'Passphrase'),
                    TextField(
                      key: const ValueKey('entry-passphrase'),
                      controller: _pass,
                      obscureText: !_show,
                      autocorrect: false,
                      enableSuggestions: false,
                      style: TextStyle(fontSize: 17, color: k.text),
                      // A passphrase already saved is never read back: the field shows dots, and left alone keeps it.
                      decoration: _box(
                        k,
                        hint: (_entry?.hasPassphrase ?? false) ? '••••••••••••' : null,
                        suffix: TextButton(
                          key: const ValueKey('entry-show'),
                          onPressed: () => setState(() => _show = !_show),
                          child: Text(_show ? 'Hide' : 'Show', style: TextStyle(fontWeight: FontWeight.w600, color: k.accent)),
                        ),
                      ),
                      onChanged: (_) => setState(() => _problems = EntryPointProblems(address: _problems.address, port: _problems.port)),
                    ),
                  ],
                ],
              ),
            ),
            if (!_adding)
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [const GroupLabel('Status'), _status(k, e!)],
              ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const GroupLabel('Files through this entry point'),
                SettingsRow(
                  key: const ValueKey('entry-cap'),
                  title: _capText(_cap),
                  status: const [Part('Bigger files wait for Wi-Fi')],
                  onTap: _busy ? null : _pickCap,
                ),
              ],
            ),
            const NoteText(
              'The person who runs it can see when your devices are online and which ones use it. Other people on it can see when your '
              'devices are online. No one can read what you send.',
            ),
            FilledButton(
              key: const ValueKey('entry-save'),
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
              onPressed: _busy ? null : _save,
              child: Text(_adding ? 'Add and connect' : 'Save', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            ),
            if (!_adding)
              OutlinedButton(
                key: const ValueKey('entry-remove'),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(52),
                    foregroundColor: k.emergency,
                  side: BorderSide(color: k.emergency.withValues(alpha: 0.7), width: 1.5),
                ),
                onPressed: _busy ? null : () => _remove(e!),
                child: const Text('Remove from all my devices', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              ),
          ],
        );
      },
    );
  }
}

class _Sub extends StatelessWidget {
  const _Sub(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Text(text, style: TextStyle(fontSize: 14, height: 1.35, color: context.t.secondary));
}
