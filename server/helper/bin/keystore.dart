import 'dart:convert';
import 'dart:io';

import '../../../packages/cache_search/lib/src/core_dispatch.dart';
import '../../../packages/cache_search/lib/src/errors.dart';
import 'line_protocol.dart';

/// The server's keystore: the web search key, the data-source keys, the video tokens and the app PIN, kept on the server so every
/// browser sees the same ones and a restart loses nothing. One JSON file (`CACHE_KEYSTORE`, `<data>/keystore.json`), outside the
/// `fs.*` roots, written atomically and owner-only (0600). It is not the sign-in keys of the Rust server (server/src/keys.rs).
///
/// Browser ops (through `/api/core`; names are 1-120 characters of letters, digits and `._:-`):
///   keys.names {} -> [name]            names only, never values
///   keys.set {name,value} -> null      value is a non-empty string (at most 64 KB)
///   keys.delete {name} -> bool
///   keys.get {name} -> string|null     raw, but only for names the phone UI shows or that are not secret: `*.user` (a video
///                                      sign-in name) and `app.pin` (a salted hash the page checks). Any other name: `forbidden`.
///
/// References: a browser that wants to hand a key to the engine uses [refOf] (`keystore://<name>`) instead of the value. [CoreHook]
/// swaps every string argument that is exactly a reference for the stored value before a core op runs, so the browser never holds
/// the key. `setWeb` is also remembered (provider, reference, online; never a raw key) and [replay]ed after the engine opens.
///
/// Inside the helper, other code (the sharing host's `set_secrets` and `take_secrets`) calls [get], [set], [delete] and [names]
/// directly; those are not limited by the browser read rule.
class KeyStore implements OpHandler, CoreHook {
  KeyStore(this.file, {this.log}) {
    _load();
  }

  /// The keystore file.
  final File file;
  final void Function(String message)? log;

  static const String refPrefix = 'keystore://';
  static const int _maxValue = 64 * 1024;
  static final RegExp _name = RegExp(r'^[A-Za-z0-9._:-]{1,120}$');

  final Map<String, String> _values = {};
  Map<String, dynamic>? _web;

  /// The reference that stands for the key [name] in a core op's arguments.
  static String refOf(String name) => '$refPrefix$name';

  void _load() {
    try {
      if (!file.existsSync()) return;
      final j = jsonDecode(file.readAsStringSync());
      if (j is! Map) return;
      final keys = j['keys'];
      if (keys is Map) {
        for (final e in keys.entries) {
          if (e.key is String && e.value is String && _name.hasMatch(e.key as String)) _values[e.key as String] = e.value as String;
        }
      }
      final w = j['web'];
      if (w is Map) _web = w.cast<String, dynamic>();
    } catch (e) {
      log?.call('keystore: cannot read ${file.path}: $e');
    }
  }

  void _save() {
    final dir = file.parent..createSync(recursive: true);
    final tmp = File('${dir.path}/.${file.uri.pathSegments.last}.$pid.tmp');
    try {
      tmp.createSync();
      try {
        Process.runSync('chmod', ['600', tmp.path]);
      } catch (_) {} // no chmod (Windows): the user's own folder is what protects it there
      tmp.writeAsStringSync(jsonEncode({'v': 1, 'keys': _values, if (_web != null) 'web': _web}), flush: true);
      tmp.renameSync(file.path);
    } catch (e) {
      try {
        if (tmp.existsSync()) tmp.deleteSync();
      } catch (_) {}
      throw CacheSearchException('io_error', 'The keystore could not be saved: $e');
    }
  }

  static String _check(Object? name) {
    if (name is! String || !_name.hasMatch(name)) throw const CacheSearchException('bad_args', 'A key name is 1-120 letters, digits or . _ : -');
    return name;
  }

  /// The value of [name], or null.
  String? get(String name) => _values[name];

  /// Saves [value] under [name].
  void set(String name, String value) {
    _check(name);
    if (value.isEmpty || value.length > _maxValue) throw const CacheSearchException('bad_args', 'A key value is 1 to 65536 characters');
    if (_values[name] == value) return;
    _values[name] = value;
    _save();
  }

  /// Removes [name]; false when it was not there.
  bool delete(String name) {
    if (_values.remove(name) == null) return false;
    _save();
    return true;
  }

  /// All names, sorted.
  List<String> names() => _values.keys.toList()..sort();

  static bool _browserMayRead(String name) => name == 'app.pin' || name.endsWith('.user');

  @override
  bool handles(String op) => op.startsWith('keys.');

  @override
  Object? handle(String op, Map<String, dynamic> a) {
    switch (op) {
      case 'keys.names':
        return names();
      case 'keys.set':
        final v = a['value'];
        if (v is! String) throw const CacheSearchException('bad_args', 'keys.set needs a string "value"');
        set(_check(a['name']), v);
        return null;
      case 'keys.delete':
        return delete(_check(a['name']));
      case 'keys.get':
        final n = _check(a['name']);
        if (!_browserMayRead(n)) throw const CacheSearchException('forbidden', 'That key is never handed out; use its reference');
        return get(n);
      default:
        throw CacheSearchException('bad_op', 'No such op: $op');
    }
  }

  /// [args] with every string that is a reference replaced by the stored value (maps and lists are walked; other values stay).
  Object? resolve(Object? v) {
    if (v is String) {
      if (!v.startsWith(refPrefix)) return v;
      final value = _values[v.substring(refPrefix.length)];
      if (value == null) throw const CacheSearchException('not_found', 'That key is not saved on the server');
      return value;
    }
    if (v is Map) return {for (final e in v.entries) e.key: resolve(e.value)};
    if (v is List) return [for (final e in v) resolve(e)];
    return v;
  }

  @override
  Map<String, dynamic> before(String op, Map<String, dynamic> args) => (resolve(args) as Map).cast<String, dynamic>();

  @override
  void after(String op, Map<String, dynamic> args) {
    if (op != 'setWeb') return;
    final key = args['key'];
    if (key != null && !(key is String && key.startsWith(refPrefix))) return; // a raw key (a check) is never kept
    final provider = args['provider'];
    _web = {'provider': provider is String ? provider : null, 'key': key, 'online': args['online'] == true};
    try {
      _save();
    } catch (e) {
      log?.call('keystore: $e');
    }
  }

  /// Gives the engine its web search settings again, as the browser last set them. Call once the engine is open.
  void replay(CoreDispatcher dispatcher) {
    final w = _web;
    if (w == null) return;
    try {
      dispatcher.handle('setWeb', (resolve(w) as Map).cast<String, dynamic>());
      log?.call('keystore: web search settings restored');
    } catch (e) {
      log?.call('keystore: could not restore web search settings: $e');
    }
  }
}
