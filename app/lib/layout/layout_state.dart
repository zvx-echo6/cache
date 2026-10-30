import 'dart:convert';
import 'dart:io';

import 'package:cache_search/cache_search.dart' show MapPlace;
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../files.dart';
import 'modules.dart';

/// The blocks Home can show.
enum HomeBlock {
  ask('Ask box', null),
  weather('Weather', 'Needs a connection to stay current'),
  alerts('Alerts', 'Needs a connection to stay current'),
  shortcuts('Shortcuts', null);

  const HomeBlock(this.label, this.note);

  final String label;

  /// A line under the name in Edit Home.
  final String? note;

  static HomeBlock? byName(String? n) {
    for (final b in HomeBlock.values) {
      if (b.name == n) return b;
    }
    return null;
  }
}

enum ShortcutKind { module, place, page, chat }

/// One card in Home's Shortcuts: a way straight to a module, a saved place, a Library page or a chat.
class Shortcut {
  const Shortcut({required this.kind, required this.title, this.subtitle = '', required this.data});

  factory Shortcut.module(ModuleId m) => Shortcut(kind: ShortcutKind.module, title: m.label, data: {'module': m.name});

  factory Shortcut.place(MapPlace p) => Shortcut(
        kind: ShortcutKind.place,
        title: p.name,
        subtitle: p.kind.isEmpty ? 'Place' : p.kind,
        data: {
          'id': p.id,
          'type': p.type,
          'kind': p.kind,
          'address': p.address,
          'lat': p.lat,
          'lon': p.lon,
          'matched': p.matched,
          'formats': p.formats,
        },
      );

  /// A page of a ZIM, by its `zim:<uuid>/<path>` address.
  factory Shortcut.page({required String address, required String title, String library = ''}) =>
      Shortcut(kind: ShortcutKind.page, title: title, subtitle: library.isEmpty ? 'Library page' : library, data: {'address': address});

  factory Shortcut.chat({required int id, required String title}) =>
      Shortcut(kind: ShortcutKind.chat, title: title, subtitle: 'Chat', data: {'id': id});

  final ShortcutKind kind;
  final String title;
  final String subtitle;
  final Map<String, dynamic> data;

  /// What makes two shortcuts the same thing.
  String get key => switch (kind) {
        ShortcutKind.module => 'module:${data['module']}',
        ShortcutKind.place => 'place:${data['id']}',
        ShortcutKind.page => 'page:${data['address']}',
        ShortcutKind.chat => 'chat:${data['id']}',
      };

  ModuleId? get module => kind == ShortcutKind.module ? ModuleId.byName(data['module'] as String?) : null;
  String? get address => kind == ShortcutKind.page ? data['address'] as String? : null;
  int? get chatId => kind == ShortcutKind.chat ? (data['id'] as num?)?.toInt() : null;

  MapPlace? get place {
    if (kind != ShortcutKind.place) return null;
    final lat = (data['lat'] as num?)?.toDouble();
    final lon = (data['lon'] as num?)?.toDouble();
    if (lat == null || lon == null) return null;
    return MapPlace(
      id: (data['id'] ?? '') as String,
      type: (data['type'] ?? 'place') as String,
      name: title,
      kind: (data['kind'] ?? '') as String,
      address: (data['address'] ?? '') as String,
      lat: lat,
      lon: lon,
      matched: (data['matched'] ?? '') as String,
      formats: {for (final e in ((data['formats'] as Map?) ?? const {}).entries) '${e.key}': '${e.value}'},
    );
  }

  Map<String, dynamic> toJson() => {'kind': kind.name, 'title': title, 'subtitle': subtitle, 'data': data};

  static Shortcut? fromJson(Object? j) {
    if (j is! Map) return null;
    ShortcutKind? kind;
    for (final k in ShortcutKind.values) {
      if (k.name == j['kind']) kind = k;
    }
    final data = j['data'];
    if (kind == null || data is! Map) return null;
    final s = Shortcut(
      kind: kind,
      title: '${j['title'] ?? ''}',
      subtitle: '${j['subtitle'] ?? ''}',
      data: Map<String, dynamic>.from(data),
    );
    // A module that no longer exists, or a shortcut with no target, is dropped.
    if (kind == ShortcutKind.module && s.module == null) return null;
    if (kind == ShortcutKind.place && s.place == null) return null;
    if (kind == ShortcutKind.page && s.address == null) return null;
    if (kind == ShortcutKind.chat && s.chatId == null) return null;
    return s;
  }
}

/// How the app is laid out, and what the person changed: which modules sit in the bottom bar, which blocks Home shows and in
/// what order, and the Shortcuts. Saved on the phone (layout.json beside the app's settings) and read back at start.
class LayoutState extends ChangeNotifier {
  LayoutState({this.settingsDirOverride});

  /// Test hook.
  final Directory? settingsDirOverride;

  static const List<ModuleId> defaultPinned = [ModuleId.ask, ModuleId.maps, ModuleId.library];
  static const List<HomeBlock> defaultBlocks = [HomeBlock.ask, HomeBlock.weather, HomeBlock.alerts, HomeBlock.shortcuts];

  List<ModuleId> _pinned = List.of(defaultPinned);
  List<HomeBlock> _order = List.of(defaultBlocks);
  final Set<HomeBlock> _off = {};
  final List<Shortcut> _shortcuts = [];
  bool _setupHidden = false;
  File? _file;

  /// The modules in the bar between Home and Modules, in bar order (at most [kMaxPinned]).
  List<ModuleId> get pinned => List.unmodifiable(_pinned);
  bool isPinned(ModuleId m) => _pinned.contains(m);
  bool get barFull => _pinned.length >= kMaxPinned;

  /// Every Home block, in the order Home shows them.
  List<HomeBlock> get blockOrder => List.unmodifiable(_order);
  bool isOn(HomeBlock b) => !_off.contains(b);

  /// The blocks Home shows now.
  List<HomeBlock> get visibleBlocks => [for (final b in _order) if (isOn(b)) b];
  List<Shortcut> get shortcuts => List.unmodifiable(_shortcuts);

  /// The person hid the "Set up Cache" card on Home (Settings > Set up Cache shows it again).
  bool get setupHidden => _setupHidden;

  Future<void> init() async {
    final dir = settingsDirOverride ?? await getApplicationSupportDirectory();
    await dir.create(recursive: true);
    _file = File('${dir.path}/layout.json');
    _read();
    notifyListeners();
  }

  void _read() {
    try {
      final f = _file!;
      if (!f.existsSync()) return;
      final j = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      final pinned = <ModuleId>[];
      for (final n in (j['pinned'] as List? ?? const [])) {
        final m = ModuleId.byName(n as String?);
        if (m != null && !pinned.contains(m) && pinned.length < kMaxPinned) pinned.add(m);
      }
      final order = <HomeBlock>[];
      for (final n in (j['blocks'] as List? ?? const [])) {
        final b = HomeBlock.byName(n as String?);
        if (b != null && !order.contains(b)) order.add(b);
      }
      for (final b in defaultBlocks) {
        if (!order.contains(b)) order.add(b);
      }
      _pinned = pinned;
      _order = order;
      _off
        ..clear()
        ..addAll([for (final n in (j['off'] as List? ?? const [])) ?HomeBlock.byName(n as String?)]);
      _shortcuts.clear();
      for (final s in (j['shortcuts'] as List? ?? const [])) {
        final sc = Shortcut.fromJson(s);
        if (sc != null && !_shortcuts.any((x) => x.key == sc.key)) _shortcuts.add(sc);
      }
      _setupHidden = j['setupHidden'] == true;
    } catch (_) {
      // A damaged file is ignored; the defaults apply.
    }
  }

  void _save() {
    notifyListeners();
    try {
      final f = _file;
      if (f == null) return;
      writeStringAtomicSync(f, jsonEncode({
        'pinned': [for (final m in _pinned) m.name],
        'blocks': [for (final b in _order) b.name],
        'off': [for (final b in _off) b.name],
        'shortcuts': [for (final s in _shortcuts) s.toJson()],
        if (_setupHidden) 'setupHidden': true,
      }));
    } catch (_) {}
  }

  // ---- the bottom bar ----------------------------------------------------------------------------------------

  /// Pins [m] at the end of the bar. False when the bar is full (nothing changes) or [m] is already pinned.
  bool pin(ModuleId m) {
    if (isPinned(m) || barFull) return false;
    _pinned.add(m);
    _save();
    return true;
  }

  void unpin(ModuleId m) {
    if (_pinned.remove(m)) _save();
  }

  /// Puts [m] in the place of the pinned module [old].
  void replace(ModuleId old, ModuleId m) {
    final i = _pinned.indexOf(old);
    if (i < 0 || isPinned(m)) return;
    _pinned[i] = m;
    _save();
  }

  // ---- Home --------------------------------------------------------------------------------------------------

  void setBlockOn(HomeBlock b, bool on) {
    if (on ? !_off.remove(b) : !_off.add(b)) return;
    _save();
  }

  /// Moves the block at [from] to place [to] (the index it ends up at, as ReorderableListView.onReorderItem reports it).
  void moveBlock(int from, int to) {
    if (from < 0 || from >= _order.length) return;
    to = to.clamp(0, _order.length - 1);
    if (to == from) return;
    _order.insert(to, _order.removeAt(from));
    _save();
  }

  void setSetupHidden(bool hidden) {
    if (_setupHidden == hidden) return;
    _setupHidden = hidden;
    _save();
  }

  /// Blocks back to the default order, all on. Shortcuts are the person's own and stay.
  void resetBlocks() {
    _order = List.of(defaultBlocks);
    _off.clear();
    _save();
  }

  // ---- Shortcuts ---------------------------------------------------------------------------------------------

  bool hasShortcut(Shortcut s) => _shortcuts.any((x) => x.key == s.key);

  /// Adds [s] to the end. False when it is already there.
  bool addShortcut(Shortcut s) {
    if (hasShortcut(s)) return false;
    _shortcuts.add(s);
    _save();
    return true;
  }

  void removeShortcut(Shortcut s) {
    final n = _shortcuts.length;
    _shortcuts.removeWhere((x) => x.key == s.key);
    if (_shortcuts.length != n) _save();
  }

  /// Moves a shortcut one place earlier (-1) or later (+1).
  void nudgeShortcut(Shortcut s, int by) {
    final i = _shortcuts.indexWhere((x) => x.key == s.key);
    final j = i + by;
    if (i < 0 || j < 0 || j >= _shortcuts.length) return;
    _shortcuts.insert(j, _shortcuts.removeAt(i));
    _save();
  }
}
