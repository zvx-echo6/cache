import 'dart:convert';
import 'dart:isolate';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../video/token_store.dart';

/// The optional app PIN (project decision, 2026-10-29): when one is set, Cache asks for it when it opens. It only gates opening
/// the app; nothing is encrypted with it and it hides nothing from Cache (the assistant) once Cache is open. The PIN itself is
/// never stored: only a salted PBKDF2-HMAC-SHA256 hash, in the phone's secure storage.
/// App lock is not in 1.0 (moved to 1.1): nothing offers it, and a PIN stored by an earlier test build is never asked for.
const bool kAppLockEnabled = false;

/// Whether Cache shows its lock screen now: never while app lock is not in the app, whatever is stored.
bool appLockAsked(AppPin pin) => kAppLockEnabled && pin.locked;

class AppPin extends ChangeNotifier {
  AppPin(this._store, {this.iterations = 60000, DateTime Function()? clock}) : _now = clock ?? DateTime.now;

  final TokenStore _store;

  /// PBKDF2 rounds (tests use few).
  final int iterations;
  final DateTime Function() _now;

  static const String _key = 'app.pin';

  /// A PIN is 4 to 8 digits.
  static bool valid(String pin) => RegExp(r'^\d{4,8}$').hasMatch(pin);

  /// After this many wrong tries in a row, the next try waits.
  static const int triesBeforeWait = 5;
  static const Duration wait = Duration(seconds: 30);

  bool? _set;
  bool _locked = false;
  int _wrong = 0;
  DateTime? _waitUntil;

  /// A PIN is set (null until read).
  bool? get isSet => _set;

  /// Cache is waiting for the PIN.
  bool get locked => _locked;

  /// How long until the next try is allowed, or null.
  Duration? get waitLeft {
    final w = _waitUntil;
    if (w == null) return null;
    final left = w.difference(_now());
    return left.isNegative ? null : left;
  }

  /// Reads whether a PIN is set; Cache opens locked when one is.
  Future<void> init() async {
    try {
      _set = await _store.read(_key) != null;
    } catch (e) {
      debugPrint('cache app pin: could not read ($e)');
      _set = false;
    }
    _locked = _set == true;
    notifyListeners();
  }

  static Uint8List _pbkdf2(List<int> pin, List<int> salt, int rounds) {
    final mac = Hmac(sha256, pin);
    var u = mac.convert([...salt, 0, 0, 0, 1]).bytes;
    final out = Uint8List.fromList(u);
    for (var i = 1; i < rounds; i++) {
      u = mac.convert(u).bytes;
      for (var j = 0; j < out.length; j++) {
        out[j] ^= u[j];
      }
    }
    return out;
  }

  static Future<String> _hash(String pin, List<int> salt, int rounds) async {
    final p = utf8.encode(pin);
    return base64Encode(await Isolate.run(() => _pbkdf2(p, salt, rounds)));
  }

  /// Sets or replaces the PIN.
  Future<void> set(String pin) async {
    if (!valid(pin)) throw ArgumentError('A PIN is 4 to 8 digits.');
    final r = Random.secure();
    final salt = List<int>.generate(16, (_) => r.nextInt(256));
    final h = await _hash(pin, salt, iterations);
    await _store.write(_key, jsonEncode({'v': 1, 'salt': base64Encode(salt), 'rounds': iterations, 'hash': h}));
    _set = true;
    notifyListeners();
  }

  /// Whether [pin] is the PIN. A right PIN unlocks Cache; wrong ones in a row make the next try wait.
  Future<bool> check(String pin) async {
    if (waitLeft != null) return false;
    final raw = await _store.read(_key);
    if (raw == null) {
      _locked = false;
      notifyListeners();
      return true;
    }
    final j = jsonDecode(raw) as Map;
    final h = await _hash(pin, base64Decode(j['salt'] as String), (j['rounds'] as num).toInt());
    final ok = _same(h, j['hash'] as String);
    if (ok) {
      _wrong = 0;
      _waitUntil = null;
      _locked = false;
    } else if (++_wrong >= triesBeforeWait) {
      _wrong = 0;
      _waitUntil = _now().add(wait);
    }
    notifyListeners();
    return ok;
  }

  static bool _same(String a, String b) {
    if (a.length != b.length) return false;
    var d = 0;
    for (var i = 0; i < a.length; i++) {
      d |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return d == 0;
  }

  /// Removes the PIN (after the current one was checked by the caller).
  Future<void> remove() async {
    await _store.delete(_key);
    _set = false;
    _locked = false;
    notifyListeners();
  }
}
