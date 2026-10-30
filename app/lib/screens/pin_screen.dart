import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../settings/app_pin.dart';
import '../theme.dart';

/// Cache's lock screen while the app PIN is asked for (only when one is set, when Cache opens).
class PinLockScreen extends StatelessWidget {
  const PinLockScreen({super.key, required this.pin});

  final AppPin pin;

  @override
  Widget build(BuildContext context) => Scaffold(
        body: SafeArea(
          child: PinPad(
            title: 'Enter your PIN',
            onDone: (p) async {
              if (await pin.check(p)) return null;
              final w = pin.waitLeft;
              return w != null ? 'Too many tries. Wait ${w.inSeconds + 1} seconds.' : 'Wrong PIN';
            },
          ),
        ),
      );
}

/// A PIN pad: dots for the digits typed, ten digits and delete (44 pt and up), OK. [onDone] answers null when the PIN is
/// accepted, else what to say.
class PinPad extends StatefulWidget {
  const PinPad({super.key, required this.title, required this.onDone, this.subtitle});

  final String title;
  final String? subtitle;
  final Future<String?> Function(String pin) onDone;

  @override
  State<PinPad> createState() => _PinPadState();
}

class _PinPadState extends State<PinPad> {
  String _typed = '';
  String? _error;
  bool _busy = false;

  void _key(String d) {
    if (_busy || _typed.length >= 8) return;
    HapticFeedback.selectionClick();
    setState(() {
      _typed += d;
      _error = null;
    });
  }

  Future<void> _ok() async {
    if (_busy || !AppPin.valid(_typed)) return;
    setState(() => _busy = true);
    final err = await widget.onDone(_typed);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = err;
      if (err != null) _typed = '';
    });
  }

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    Widget key(String label, {VoidCallback? onTap, Widget? child, String? semantic}) => Padding(
          padding: const EdgeInsets.all(6),
          child: SizedBox(
            width: 72,
            height: 60,
            child: Semantics(
              button: true,
              label: semantic ?? label,
              excludeSemantics: true,
              child: Material(
                color: k.surface,
                borderRadius: BorderRadius.circular(14),
                child: InkWell(
                  key: ValueKey('pin-$label'),
                  borderRadius: BorderRadius.circular(14),
                  onTap: onTap,
                  child: Center(child: child ?? Text(label, style: TextStyle(fontSize: 24, color: k.text))),
                ),
              ),
            ),
          ),
        );
    return Center(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.lock_outline, size: 36, color: k.accent),
            const SizedBox(height: 12),
            Text(widget.title, style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: k.text)),
            if (widget.subtitle != null) Padding(padding: const EdgeInsets.only(top: 4), child: Text(widget.subtitle!, style: TextStyle(fontSize: 14, color: k.secondary))),
            const SizedBox(height: 16),
            Semantics(
              label: '${_typed.length} digits typed',
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var i = 0; i < (_typed.length < 4 ? 4 : _typed.length); i++)
                    Container(
                      margin: const EdgeInsets.all(6),
                      width: 14,
                      height: 14,
                      decoration: BoxDecoration(shape: BoxShape.circle, color: i < _typed.length ? k.accent : Colors.transparent, border: Border.all(color: k.secondary, width: 1.5)),
                    ),
                ],
              ),
            ),
            SizedBox(height: 24, child: _error == null ? null : Text(_error!, key: const ValueKey('pin-error'), style: TextStyle(fontSize: 14, color: k.warning))),
            for (final row in const [
              ['1', '2', '3'],
              ['4', '5', '6'],
              ['7', '8', '9'],
            ])
              Row(mainAxisSize: MainAxisSize.min, children: [for (final d in row) key(d, onTap: () => _key(d))]),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                key('del', semantic: 'Delete', onTap: () => setState(() => _typed = _typed.isEmpty ? '' : _typed.substring(0, _typed.length - 1)), child: Icon(Icons.backspace_outlined, color: k.text)),
                key('0', onTap: () => _key('0')),
                key('ok', semantic: 'OK', onTap: AppPin.valid(_typed) && !_busy ? _ok : null, child: _busy ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)) : Text('OK', style: TextStyle(fontSize: 18, color: AppPin.valid(_typed) ? k.accent : k.secondary))),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Notebooks > App PIN: set a PIN (typed twice), change it or remove it (the current one first).
class AppPinScreen extends StatefulWidget {
  const AppPinScreen({super.key, required this.pin});

  final AppPin pin;

  @override
  State<AppPinScreen> createState() => _AppPinScreenState();
}

enum _Step { current, choose, confirm }

class _AppPinScreenState extends State<AppPinScreen> {
  late _Step _step = widget.pin.isSet == true ? _Step.current : _Step.choose;
  bool _removing = false;
  String? _first;
  int _round = 0;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final set = widget.pin.isSet == true;
    if (set && _step == _Step.current && !_removing && _round == 0) {
      return Scaffold(
        appBar: AppBar(title: const Text('App PIN')),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text('Cache asks for your PIN when it opens. It does not lock or hide anything once Cache is open.', style: TextStyle(fontSize: 15, color: k.secondary)),
            const SizedBox(height: 16),
            FilledButton(key: const ValueKey('pin-change'), onPressed: () => setState(() => _round = 1), child: const Text('Change PIN')),
            const SizedBox(height: 8),
            OutlinedButton(key: const ValueKey('pin-remove'), onPressed: () => setState(() => _removing = true), child: const Text('Remove PIN')),
          ],
        ),
      );
    }
    final (title, sub) = switch (_step) {
      _Step.current => ('Enter your PIN', _removing ? 'to remove it' : 'to change it'),
      _Step.choose => ('Choose a PIN', '4 to 8 digits. Cache will ask for it when it opens.'),
      _Step.confirm => ('Type it again', null),
    };
    return Scaffold(
      appBar: AppBar(title: const Text('App PIN')),
      body: PinPad(
        key: ValueKey(_step),
        title: title,
        subtitle: sub,
        onDone: (p) async {
          final nav = Navigator.of(context);
          final messenger = ScaffoldMessenger.of(context);
          switch (_step) {
            case _Step.current:
              if (!await widget.pin.check(p)) return widget.pin.waitLeft != null ? 'Too many tries. Wait a little.' : 'Wrong PIN';
              if (_removing) {
                await widget.pin.remove();
                messenger.showSnackBar(const SnackBar(content: Text('PIN removed')));
                nav.pop();
                return null;
              }
              setState(() => _step = _Step.choose);
            case _Step.choose:
              setState(() {
                _first = p;
                _step = _Step.confirm;
              });
            case _Step.confirm:
              if (p != _first) {
                setState(() => _step = _Step.choose);
                return "The PINs didn't match. Choose one again.";
              }
              await widget.pin.set(p);
              messenger.showSnackBar(const SnackBar(content: Text('PIN set. Cache will ask for it when it opens.')));
              nav.pop();
          }
          return null;
        },
      ),
    );
  }
}
